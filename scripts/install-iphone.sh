#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if (( $# != 1 )); then
  print -u2 '사용법: scripts/install-iphone.sh <device-identifier>'
  print -u2 '기기 확인: xcrun devicectl list devices'
  exit 2
fi
xcodegen generate
xcodebuild -project Sway.xcodeproj -scheme Sway -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath .build/device \
  -allowProvisioningUpdates build
codesign --verify --deep --strict .build/device/Build/Products/Release-iphoneos/Sway.app
xcrun devicectl device install app --device "$1" .build/device/Build/Products/Release-iphoneos/Sway.app
xcrun devicectl device process launch --device "$1" com.tinkerer0.solomusic
