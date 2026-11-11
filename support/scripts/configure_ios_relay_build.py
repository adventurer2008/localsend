"""Configure the Codemagic checkout for a signed iPhone relay test build."""

import os
import plistlib
import re
from pathlib import Path


bundle_id = os.environ.get("IOS_RELAY_BUNDLE_ID", "")
if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
    raise SystemExit("Set IOS_RELAY_BUNDLE_ID to your registered Runner Bundle ID.")

original_bundle_id = "org.localsend.localsendApp"
if bundle_id.lower() == original_bundle_id.lower():
    raise SystemExit("Use a Bundle ID registered to your Apple Developer team.")

app = Path(__file__).resolve().parents[2] / "app"
ios = app / "ios"
original_group = f"group.{original_bundle_id}"
app_group = f"group.{bundle_id}"

project = ios / "Runner.xcodeproj/project.pbxproj"
project_text = project.read_text(encoding="utf-8")
project_text, replacements = re.subn(
    rf"(PRODUCT_BUNDLE_IDENTIFIER = ){re.escape(original_bundle_id)}(\.ShareExtension)?;",
    lambda match: f"{match[1]}{bundle_id}{match[2] or ''};",
    project_text,
)
if replacements != 6:
    raise SystemExit("Expected Runner and ShareExtension Bundle IDs for all three build configurations.")
project.write_text(
    re.sub(r"^\s*DEVELOPMENT_TEAM = 3W7H4PYMCV;\n", "", project_text, flags=re.MULTILINE),
    encoding="utf-8",
)

for target in ("Runner", "ShareExtension"):
    entitlements_path = ios / target / f"{target}.entitlements"
    entitlements = plistlib.loads(entitlements_path.read_bytes())
    entitlements["com.apple.security.application-groups"] = [app_group]
    entitlements.pop("com.apple.developer.networking.multicast", None)
    entitlements.pop("aps-environment", None)
    entitlements_path.write_bytes(plistlib.dumps(entitlements))

for path in (
    ios / "ShareExtension/ShareViewController.swift",
    app / "lib/util/native/cache_helper.dart",
    app / "lib/util/native/incoming_share.dart",
):
    source = path.read_text(encoding="utf-8")
    if original_group not in source:
        raise SystemExit(f"Expected the upstream App Group in {path}.")
    path.write_text(source.replace(original_group, app_group), encoding="utf-8")
