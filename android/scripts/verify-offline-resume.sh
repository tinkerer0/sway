#!/bin/sh
# 받아 두기: 앱 프로세스가 없는 상태에서 Wi-Fi가 생겼을 때의 동작을 본다. 격리 에뮬레이터 전용이며 기존 보관함은 백업했다가 되돌린다.
# Android 9~11: 데이터 요금이 없는 연결 조건의 예약(job 104)이 서비스를 다시 띄워 받는다.
# Android 12 이상: Media3가 예약을 쓰지 않으므로 받지 않고 기다리다가, 앱을 열면 이어 받는다.
set -eu
case "${1:-}" in emulator-*) ;; *) echo 'Usage: scripts/verify-offline-resume.sh emulator-<port> (격리 전용)' >&2; exit 2;; esac
cd "$(dirname "$0")/.."
adb_bin="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
serial=$1
a() { "$adb_bin" -s "$serial" "$@"; }
pkg=com.tinkerer0.sway
sdk=$(a shell getprop ro.build.version.sdk | tr -d '\r')
mkdir -p evidence/offline-resume
log=evidence/offline-resume/api$sdk.txt
: > "$log"
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$log"; }
kb() { a shell "run-as $pkg sh -c 'du -sk no_backup/offline 2>/dev/null | cut -f1'" | tr -d '\r'; }
pid() { a shell pidof $pkg | tr -d '\r'; }
library() { a shell "run-as $pkg sh -c 'rm -f no_backup/library.json.bak no_backup/library.json.new; cat > no_backup/library.json'"; }

say "sdk=$sdk serial=$serial"
a logcat -c
a shell am force-stop $pkg
a shell "run-as $pkg sh -c 'cp no_backup/library.json no_backup/library.json.resume-bak 2>/dev/null || true'"
cleanup() {
  # 앱을 받아 두기 없는 보관함으로 열면 sync가 받은 곡을 인덱스와 함께 지운다.
  a shell svc wifi enable; a shell svc data enable
  a shell am force-stop $pkg
  if a shell "run-as $pkg sh -c 'test -f no_backup/library.json.resume-bak'"; then
    a shell "run-as $pkg sh -c 'mv no_backup/library.json.resume-bak no_backup/library.json'"
  else
    printf '%s' '{"version":1,"saved":[],"recent":[],"stats":{},"wifiOnly":true,"playlists":[]}' | library
  fi
  a shell am start -W -n $pkg/.MainActivity > /dev/null; sleep 8
  say "cleanup offline_kb=$(kb)"
  a shell am force-stop $pkg
}
trap cleanup EXIT

say "before offline_kb=$(kb)"
printf '%s' '{"version":1,"saved":[{"id":"YE7VzlLtp-4","title":"Big Buck Bunny","artist":"Blender","duration":596,"artwork":""}],"recent":[],"stats":{},"wifiOnly":true,"playlists":[{"id":"resume-test","name":"재시작 시험","ids":["YE7VzlLtp-4"],"offline":true}]}' | library
a shell svc wifi disable; a shell svc data enable; sleep 15
say "metered: $(a shell dumpsys connectivity | grep -m1 -o 'Active default network: [0-9]*' || true)"
a shell am start -W -n $pkg/.MainActivity > /dev/null; sleep 10
a shell input keyevent KEYCODE_HOME; sleep 6
say "after open on mobile data: offline_kb=$(kb) pid=$(pid)"
a shell dumpsys jobscheduler | grep -E "#u0a[0-9]+/104[^0-9]" | head -3 | tee -a "$log" || true
a shell am kill $pkg; sleep 2
[ -n "$(pid)" ] && a shell "run-as $pkg kill -9 $(pid)" || true
sleep 2
say "killed: pid='$(pid)'"
a shell svc wifi enable
done_kb=9000
i=0; while [ $i -lt 18 ]; do sleep 10; i=$((i+1)); k=$(kb); say "wifi +$((i*10))s offline_kb=$k pid='$(pid)'"; [ "${k:-0}" -ge $done_kb ] && break; done
if [ "${k:-0}" -ge $done_kb ]; then
  say "RESULT: 앱을 열지 않고 받기 완료 (offline_kb=$k)"
else
  say "RESULT: 앱을 열기 전에는 받지 않음 (offline_kb=${k:-0}). 앱을 연다."
  a shell am start -W -n $pkg/.MainActivity > /dev/null
  i=0; while [ $i -lt 18 ]; do sleep 10; i=$((i+1)); k=$(kb); say "app open +$((i*10))s offline_kb=$k"; [ "${k:-0}" -ge $done_kb ] && break; done
  [ "${k:-0}" -ge $done_kb ] && say "RESULT: 앱을 연 뒤 이어 받기 완료 (offline_kb=$k)" || say "RESULT: FAIL 앱을 연 뒤에도 받지 못함"
fi
a shell logcat -d | grep -E "AudioDownloadService|PlatformScheduler|FATAL|ForegroundServiceStartNotAllowed" | tail -12 >> "$log" || true
