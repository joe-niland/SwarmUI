#!/usr/bin/env bash
# Shared helpers for the RunPod scripts. Source this file, don't run it.
# shellcheck disable=SC2034 # Constants are used by the scripts that source this file.

RUNPOD_API="https://api.runpod.io/v2"
RUNPOD_DEFAULT_ENV_FILE="$HOME/.config/swarmui/runpod.env"
WORKER_PORT=7801
VOLUME_MOUNT=/workspace
WORKER_SWARM_DIR="$VOLUME_MOUNT/SwarmUI"
POD_NAME_PREFIX=swarmui-
# ComfyUI's installer pulls CUDA 13 PyTorch, so the host driver must support CUDA 13.
MIN_CUDA_VERSION=13.0

# Load KEY=VALUE lines from the settings file, read literally like `docker run --env-file`.
load_env_file() {
    local file="${RUNPOD_ENV_FILE:-$RUNPOD_DEFAULT_ENV_FILE}"
    if [ ! -f "$file" ]; then
        >&2 echo "Settings file not found: $file"
        >&2 echo "Copy runpod.env.example there, or set RUNPOD_ENV_FILE to its path."
        exit 1
    fi
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '' | \#*) continue ;;
        esac
        export "${line%%=*}=${line#*=}"
    done <"$file"
}

require_vars() {
    local name
    for name in "$@"; do
        if [ -z "${!name:-}" ]; then
            >&2 echo "Missing setting: $name"
            exit 1
        fi
    done
}

# runpod_api METHOD PATH [-]
# With a third argument of "-", the request body is read from stdin.
# Prints the response body. Fails on an HTTP error status.
# The key and body never go on the command line, so they stay out of the process list.
runpod_api() {
    local args=(-sS --fail-with-body -X "$1" -H "Content-Type: application/json")
    if [ "${3:-}" = "-" ]; then
        args+=(--data-binary @-)
    fi
    curl "${args[@]}" -H @<(printf 'Authorization: Bearer %s\n' "$RUNPOD_API_KEY") "$RUNPOD_API$2"
}

# json_field NAME: print one top-level field of the JSON object on stdin.
json_field() {
    python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

# create_pod NAME SCRIPT [ENV_VAR_NAME...]
# Creates a pod on the network volume that runs SCRIPT with `bash -c`.
# RunPod places the pod in the volume's data centre.
# Tries each GPU type in RUNPOD_GPU_TYPE in order, until one is in stock there.
# The named environment variables are copied into the pod.
# Prints the API response. If every GPU type fails, prints each failure to stderr.
create_pod() {
    local gpu_types gpu_type response errors=""
    IFS=, read -ra gpu_types <<<"$RUNPOD_GPU_TYPE"
    for gpu_type in "${gpu_types[@]}"; do
        read -r gpu_type <<<"$gpu_type"
        if response=$(GPU_TYPE="$gpu_type" POD_NAME="$1" POD_SCRIPT="$2" VOLUME_MOUNT="$VOLUME_MOUNT" \
            WORKER_PORT="$WORKER_PORT" MIN_CUDA_VERSION="$MIN_CUDA_VERSION" \
            python3 -c "$CREATE_POD_BODY_PY" "${@:3}" | runpod_api POST /pods - 2>&1); then
            echo "$response"
            return
        fi
        errors+="$gpu_type: $response"$'\n'
    done
    >&2 printf '%s' "$errors"
    return 1
}

CREATE_POD_BODY_PY=$(
    cat <<'PY'
import json, os, sys

env = os.environ
print(json.dumps({
    "name": env["POD_NAME"],
    "image": env["RUNPOD_IMAGE"],
    "cloud": "SECURE",
    "gpu": {"id": env["GPU_TYPE"], "count": 1, "minCudaVersion": env["MIN_CUDA_VERSION"]},
    "disk": int(env["RUNPOD_CONTAINER_DISK_GB"]),
    "mounts": {"network": [{"volumeId": env["RUNPOD_NETWORK_VOLUME_ID"], "path": env["VOLUME_MOUNT"]}]},
    "ports": [f"{env['WORKER_PORT']}/http"],
    "env": {name: env[name] for name in sys.argv[1:]},
    "entrypoint": ["bash", "-c"],
    "cmd": [env["POD_SCRIPT"]],
}))
PY
)

proxy_url() {
    echo "https://$1-$WORKER_PORT.proxy.runpod.net"
}
