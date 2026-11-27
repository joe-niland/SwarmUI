#!/usr/bin/env bash
# One-time RunPod setup, run from your own machine. See README.md in this folder.
#   provision.sh volume          Create the global volume.
#   provision.sh setup           Start a setup pod that installs SwarmUI and the models onto the volume.
#   provision.sh delete POD_ID   Delete a pod, for example a setup pod that failed.
#   provision.sh gpus            List Secure Cloud GPU types with VRAM and price, for RUNPOD_GPU_TYPE.
#   provision.sh pods            List this project's pods, to spot any that didn't delete themselves.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

load_env_file
require_vars RUNPOD_API_KEY

create_volume() {
    if [ -n "${RUNPOD_GLOBAL_VOLUME_ID:-}" ]; then
        echo "RUNPOD_GLOBAL_VOLUME_ID is already set to $RUNPOD_GLOBAL_VOLUME_ID, not creating another volume."
        return
    fi
    local response volume_id
    response=$(echo '{"name": "swarmui"}' | runpod_api POST /global-volumes -)
    volume_id=$(json_field id <<<"$response")
    echo "Created global volume $volume_id."
    echo "Set RUNPOD_GLOBAL_VOLUME_ID=$volume_id in your settings file."
}

start_setup_pod() {
    require_vars RUNPOD_GLOBAL_VOLUME_ID RUNPOD_GPU_TYPE RUNPOD_IMAGE \
        RUNPOD_CONTAINER_DISK_GB SWARM_REPO_URL SWARM_REPO_BRANCH
    local script response pod_id
    # Starts from the saved install if there is one, otherwise from a fresh clone.
    script="if [ -f $INSTALL_ARCHIVE ]; then
    tar -xf $INSTALL_ARCHIVE -C $(dirname "$LOCAL_SWARM_DIR")
else
    git clone --branch \"\$SWARM_REPO_BRANCH\" \"\$SWARM_REPO_URL\" $LOCAL_SWARM_DIR
fi || { echo 'Could not get the SwarmUI install. Delete this pod.'; sleep infinity; }
exec bash $LOCAL_SWARM_DIR/launchtools/runpod/worker-setup.sh"
    export SWARM_RUNPOD_API_KEY="$RUNPOD_API_KEY"
    response=$(create_pod "${POD_NAME_PREFIX}setup" "$script" SWARM_RUNPOD_API_KEY SWARM_REPO_URL SWARM_REPO_BRANCH)
    pod_id=$(json_field id <<<"$response")
    echo "Started setup pod $pod_id. Follow its logs in the RunPod console."
    echo "When the logs say SwarmUI is starting, open $(proxy_url "$pod_id") and finish the installer."
    echo "Then click Shutdown Server under Server → Server Info. The pod saves the install and deletes itself."
}

# Lists GPU types cheapest first, with VRAM, Secure Cloud price per hour and stock across RunPod.
list_gpus() {
    runpod_api GET "/catalog/gpus?include=AVAILABILITY&product=POD&cloud=SECURE" | python3 -c "
import json, sys
$GPU_CATALOG_PY

gpus = gpu_list(json.load(sys.stdin))
gpus.sort(key=lambda g: (secure_price(g) is None, secure_price(g) or 0))
print(f\"{'VRAM':>5} {'\$/HOUR':>7} {'STOCK':<7} ID\")
for g in gpus:
    price = secure_price(g)
    price = '-' if price is None else f'{price:.2f}'
    print(f\"{g.get('memory', '-'):>5} {price:>7} {g.get('availability', '-'):<7} {g['id']}\")
"
}

# print_items PREFIX: print the id, name and status fields of each item in the JSON list on
# stdin whose name starts with PREFIX. The list may be wrapped in an object.
print_items() {
    python3 -c '
import json, sys
data = json.load(sys.stdin)
if isinstance(data, dict):
    data = next((v for v in data.values() if isinstance(v, list)), [])
for item in data:
    if str(item.get("name") or item.get("id")).startswith(sys.argv[1]):
        fields = {k: v for k, v in item.items() if k in ("id", "name", "status", "desiredStatus")}
        print(json.dumps(fields))
' "$1"
}

case "${1:-}" in
    volume) create_volume ;;
    setup) start_setup_pod ;;
    delete)
        runpod_api DELETE "/pods/${2:?Give the pod ID to delete}" >/dev/null
        echo "Deleted pod $2."
        ;;
    gpus) list_gpus ;;
    pods) runpod_api GET /pods | print_items "$POD_NAME_PREFIX" ;;
    *)
        >&2 echo "Usage: $0 volume | setup | delete POD_ID | gpus | pods"
        exit 1
        ;;
esac
