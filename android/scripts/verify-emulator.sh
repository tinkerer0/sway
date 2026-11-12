#!/bin/sh
set -eu
case "${1:-}" in emulator-*) ;; *) echo 'Usage: scripts/verify-emulator.sh emulator-<port>'; exit 2;; esac
cd "$(dirname "$0")/.."
adb_bin="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
"$adb_bin" -s "$1" install -r -g app/build/outputs/apk/debug/app-debug.apk
"$adb_bin" -s "$1" install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
exec scripts/verify-streaming.sh "$1"
