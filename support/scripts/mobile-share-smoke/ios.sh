#!/usr/bin/env bash
set -euo pipefail
simulator="$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(item["udid"] for runtime in reversed(list(d)) for item in d[runtime] if item["name"].startswith("iPhone")))' )"
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
app="$GITHUB_WORKSPACE/app/build/ios/iphonesimulator/Runner.app"
test -d "$app/PlugIns/ShareExtension.appex"
entitlements="$RUNNER_TEMP/share-smoke.entitlements"
cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array><string>group.org.localsend.localsendApp</string></array>
</dict>
</plist>
PLIST
codesign --force --sign - --generate-entitlement-der --entitlements "$entitlements" "$app/PlugIns/ShareExtension.appex"
codesign --force --sign - --generate-entitlement-der --entitlements "$entitlements" "$app"
codesign -d --entitlements - "$app"

xcrun simctl install "$simulator" "$app"
bundle="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"
xcrun simctl get_app_container "$simulator" "$bundle" groups
group="$(xcrun simctl get_app_container "$simulator" "$bundle" group.org.localsend.localsendApp)"
inbox="$group/IncomingShares/smoke"
mkdir -p "$inbox/0"
printf 'LocalSend test file\n' > "$inbox/0/shared.txt"
printf '{"paths":["0/shared.txt"],"text":"","failed":0}\n' > "$inbox/manifest.json"
xcrun simctl launch "$simulator" "$bundle"
for attempt in {1..30}; do
  if [[ ! -f "$inbox/manifest.json" ]]; then
    echo 'iOS host consumed the queued share after launch.'
    exit 0
  fi
  sleep 2
done
echo 'iOS host did not consume the queued share.' >&2
exit 1

