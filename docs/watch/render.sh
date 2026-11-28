#!/bin/bash
# Renders each board in mockups.html to a PNG beside it, with headless Chrome.
#   docs/watch/render.sh            all boards
#   docs/watch/render.sh tv-remote  one
set -euo pipefail
cd "$(dirname "$0")"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# board  width  height
boards=(
  "now-playing-sizes 760 440"
  "music-flow 1040 480"
  "start-music 1040 470"
  "tv-remote 1040 470"
  "navigation 1000 500"
  "complications 1040 480"
  "phone-settings 780 830"
)
for entry in "${boards[@]}"; do
  read -r board width height <<<"$entry"
  [[ $# -gt 0 && " $* " != *" $board "* ]] && continue
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size="$width,$height" --screenshot="$PWD/$board.png" \
    "file://$PWD/mockups.html#$board" >/dev/null 2>&1
  echo "$board.png"
done
