#!/bin/bash
set -euo pipefail

PROJECT_DIR="\${1:?Missing project directory}"
SCHEME="\${2:-SFI}"

# Keep the bundle IDs, Info.plist values and signing entitlements aligned.
BASE_PACKAGE_IDENTIFIER="\${BASE_PACKAGE_IDENTIFIER:-io.nekohasekai.sfamt1}"
APP_GROUP_IDENTIFIER="\${APP_GROUP_IDENTIFIER:-group.\${BASE_PACKAGE_IDENTIFIER}}"

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
OUTPUT_DIR="$GITHUB_WORKSPACE/output"
BUILD_DIR="$RUNNER_TEMP/sing-box-ios-build"

mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"

cd "$PROJECT_DIR"

echo "Resolving Xcode packages..."
xcodebuild -resolvePackageDependencies \
    -project sing-box.xcodeproj \
    -scheme "$SCHEME"

echo "Cleaning..."
xcodebuild clean \
    -project sing-box.xcodeproj \
    -scheme "$SCHEME" \
    -derivedDataPath "$BUILD_DIR/DerivedData"

echo "Archiving..."
set -o pipefail

xcodebuild archive \
    -project sing-box.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$BUILD_DIR/SFI.xcarchive" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -skipPackagePluginValidation \
    BASE_PACKAGE_IDENTIFIER="$BASE_PACKAGE_IDENTIFIER" \
    APP_GROUP_IDENTIFIER="$APP_GROUP_IDENTIFIER" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    2>&1 | tee "$BUILD_DIR/build.log"

APP="$BUILD_DIR/SFI.xcarchive/Products/Applications/sing-box.app"

if [[ ! -d "$APP" ]]; then
    echo "ERROR: sing-box.app not found in archive"
    exit 1
fi

DIAG_DIR="$OUTPUT_DIR/diagnostics"
DSYM_DIR="$DIAG_DIR/dSYMs"
ENTITLEMENTS_DIR="$OUTPUT_DIR/signing-entitlements"
mkdir -p "$DSYM_DIR" "$ENTITLEMENTS_DIR"

# Preserve dSYMs so future crash logs can be symbolicated against this exact build.
if [[ -d "$BUILD_DIR/SFI.xcarchive/dSYMs" ]]; then
    cp -R "$BUILD_DIR/SFI.xcarchive/dSYMs/." "$DSYM_DIR/"
fi

# Export resolved entitlements separately. The IPA is unsigned, so these are not
# embedded in its code signatures and must be applied by the user's signing tool.
python3 - "$PROJECT_DIR" "$ENTITLEMENTS_DIR" "$BASE_PACKAGE_IDENTIFIER" "$APP_GROUP_IDENTIFIER" <<'PY'
import plistlib
import sys
from pathlib import Path

project = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
base_id = sys.argv[3]
group_id = sys.argv[4]

targets = {
    "SFI/SFI.entitlements": "sing-box.app.entitlements.plist",
    "Extension/Extension.entitlements": "Extension.appex.entitlements.plist",
    "ShareExtension/ShareExtension.entitlements": "ShareExtension.appex.entitlements.plist",
    "ActionExtension/ActionExtension.entitlements": "ActionExtension.appex.entitlements.plist",
    "IntentsExtension/IntentsExtension.entitlements": "IntentsExtension.appex.entitlements.plist",
    "WidgetExtension/WidgetExtension.entitlements": "WidgetExtension.appex.entitlements.plist",
    "FileProviderExtension/FileProviderExtension.entitlements": "FileProviderExtension.appex.entitlements.plist",
}

def resolve(value):
    if isinstance(value, str):
        return value.replace("$(BASE_PACKAGE_IDENTIFIER)", base_id).replace("$(APP_GROUP_IDENTIFIER)", group_id)
    if isinstance(value, list):
        return [resolve(item) for item in value]
    if isinstance(value, dict):
        return {key: resolve(item) for key, item in value.items()}
    return value

for source, filename in targets.items():
    path = project / source
    if not path.is_file():
        continue
    data = plistlib.loads(path.read_bytes())
    resolved = resolve(data)
    destination = out_dir / filename
    destination.write_bytes(plistlib.dumps(resolved, fmt=plistlib.FMT_XML, sort_keys=True))
    print(f"Exported {source} -> {destination}")

