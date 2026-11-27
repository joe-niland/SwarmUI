#!/usr/bin/env bash
# Runs on the setup pod that provision.sh starts. Safe to run again: it skips finished steps.
# Installs .NET and the models onto the network volume, then starts SwarmUI so you can finish
# its installer in the browser.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
cd "$WORKER_SWARM_DIR"

git pull --ff-only

if [ ! -x .dotnet/dotnet ]; then
    ./launchtools/linux-dotnet-install.sh "$PWD/.dotnet"
fi

while read -r _flag path url; do
    case "$_flag" in
        '' | \#*) continue ;;
    esac
    mkdir -p "Models/$(dirname "$path")"
    echo "Downloading Models/$path"
    wget -nv -c -O "Models/$path" "$url"
done <"$SCRIPT_DIR/models.txt"

echo "SwarmUI is starting. When it's ready, open this pod's port $WORKER_PORT through the RunPod proxy."
./launch-linux.sh --launch_mode none --host 0.0.0.0
