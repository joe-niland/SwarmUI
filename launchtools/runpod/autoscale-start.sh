#!/usr/bin/env bash
# Start script for SwarmUI's Auto Scaling Backend. Creates one worker pod on RunPod and
# reports its address back to SwarmUI. Settings come from the environment: start the
# SwarmUI container with `--env-file` pointing at your runpod.env.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# SwarmUI retries every 5 seconds or so; this allows roughly 15 minutes for the pod to boot
# and unpack the install.
CONNECT_RETRIES=180

emit() {
    echo "[SwarmAutoScaleBackend]$1[/SwarmAutoScaleBackend]"
}

require_vars RUNPOD_API_KEY RUNPOD_GLOBAL_VOLUME_ID RUNPOD_GPU_TYPE RUNPOD_IMAGE \
    RUNPOD_CONTAINER_DISK_GB SWARM_WORKER_MAX_HOURS

export SWARM_RUNPOD_API_KEY="$RUNPOD_API_KEY"
if ! response=$(create_pod "${POD_NAME_PREFIX}worker-$(date +%s)" \
    "exec bash $VOLUME_SCRIPTS_DIR/worker-start.sh" \
    SWARM_RUNPOD_API_KEY SWARM_WORKER_MAX_HOURS 2>&1); then
    emit "DeclareFailed: RunPod pod create failed: $(tr '\n' ' ' <<<"$response")"
    exit 1
fi

pod_id=$(json_field id <<<"$response")
emit "DoRetries: $CONNECT_RETRIES"
emit "NewURL: $(proxy_url "$pod_id")"
