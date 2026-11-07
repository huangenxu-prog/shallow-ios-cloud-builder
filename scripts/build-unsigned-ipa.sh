#!/bin/bash
set -euo pipefail

PROJECT_DIR="${1:-.}"
SCHEME="${2:?请提供 Xcode Scheme 名称}"

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
OUTPUT_DIR="$GITHUB_WORKSPACE/output"
BUILD_DIR="$RUNNER_TEMP/ios-build"

mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"

echo "项目目录：$PROJECT_DIR"
echo "构建 Scheme：$SCHEME"

# 优先使用 Xcode Workspace，否则使用 Xcode Project
WORKSPACE="$(find "$PROJECT_DIR" -maxdepth 1 -name '*.xcworkspace' -print -quit)"
PROJECT="$(find "$PROJECT_DIR" -maxdepth 1 -name '*.xcodeproj' -print -quit)"

if [[ -n "$WORKSPACE" ]]; then
    PROJECT_OPTION=(-workspace "$WORKSPACE")
elif [[ -n "$PROJECT" ]]; then
    PROJECT_OPTION=(-project "$PROJECT")
else
    echo "错误：没有找到 .xcworkspace 或 .xcodeproj"
    exit 1
fi

echo "开始编译..."

xcodebuild archive \
    "${PROJECT_OPTION[@]}" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$BUILD_DIR/App.xcarchive" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_IDENTITY="" \
    | tee "$BUILD_DIR/build.log" \
    | xcbeautify || {
        echo "编译失败，请检查构建日志"
        exit 1
    }

APP_PATH="$BUILD_DIR/App.xcarchive/Products/Applications"

APP="$(find "$APP_PATH" -maxdepth 1 -name '*.app' -print -quit)"

if [[ -z "$APP" ]]; then
    echo "错误：Archive 中没有找到 .app"
    exit 1
fi

# 将未签名 App 打包为 IPA
PACKAGE_DIR="$BUILD_DIR/package"
mkdir -p "$PACKAGE_DIR/Payload"
cp -R "$APP" "$PACKAGE_DIR/Payload/"

APP_NAME="$(basename "$APP" .app)"
IPA_PATH="$OUTPUT_DIR/${APP_NAME}-unsigned.ipa"

cd "$PACKAGE_DIR"
zip -qr "$IPA_PATH" Payload

echo "构建完成：$IPA_PATH"
