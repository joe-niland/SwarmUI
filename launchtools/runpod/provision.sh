#!/usr/bin/env bash
# One-time RunPod setup, run from your own machine. See README.md in this folder.
#   provision.sh datacenters     Suggest data centres for the volume that have RUNPOD_GPU_TYPE.
#   provision.sh volume          Create the network volume.
#   provision.sh setup          Start a setup pod that installs SwarmUI and the models onto the volume.
#   provision.sh delete POD_ID   Delete a pod, for example the setup pod when you're done with it.
#   provision.sh gpus            List Secure Cloud GPU type IDs, for RUNPOD_GPU_TYPE.
#   provision.sh pods            List this project's pods, to spot any that didn't delete themselves.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

load_env_file
require_vars RUNPOD_API_KEY

# Lists data centres that support network volumes and have any of the GPU types in stock now,
# in order of preference: Oceania, Asia, then North America with the US west coast first, then
# other regions. RunPod lists only GPU types that are in stock, so a data centre that has your
# GPU type but has none free at this moment doesn't appear. The IN STOCK NOW column shows each
# of your GPU types the data centre has free, in the order you listed them, for information only.
SUGGEST_DATA_CENTERS_PY=$(
    cat <<'PY'
import json, sys

gpus = [g.strip() for g in sys.argv[1].split(",") if g.strip()]
REGION_ORDER = ["OCEANIA", "ASIA", "NORTH_AMERICA"]
WEST_COAST_PREFIXES = ("US-CA-", "US-OR-", "US-WA-", "US-NV-", "US-AZ-", "US-UT-", "US-ID-", "CA-BC-")

rows = []
for dc in json.load(sys.stdin)["dataCenters"]:
    if not dc.get("networkVolumeTypes"):
        continue
    available = dc.get("gpuAvailability") or []
    in_stock = [
        f"{g['name']}:{g['availability']}"
        for gpu in gpus
        for g in available
        if gpu in (g.get("id"), g.get("name"))
    ]
    if not in_stock:
        continue
    region = dc["region"]
    region_rank = REGION_ORDER.index(region) if region in REGION_ORDER else len(REGION_ORDER)
    west_rank = 0 if dc["id"].startswith(WEST_COAST_PREFIXES) else 1
    rows.append((region_rank, west_rank, dc["id"], region, ", ".join(in_stock)))

if not rows:
    sys.exit(
        f"No data centre with network volumes has any of these GPU types in stock now: {', '.join(gpus)}.\n"
        "Stock changes within minutes. Try again later, or add more GPU types to RUNPOD_GPU_TYPE."
    )
print(f"{'ID':<12} {'REGION':<14} IN STOCK NOW")
for *_, dc_id, region, in_stock in sorted(rows):
    print(f"{dc_id:<12} {region:<14} {in_stock}")
PY
)

suggest_data_centers() {
    require_vars RUNPOD_GPU_TYPE
    runpod_api GET "/catalog/datacenters?include=GPU_AVAILABILITY" |
        python3 -c "$SUGGEST_DATA_CENTERS_PY" "$RUNPOD_GPU_TYPE"
}

create_volume() {
    if [ -n "${RUNPOD_NETWORK_VOLUME_ID:-}" ]; then
        echo "RUNPOD_NETWORK_VOLUME_ID is already set to $RUNPOD_NETWORK_VOLUME_ID, not creating another volume."
        return
    fi
    if [ -z "${RUNPOD_DATA_CENTER:-}" ]; then
        suggest_data_centers
        echo
        echo "Set RUNPOD_DATA_CENTER in your settings file to one of these IDs, then run this again."
        exit 1
    fi
    require_vars RUNPOD_NETWORK_VOLUME_SIZE_GB
    local response volume_id
    response=$(
        python3 -c 'import json, os; print(json.dumps({"name": "swarmui-models", "size": int(os.environ["RUNPOD_NETWORK_VOLUME_SIZE_GB"]), "dataCenter": os.environ["RUNPOD_DATA_CENTER"]}))' |
            runpod_api POST /network-volumes -
    )
    volume_id=$(json_field id <<<"$response")
    echo "Created network volume $volume_id."
    echo "Set RUNPOD_NETWORK_VOLUME_ID=$volume_id in your settings file."
}

start_setup_pod() {
    require_vars RUNPOD_NETWORK_VOLUME_ID RUNPOD_GPU_TYPE RUNPOD_IMAGE \
        RUNPOD_CONTAINER_DISK_GB SWARM_REPO_URL SWARM_REPO_BRANCH
    local script response pod_id
    script="set -e
if [ ! -d $WORKER_SWARM_DIR/.git ]; then
    git clone --branch \"\$SWARM_REPO_BRANCH\" \"\$SWARM_REPO_URL\" $WORKER_SWARM_DIR
fi
exec bash $WORKER_SWARM_DIR/launchtools/runpod/worker-setup.sh"
    response=$(create_pod "${POD_NAME_PREFIX}setup" "$script" SWARM_REPO_URL SWARM_REPO_BRANCH)
    pod_id=$(json_field id <<<"$response")
    echo "Started setup pod $pod_id. Follow its logs in the RunPod console."
    echo "When the logs say SwarmUI is ready, open $(proxy_url "$pod_id") and finish the installer."
    echo "Then delete the pod: $0 delete $pod_id"
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
        fields = {k: v for k, v in item.items() if k in ("id", "name", "status", "desiredStatus", "availability")}
        print(json.dumps(fields))
' "$1"
}

case "${1:-}" in
    datacenters) suggest_data_centers ;;
    volume) create_volume ;;
    setup) start_setup_pod ;;
    delete)
        runpod_api DELETE "/pods/${2:?Give the pod ID to delete}" >/dev/null
        echo "Deleted pod $2."
        ;;
    gpus) runpod_api GET "/catalog/gpus?include=AVAILABILITY&product=POD&cloud=SECURE" | print_items "" ;;
    pods) runpod_api GET /pods | print_items "$POD_NAME_PREFIX" ;;
    *)
        >&2 echo "Usage: $0 datacenters | volume | setup | delete POD_ID | gpus | pods"
        exit 1
        ;;
esac
