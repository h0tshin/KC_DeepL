#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="KCDeepL"
BUNDLE_ID="com.h0tshin.KCDeepL"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
STAGING_ROOT="${TMPDIR:-/tmp}/KCDeepL-build.$$"
STAGING_BUNDLE="$STAGING_ROOT/$APP_NAME.app"
APP_CONTENTS="$STAGING_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Sources/App/Resources/AppIcon.icns"
MENU_BAR_ICON_SOURCE="$ROOT_DIR/Sources/App/Resources/MenuBarIcon.png"
CODESIGN_IDENTITY="${KCDEEPL_CODESIGN_IDENTITY:-}"

if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk '$1 ~ /^[0-9]+\)$/ { print $2; exit }'
  )"
fi

if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="-"
fi

cd "$ROOT_DIR"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$STAGING_ROOT"
trap 'rm -rf "$STAGING_ROOT"' EXIT
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
fi

if [[ -f "$MENU_BAR_ICON_SOURCE" ]]; then
  cp "$MENU_BAR_ICON_SOURCE" "$APP_RESOURCES/MenuBarIcon.png"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>KC DeepL</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Live 번역에서 사용자의 마이크 음성을 실시간으로 통역하기 위해 필요합니다.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/xattr -cr "$STAGING_BUNDLE"
codesign \
  --force \
  --deep \
  --sign "$CODESIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  "$STAGING_BUNDLE"
/usr/bin/xattr -cr "$STAGING_BUNDLE"
codesign --verify --deep --strict "$STAGING_BUNDLE"

rm -rf "$APP_BUNDLE"
mv "$STAGING_BUNDLE" "$APP_BUNDLE"
rm -rf "$STAGING_ROOT"
trap - EXIT
codesign --verify --deep "$APP_BUNDLE"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
