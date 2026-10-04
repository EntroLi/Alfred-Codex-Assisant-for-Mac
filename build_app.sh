#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/module-cache"
# Do not embed this machine's source directory in shared binaries.
swift build --disable-sandbox -c release -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=." -Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=."
mkdir -p "$ROOT_DIR/.staging"
RELEASE_DIR="$(mktemp -d "$ROOT_DIR/.staging/release.XXXXXX")"
APP_NAME="$(python3 -c 'import json; print(json.load(open("VERSION.json"))["displayName"])')"
APP_DIR="$RELEASE_DIR/$APP_NAME.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/SuiAssistant "$APP_DIR/Contents/MacOS/SuiAssistant"
# Linker debug symbols can retain absolute object paths even after Swift prefix mapping.
xcrun strip -S "$APP_DIR/Contents/MacOS/SuiAssistant"
cp -R Resources/. "$APP_DIR/Contents/Resources/"
python3 tools/package_info.py "$APP_DIR"
WIDGET_DIR="$APP_DIR/Contents/PlugIns/AlfredDesktop.appex"
mkdir -p "$WIDGET_DIR/Contents/MacOS"
xcrun swiftc -O -file-prefix-map "$ROOT_DIR=." -debug-prefix-map "$ROOT_DIR=." -parse-as-library -application-extension -D ALFRED_WIDGET -target arm64-apple-macosx14.0 Sources/CodexQuotaBar/DesktopWidgetSnapshot.swift Sources/CodexQuotaBar/DesktopWidgetView.swift Widget/AlfredDesktopWidget.swift -framework Foundation -Xlinker -e -Xlinker _NSExtensionMain -o "$WIDGET_DIR/Contents/MacOS/AlfredDesktop"
python3 tools/package_widget.py "$WIDGET_DIR"
xcrun strip -S "$WIDGET_DIR/Contents/MacOS/AlfredDesktop"
codesign --force --sign - --entitlements Widget/display-snapshot-entitlements.plist "$WIDGET_DIR"
codesign --force --sign - "$APP_DIR"
python3 tools/verify_app.py "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf '%s\n' "$APP_DIR" > .staging/latest-path.txt
printf '暂存发布包：%s\n' "$APP_DIR"
