#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
iconset="$temp/AppIcon.iconset"
mkdir "$iconset"

for spec in '16 16 icon_16x16.png' '32 32 icon_16x16@2x.png' '32 32 icon_32x32.png' '64 64 icon_32x32@2x.png' '128 128 icon_128x128.png' '256 256 icon_128x128@2x.png' '256 256 icon_256x256.png' '512 512 icon_256x256@2x.png' '512 512 icon_512x512.png' '1024 1024 icon_512x512@2x.png'; do
  read -r width height name <<<"$spec"
  sips -z "$height" "$width" "$root/Packaging/AppIcon.png" --out "$iconset/$name" >/dev/null
done

iconutil -c icns "$iconset" -o "$root/Packaging/AppIcon.icns"
