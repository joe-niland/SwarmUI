#!/usr/bin/env bash
# Runs on the setup pod that provision.sh starts, from the local install in LOCAL_SWARM_DIR.
# Safe to run again: it updates the existing install and skips finished downloads.
# 1. Updates SwarmUI from git and installs .NET.
# 2. Downloads the models in models.txt onto the global volume.
# 3. Starts SwarmUI so you can finish its installer in the browser. Shut it down from its UI to go on.
# 4. Packs the install onto the volume, copies these scripts there and deletes this pod.
# If a step fails, the pod stays up so you can read its logs.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
require_vars SWARM_RUNPOD_API_KEY RUNPOD_POD_ID
RUNPOD_API_KEY="$SWARM_RUNPOD_API_KEY"

# Logs how full the pod's disk is and what uses it, to size RUNPOD_CONTAINER_DISK_GB.
report_disk() {
    df -h /
    du -xsh "$LOCAL_SWARM_DIR" "$LOCAL_SWARM_DIR/dlbackend" "$HOME/.cache" "$HOME/.nuget" 2>/dev/null || true
}

keep_pod_on_failure() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        report_disk
        >&2 echo "Setup failed. This pod stays up so you can read its logs."
        >&2 echo "Delete it when you're done: provision.sh delete $RUNPOD_POD_ID"
        sleep infinity
    fi
}
trap keep_pod_on_failure EXIT

cd "$LOCAL_SWARM_DIR"
git pull --ff-only

if [ ! -x .dotnet/dotnet ]; then
    ./launchtools/linux-dotnet-install.sh "$PWD/.dotnet"
fi

while read -r _flag path url; do
    case "$_flag" in
        '' | \#*) continue ;;
    esac
    mkdir -p "$VOLUME_MODELS_DIR/$(dirname "$path")"
    echo "Downloading $path"
    wget -nv -c -O "$VOLUME_MODELS_DIR/$path" "$url"
done <"$SCRIPT_DIR/models.txt"
link_models

echo "SwarmUI is starting. When it's ready, open this pod's port $WORKER_PORT through the RunPod proxy."
echo "When you've finished setting it up, click Shutdown Server under Server → Server Info to save the install."
./launch-linux.sh --launch_mode none --host 0.0.0.0

report_disk
install_name=$(basename "$LOCAL_SWARM_DIR")
echo "Packing the install into $INSTALL_ARCHIVE"
SECONDS=0
tar -cf "$INSTALL_ARCHIVE" -C "$(dirname "$LOCAL_SWARM_DIR")" \
    --exclude="$install_name/Models" --exclude="$install_name/Output" "$install_name"
echo "Packed in $SECONDS seconds."
mkdir -p "$VOLUME_SCRIPTS_DIR"
cp "$SCRIPT_DIR/common.sh" "$SCRIPT_DIR/worker-start.sh" "$VOLUME_SCRIPTS_DIR/"

echo "Setup finished. Deleting this pod."
runpod_api DELETE "/pods/$RUNPOD_POD_ID" >/dev/null
