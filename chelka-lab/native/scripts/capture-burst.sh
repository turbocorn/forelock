#!/bin/zsh
set -euo pipefail
output_dir=$1
frame_count=${2:-80}
mkdir -p "$output_dir"
for ((frame_index=0; frame_index<frame_count; frame_index++)); do
  frame_path="$output_dir/frame-$(printf '%03d' "$frame_index").png"
  /usr/sbin/screencapture -x -R0,0,1800,400 "$frame_path"
  sleep 0.04
done
printf 'Captured %s real display frames\n' "$frame_count"
