#!/usr/bin/env bash
# Shared helpers for the RunPod scripts. Source this file, don't run it.
# shellcheck disable=SC2034 # Constants are used by the scripts that source this file.

RUNPOD_API="https://api.runpod.io/v2"
RUNPOD_DEFAULT_ENV_FILE="$HOME/.config/swarmui/runpod.env"
WORKER_PORT=7801
# Where pods mount the global volume.
VOLUME_MOUNT=/workspace
# The models live on the volume. Each pod links them into its local install.
VOLUME_MODELS_DIR="$VOLUME_MOUNT/Models"
# Packed SwarmUI install, with ComfyUI, settings and login. Each pod unpacks it to local disk,
# because the global volume has no file locking and can't run a Python environment.
INSTALL_ARCHIVE="$VOLUME_MOUNT/swarmui-install.tar"
# Must stay the same on every pod: the Python environment inside it uses absolute paths.
LOCAL_SWARM_DIR=/opt/SwarmUI
# Copies of common.sh and worker-start.sh on the volume. Worker pods run worker-start.sh from
# here, so the pod can still delete itself if unpacking the install fails.
VOLUME_SCRIPTS_DIR="$VOLUME_MOUNT/runpod-scripts"
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
# Creates a pod that mounts the global volume and runs SCRIPT with `bash -c`.
# RunPod places the pod in any data centre that has the GPU type free.
# Tries the GPU types in RUNPOD_GPU_TYPE from cheapest to dearest, skipping any that RunPod
# reports as out of stock everywhere, until one succeeds.
# The named environment variables are copied into the pod.
# Prints the API response. If every GPU type fails, prints each failure to stderr.
create_pod() {
    local catalog gpu_types gpu_type response errors=""
    catalog=$(runpod_api GET "/catalog/gpus?include=AVAILABILITY&product=POD&cloud=SECURE") || return
    gpu_types=$(python3 -c "$GPU_TYPES_BY_PRICE_PY" "$RUNPOD_GPU_TYPE" <<<"$catalog") || return
    while IFS= read -r gpu_type; do
        if response=$(GPU_TYPE="$gpu_type" POD_NAME="$1" POD_SCRIPT="$2" VOLUME_MOUNT="$VOLUME_MOUNT" \
            WORKER_PORT="$WORKER_PORT" MIN_CUDA_VERSION="$MIN_CUDA_VERSION" \
            python3 -c "$CREATE_POD_BODY_PY" "${@:3}" | runpod_api POST /pods - 2>&1); then
            echo "$response"
            return
        fi
        errors+="$gpu_type: $response"$'\n'
    done <<<"$gpu_types"
    >&2 printf '%s' "$errors"
    return 1
}

# Python helpers for a GET /catalog/gpus response, shared with provision.sh.
GPU_CATALOG_PY=$(
    cat <<'PY'
def gpu_list(data):
    if isinstance(data, dict):
        data = next((v for v in data.values() if isinstance(v, list)), [])
    return data

def secure_price(gpu):
    return (gpu.get("price") or {}).get("secure")
PY
)

# Prints the GPU types in the whitelist (argv[1], comma-separated) that are in stock, one per line,
# cheapest first. Fails if none are.
GPU_TYPES_BY_PRICE_PY=$(
    cat <<PY
import json, sys
$GPU_CATALOG_PY

whitelist = [g.strip() for g in sys.argv[1].split(",") if g.strip()]
gpus = {g["id"]: g for g in gpu_list(json.load(sys.stdin))}
unknown = [g for g in whitelist if g not in gpus]
if unknown:
    sys.exit(f"RunPod doesn't list these GPU types: {', '.join(unknown)}. Check RUNPOD_GPU_TYPE.")
in_stock = [g for g in whitelist if gpus[g].get("availability") != "NONE"]
if not in_stock:
    sys.exit(f"None of these GPU types is in stock: {', '.join(whitelist)}.")
for g in sorted(in_stock, key=lambda g: (secure_price(gpus[g]) is None, secure_price(gpus[g]) or 0)):
    print(g)
PY
)

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
    "mounts": {"global": [{"volumeId": env["RUNPOD_GLOBAL_VOLUME_ID"], "path": env["VOLUME_MOUNT"]}]},
    "ports": [f"{env['WORKER_PORT']}/http"],
    "env": {name: env[name] for name in sys.argv[1:]},
    "entrypoint": ["bash", "-c"],
    "cmd": [env["POD_SCRIPT"]],
}))
PY
)

# Links each model file on the volume into the local install's Models folder. The folders
# themselves stay on local disk, because SwarmUI keeps a database in each model folder.
link_models() {
    mkdir -p "$LOCAL_SWARM_DIR/Models"
    cp -rs "$VOLUME_MODELS_DIR/." "$LOCAL_SWARM_DIR/Models/"
}

proxy_url() {
    echo "https://$1-$WORKER_PORT.proxy.runpod.net"
}
