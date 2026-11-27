#!/usr/bin/env bash
# Writes a header-only copy of each "stub" model in models.txt into the local Models/ folder.
# The local SwarmUI reads model details from the header alone, so it can list these models and
# send jobs for them while no worker is running. The real files live on the network volume.
# Existing files are left alone.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
MODELS_DIR="${1:-$SCRIPT_DIR/../../Models}"
# A safetensors file starts with an 8-byte little-endian header length.
LENGTH_BYTES=8
# Stops curl downloading a whole model if a server ignores the byte range.
MAX_HEADER_BYTES=100000000

fetch_range() {
    curl -sSfL --max-filesize "$MAX_HEADER_BYTES" -r "0-$(($2 - 1))" "$1"
}

while read -r flag path url; do
    if [ "$flag" != "stub" ]; then
        continue
    fi
    dest="$MODELS_DIR/$path"
    if [ -e "$dest" ]; then
        echo "Skipping $path: already exists"
        continue
    fi
    header_length=$(fetch_range "$url" "$LENGTH_BYTES" | od -An -t u8 | tr -d ' ')
    total=$((LENGTH_BYTES + header_length))
    mkdir -p "$(dirname "$dest")"
    fetch_range "$url" "$total" >"$dest.tmp"
    if [ "$(wc -c <"$dest.tmp" | tr -d ' ')" != "$total" ]; then
        >&2 echo "Unexpected size for $path, the server may not support byte ranges."
        exit 1
    fi
    mv "$dest.tmp" "$dest"
    echo "Wrote stub $path ($total bytes)"
done <"$SCRIPT_DIR/models.txt"