(out_dir / "README.txt").write_text(
    "Unsigned sing-box iOS IPA signing notes\n"
    "=======================================\n"
    f"Base bundle identifier: {base_id}\n"
    f"App Group identifier: {group_id}\n\n"
    "Apply the matching entitlement plist to each bundle when signing:\n"
    "- sing-box.app.entitlements.plist -> Payload/sing-box.app\n"
    "- Extension.appex.entitlements.plist -> Payload/sing-box.app/PlugIns/Extension.appex\n"
    "- ShareExtension.appex.entitlements.plist -> matching ShareExtension.appex, if present\n"
    "- ActionExtension.appex.entitlements.plist -> matching ActionExtension.appex, if present\n"
    "- IntentsExtension.appex.entitlements.plist -> matching IntentsExtension.appex, if present\n"
    "- WidgetExtension.appex.entitlements.plist -> matching WidgetExtension.appex, if present\n"
    "- FileProviderExtension.appex.entitlements.plist -> matching FileProviderExtension.appex, if present\n\n"
    "The provisioning profile used for signing must authorize the App Group and Network Extension\n"
    "capabilities. Info.plist values alone do not grant these capabilities. The app's FilePath\n"
    "initialization force-unwraps the App Group container URL, so a missing App Group entitlement\n"
    "can cause an immediate launch crash.\n"
)

(out_dir / "signing-summary.txt").write_text(
    f"BASE_PACKAGE_IDENTIFIER={base_id}\nAPP_GROUP_IDENTIFIER={group_id}\n"
)
PY

# Record bundle identifiers and runtime configuration for every bundle in the archive.
python3 - "$APP" "$DIAG_DIR/bundle-inventory.txt" <<'PY'
import plistlib
import sys
from pathlib import Path

app = Path(sys.argv[1])
out = Path(sys.argv[2])
keys = (
    "CFBundleIdentifier",
    "CFBundleExecutable",
    "CFBundlePackageType",
    "BasePackageIdentifier",
    "AppGroupIdentifier",
    "NSExtension",
    "MinimumOSVersion",
)
with out.open("w") as stream:
    for info in sorted(app.rglob("Info.plist")):
        try:
            data = plistlib.loads(info.read_bytes())
        except Exception as exc:
            stream.write(f"{info}: plist read failed: {exc}\n")
            continue
        if data.get("CFBundleIdentifier") or data.get("NSExtension"):
            stream.write(f"\n[{info.relative_to(app)}]\n")
            for key in keys:
                if key in data:
                    stream.write(f"{key} = {data[key]!r}\n")
PY

{
    echo "Archive: $BUILD_DIR/SFI.xcarchive"
    echo "App: $APP"
    echo "BASE_PACKAGE_IDENTIFIER=$BASE_PACKAGE_IDENTIFIER"
    echo "APP_GROUP_IDENTIFIER=$APP_GROUP_IDENTIFIER"
    echo
    echo "Xcode archive bundle inventory:"
    cat "$DIAG_DIR/bundle-inventory.txt"
    echo
    echo "dSYM UUIDs:"
    if find "$DSYM_DIR" -name '*.dSYM' -type d -print -quit | grep -q .; then
        find "$DSYM_DIR" -name DWARF -type d -maxdepth 4 -print0 |
        while IFS= read -r -d '' dwarf_dir; do
            find "$dwarf_dir" -maxdepth 1 -type f -exec dwarfdump --uuid {} \;
        done
    else
        echo "No dSYM bundles found in archive."
    fi
} > "$DIAG_DIR/build-diagnostics.txt"

PACKAGE_DIR="$BUILD_DIR/package"
mkdir -p "$PACKAGE_DIR/Payload"
cp -R "$APP" "$PACKAGE_DIR/Payload/"

cd "$PACKAGE_DIR"
zip -qr "$OUTPUT_DIR/sing-box-unsigned.ipa" Payload

echo "IPA created: $OUTPUT_DIR/sing-box-unsigned.ipa"
echo "Signing entitlements: $ENTITLEMENTS_DIR"
echo "Crash diagnostics: $DIAG_DIR"
