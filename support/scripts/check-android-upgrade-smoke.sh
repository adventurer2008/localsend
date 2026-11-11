#!/usr/bin/env bash
set -euo pipefail
package=org.localsend.localsend_app.remote
activity="$package/org.localsend.localsend_app.MainActivity"
smoke="$GITHUB_WORKSPACE/support/scripts/check-native-receive-smoke.sh"
adb install "$RUNNER_TEMP/remote-66/LocalSend-Remote-Android.apk"
adb shell am start -W -n "$activity"
adb forward tcp:53317 tcp:53317
bash "$smoke" "$RUNNER_TEMP/identity-before"
adb install -r "$RUNNER_TEMP/remote-67/LocalSend-Remote-Android.apk"
adb shell am start -W -n "$activity"
adb shell dumpsys package "$package" | grep -E 'versionCode=67\b'
bash "$smoke" "$RUNNER_TEMP/identity-after"
cmp "$RUNNER_TEMP/identity-before" "$RUNNER_TEMP/identity-after"
echo 'Build 67 started after replacing build 66 and retained the LAN identity.'

