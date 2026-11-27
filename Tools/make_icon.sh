#!/bin/sh
# Regenerates the icon layers, then, if the website folder sits next to this one,
# its copies using Apple's own renderer (needs Xcode).
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
swiftc -parse-as-library Tools/make_icon.swift -o "$tmp/make_icon"
"$tmp/make_icon" Resources/AppIcon.icon/Assets
site=../faceunlock-website/website/assets
[ -d "$site" ] || exit 0
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
for pair in "icon.png 512" "favicon.png 64"; do
  set -- $pair
  "$ictool" Resources/AppIcon.icon --export-image --output-file "$site/$1" \
    --platform macOS --rendition Default --width "$2" --height "$2" --scale 1
done
"$ictool" Resources/AppIcon.icon --export-image --output-file "$tmp/tile.png" \
  --platform macOS --rendition Default --width 412 --height 412 --scale 1
swift Tools/pad_icon.swift "$tmp/tile.png" "$site/mac/faceunlock.png"
