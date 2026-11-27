#!/bin/sh
# Builds the hardened release and installs it in /Applications.
set -e
cd "$(dirname "$0")/.."
xcodegen generate
# Optional, never committed: SIGN_IDENTITY="Apple Development" and TEAM=XXXXXXXXXX
[ -f Tools/local.env ] && . Tools/local.env
xcodebuild -project FaceUnlock.xcodeproj -scheme FaceUnlock -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build -quiet build \
  CODE_SIGN_IDENTITY="${SIGN_IDENTITY:--}" DEVELOPMENT_TEAM="${TEAM:-}"
pkill -x FaceUnlock || true
rm -rf /Applications/FaceUnlock.app
ditto build/Build/Products/Release/FaceUnlock.app /Applications/FaceUnlock.app
open /Applications/FaceUnlock.app
