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
IPHONEOS_DEPLOYMENT_TARGET=16.0 \
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
