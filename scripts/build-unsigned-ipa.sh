#!/bin/bash
set -euo pipefail

PROJECT_DIR="${1:?Missing project directory}"
SCHEME="${2:-SFI}"

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
OUTPUT_DIR="$GITHUB_WORKSPACE/output"
BUILD_DIR="$RUNNER_TEMP/sing-box-ios-build"

mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"

cd "$PROJECT_DIR"

# Work around an iOS launch crash in the Go/PLCrashReporter signal-handler
# chaining path. The uploaded crash log shows SIGTRAP raised from Library.framework
# during process launch. Keep the Go runtime's default handlers and skip the
# custom signal-handler installation in both the app and packet-tunnel provider.
python3 - "$PROJECT_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

app_delegate = root / "SFI" / "ApplicationDelegate.swift"
app_text = app_delegate.read_text()
for call in (
    "LibboxPrepareCrashSignalHandlers()",
    "NativeCrashReporter.installForCurrentProcess()",
    "LibboxReinstallCrashSignalHandlers()",
):
    if call not in app_text:
        raise SystemExit(f"Expected crash-handler call not found in {app_delegate}: {call}")
    app_text = app_text.replace(
        call,
        "// Temporarily disabled: avoid launch-time SIGTRAP in crash-handler chaining.",
        1,
    )
app_delegate.write_text(app_text)

extension_provider = root / "Library" / "Network" / "ExtensionProvider.swift"
ext_text = extension_provider.read_text()
pattern = re.compile(
    r"(?ms)^    override public init\(\) \{.*?^    \}"
)
replacement = """    override public init() {
        // Temporarily disabled: avoid signal-handler chaining crash in the
        // embedded Go runtime / PLCrashReporter path.
        super.init()
    }"""
ext_text, count = pattern.subn(replacement, ext_text, count=1)
if count != 1:
    raise SystemExit(f"Could not safely patch ExtensionProvider initializer in {extension_provider}")
extension_provider.write_text(ext_text)

print("Applied launch-crash workaround to ApplicationDelegate and ExtensionProvider.")
PY

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

PACKAGE_DIR="$BUILD_DIR/package"
mkdir -p "$PACKAGE_DIR/Payload"
cp -R "$APP" "$PACKAGE_DIR/Payload/"

cd "$PACKAGE_DIR"
zip -qr "$OUTPUT_DIR/sing-box-unsigned.ipa" Payload

echo "IPA created: $OUTPUT_DIR/sing-box-unsigned.ipa"
