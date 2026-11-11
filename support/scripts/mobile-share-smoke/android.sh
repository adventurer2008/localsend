#!/usr/bin/env bash
set -euo pipefail
root="$GITHUB_WORKSPACE/support/scripts/mobile-share-smoke"
fixture="$RUNNER_TEMP/share-fixture"
mkdir -p "$fixture/classes" "$fixture/dex"
tools="$(dirname "$(find "$ANDROID_HOME/build-tools" -name d8 | sort -V | tail -1)")"
api="$ANDROID_HOME/platforms/android-35/android.jar"
javac -source 8 -target 8 -cp "$api" -d "$fixture/classes" "$root/ShareFixture.java"
jar cf "$fixture/classes.jar" -C "$fixture/classes" .
"$tools/d8" --min-api 24 --lib "$api" --output "$fixture/dex" "$fixture/classes.jar"
cat > "$fixture/AndroidManifest.xml" <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="org.localsend.sharefixture">
  <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="35" />
  <application android:label="LocalSend share fixture">
    <activity android:name=".ShareFixture" android:exported="true" />
    <provider android:name=".ShareFixture$Files" android:authorities="org.localsend.sharefixture.files" android:exported="false" android:grantUriPermissions="true" />
  </application>
</manifest>
XML
"$tools/aapt2" link -I "$api" --manifest "$fixture/AndroidManifest.xml" -o "$fixture/raw.apk"
zip -jq "$fixture/raw.apk" "$fixture/dex/classes.dex"
"$tools/zipalign" -f 4 "$fixture/raw.apk" "$fixture/aligned.apk"
keytool -genkeypair -keystore "$fixture/test.p12" -storepass fixture-test -alias fixture -keyalg RSA -keysize 2048 -dname CN=Fixture -validity 2
"$tools/apksigner" sign --ks "$fixture/test.p12" --ks-pass pass:fixture-test --out "$fixture/fixture.apk" "$fixture/aligned.apk"
adb install "$fixture/fixture.apk"
adb install "$RUNNER_TEMP/share-target/LocalSend-Remote-Android.apk"
adb shell am force-stop org.localsend.localsend_app.remote
verify_share() {
  local mode="$1" count="$2"
  adb shell am start -W -n org.localsend.sharefixture/.ShareFixture --es mode "$mode"
  for attempt in {1..12}; do
    adb shell uiautomator dump /sdcard/share-check.xml >/dev/null 2>&1 || true
    adb shell cat /sdcard/share-check.xml > "$fixture/window.xml" || true
    if grep -q "Files: $count" "$fixture/window.xml"; then
      echo "Share mode $mode populated the send selection with $count file(s)"
      return
    fi
    sleep 2
  done
  cat "$fixture/window.xml"
  adb logcat -d -s IncomingShare flutter AndroidRuntime | tail -110
  return 1
}
verify_share cold 1
adb shell am start -W -n org.localsend.sharefixture/.ShareFixture --es mode warm
sleep 4
adb shell uiautomator dump /sdcard/share-check.xml >/dev/null
adb shell cat /sdcard/share-check.xml > "$fixture/window.xml"
grep -q 'Files: 1' "$fixture/window.xml"
echo 'Build 67 failed to add the ClipData-only file to its send selection.'

