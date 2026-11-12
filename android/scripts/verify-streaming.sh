#!/bin/sh
set -eu
case "${1:-}" in emulator-*) ;; *) echo 'Usage: scripts/verify-streaming.sh emulator-<port> (격리 전용)' >&2; exit 2;; esac
cd "$(dirname "$0")/.."
adb_bin="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
serial=$1
mkdir -p evidence/streaming/final
run_test() {
 name=$1
 klass=$2
 "$adb_bin" -s "$serial" shell am instrument -w -e class "$klass" com.tinkerer0.sway.test/androidx.test.runner.AndroidJUnitRunner > "evidence/streaming/final/$name.txt" 2>&1
 if ! rg -q '^OK \([0-9]+ tests?\)' "evidence/streaming/final/$name.txt" || rg -q 'INSTRUMENTATION_STATUS_CODE: -[234]|FAILURES|Process crashed' "evidence/streaming/final/$name.txt"; then cat "evidence/streaming/final/$name.txt"; exit 1; fi
 rg '^OK \(' "evidence/streaming/final/$name.txt"
}
# upgrade 검사는 README의 v1 fixture 설치 후 별도 수행한다. 기존 보관함을 초기화하지 않는다.
run_test library com.tinkerer0.sway.LibraryTest
run_test refresh com.tinkerer0.sway.RefreshingSourceTest
run_test policy com.tinkerer0.sway.StreamingPolicyTest
run_test cache com.tinkerer0.sway.AudioCacheTest
run_test queue com.tinkerer0.sway.MixQueueTest
run_test stream 'com.tinkerer0.sway.LiveAudioTest#searchStreamAndBackgroundControlsWithoutAudioFiles'
"$adb_bin" -s "$serial" shell am force-stop com.tinkerer0.sway
run_test restore 'com.tinkerer0.sway.LiveAudioTest#restoreQueueWithoutPrefetch'
run_test offline 'com.tinkerer0.sway.LiveAudioTest#offlineNewStreamFailsWithoutPretendingDownloaded'
run_test cached 'com.tinkerer0.sway.LiveAudioTest#completeCachedTrackPlaysOfflineWithoutNetwork'
run_test stale 'com.tinkerer0.sway.LiveAudioTest#staleCachedFormatIsDroppedAndRefetchedOnce'
run_test nosave 'com.tinkerer0.sway.LiveAudioTest#noSaveModeWritesNothingAndDropsPreviousTrack'
run_test download 'com.tinkerer0.sway.LiveAudioTest#offlinePlaylistWaitsForWifiThenPlaysWithoutNetwork'
run_test download-home 'com.tinkerer0.sway.LiveAudioTest#offlineResumesOnWifiAfterLeavingApp'
run_test mix 'com.tinkerer0.sway.LiveAudioTest#liveMixAndDiscoveryCandidates'
run_test mvmix 'com.tinkerer0.sway.LiveAudioTest#liveMixFromMusicVideoFallsBackToOfficialAudio'
run_test ui com.tinkerer0.sway.UiSmokeTest
"$adb_bin" -s "$serial" logcat -d -s SwayStreamTest:I > evidence/streaming/final/runtime.txt
echo 'PASS: streaming suite (34 tests)'
