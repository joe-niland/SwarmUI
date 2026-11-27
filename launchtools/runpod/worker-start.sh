#!/usr/bin/env bash
# Runs on each worker pod that autoscale-start.sh creates, from the copy on the global volume.
# Unpacks the SwarmUI install to local disk, links in the models and starts SwarmUI as a worker.
# Deletes this pod when it stops for any reason, so a stopped worker never keeps billing.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
require_vars SWARM_RUNPOD_API_KEY RUNPOD_POD_ID SWARM_WORKER_MAX_HOURS
RUNPOD_API_KEY="$SWARM_RUNPOD_API_KEY"

DELETE_ATTEMPTS=5
DELETE_RETRY_SECONDS=10
# Must be longer than the worker takes to start ComfyUI: the local SwarmUI only starts pinging
# once the worker's backends finish loading.
CONTROL_TIMEOUT_MINUTES=10

delete_this_pod() {
    local attempt
    for ((attempt = 1; attempt <= DELETE_ATTEMPTS; attempt++)); do
        if runpod_api DELETE "/pods/$RUNPOD_POD_ID" >/dev/null; then
            return
        fi
        sleep "$DELETE_RETRY_SECONDS"
    done
    >&2 echo "Could not delete pod $RUNPOD_POD_ID. Delete it in the RunPod console, or it keeps billing."
}
trap delete_this_pod EXIT

echo "Unpacking $INSTALL_ARCHIVE"
SECONDS=0
tar -xf "$INSTALL_ARCHIVE" -C "$(dirname "$LOCAL_SWARM_DIR")"
echo "Unpacked in $SECONDS seconds."
link_models

cd "$LOCAL_SWARM_DIR"
timeout "${SWARM_WORKER_MAX_HOURS}h" ./launch-linux.sh \
    --launch_mode none \
    --host 0.0.0.0 \
    --require_control_within "$CONTROL_TIMEOUT_MINUTES" \
    --no_persist true \
    --lock_settings true
