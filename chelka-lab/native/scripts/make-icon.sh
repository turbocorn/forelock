#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
iconset="$project_dir/.build/AppIcon.iconset"
mkdir -p "$iconset"
swift -module-cache-path "$project_dir/.build/module-cache" "$project_dir/scripts/make-icon.swift" "$project_dir/.build/icon-1024.png"
for dimension in 16 32 128 256 512; do
  sips -z "$dimension" "$dimension" "$project_dir/.build/icon-1024.png" --out "$iconset/icon_${dimension}x${dimension}.png" >/dev/null
  retina=$((dimension * 2))
  sips -z "$retina" "$retina" "$project_dir/.build/icon-1024.png" --out "$iconset/icon_${dimension}x${dimension}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$project_dir/Resources/AppIcon.icns"
