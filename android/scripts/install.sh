#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/install.sh <adb-device-serial>' >&2
  exit 2
fi
cd "$(dirname "$0")/.."
adb_bin="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
test -x "$adb_bin" || adb_bin=adb
apk=app/build/outputs/apk/debug/app-debug.apk
"$adb_bin" -s "$1" install -r "$apk"
"$adb_bin" -s "$1" shell am start -n com.tinkerer0.sway/.MainActivity
