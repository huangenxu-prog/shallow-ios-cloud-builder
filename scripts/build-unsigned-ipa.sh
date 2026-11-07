#!/bin/bash
set -euo pipefail

PROJECT_DIR="${1:?Missing project directory}"
SCHEME="${2:-SFI}"

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
mkdir -p "$DIAG_DIR/dSYMs"

# Preserve the archive's dSYM bundles for symbolication.
if [[ -d "$BUILD_DIR/SFI.xcarchive/dSYMs" ]]; then
    cp -R "$BUILD_DIR/SFI.xcarchive/dSYMs/." "$DIAG_DIR/dSYMs/"
fi

# Record bundle identifiers and relevant runtime configuration from every app bundle.
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
    echo
    echo "Xcode archive bundle inventory:"
    cat "$DIAG_DIR/bundle-inventory.txt"
    echo
    echo "dSYM UUIDs:"
    if compgen -G "$DIAG_DIR/dSYMs/*.dSYM" > /dev/null; then
        find "$DIAG_DIR/dSYMs" -name DWARF -type d -maxdepth 4 -print0 |
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
