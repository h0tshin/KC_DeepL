#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--release|release|--install-application|install-application|--install-and-verify|install-and-verify)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--release|--install-application|--install-and-verify]" >&2
    exit 2
    ;;
esac

APP_NAME="KCDeepL"
BUNDLE_ID="com.h0tshin.KCDeepL"
PACKAGE_RESOURCE_BUNDLE_NAME="${APP_NAME}_${APP_NAME}.bundle"
MIN_SYSTEM_VERSION="14.0"
EXPECTED_TEAM_IDENTIFIER="${KCDEEPL_TEAM_IDENTIFIER:-5M6Y34KW88}"
DEVELOPMENT_SIGNING_COMMON_NAME="${KCDEEPL_DEVELOPMENT_SIGNING_COMMON_NAME:-Apple Development: Kyung Chul Shin (GSB3764KDE)}"
DISTRIBUTION_SIGNING_COMMON_NAME="${KCDEEPL_DISTRIBUTION_SIGNING_COMMON_NAME:-Developer ID Application: Kyung Chul Shin (5M6Y34KW88)}"
SIGNING_COMMON_NAME_OVERRIDE="${KCDEEPL_SIGNING_COMMON_NAME:-}"
IS_RELEASE_BUILD=false
BUILD_CONFIGURATION="debug"

if [[ "$MODE" == "--release" || "$MODE" == "release" ]]; then
  IS_RELEASE_BUILD=true
  BUILD_CONFIGURATION="release"
  EXPECTED_SIGNING_COMMON_NAME="$DISTRIBUTION_SIGNING_COMMON_NAME"
else
  EXPECTED_SIGNING_COMMON_NAME="$DEVELOPMENT_SIGNING_COMMON_NAME"
fi

if [[ -n "$SIGNING_COMMON_NAME_OVERRIDE" && "$IS_RELEASE_BUILD" == "true" ]]; then
  echo "error: KCDEEPL_SIGNING_COMMON_NAME is not accepted for release signing." >&2
  echo "Use KCDEEPL_DISTRIBUTION_SIGNING_COMMON_NAME with a Developer ID Application identity." >&2
  exit 2
elif [[ -n "$SIGNING_COMMON_NAME_OVERRIDE" ]]; then
  EXPECTED_SIGNING_COMMON_NAME="$SIGNING_COMMON_NAME_OVERRIDE"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APPLICATION_DIR="/Applications"
APPLICATION_BUNDLE="$APPLICATION_DIR/$APP_NAME.app"
SWIFTPM_SCRATCH_PATH="${KCDEEPL_SWIFTPM_SCRATCH_PATH:-${TMPDIR:-/tmp}/KCDeepL-swiftpm}"
MODULE_CACHE_ROOT="${KCDEEPL_MODULE_CACHE_ROOT:-${TMPDIR:-/tmp}/KCDeepL-module-cache}"
STAGING_ROOT="${TMPDIR:-/tmp}/KCDeepL-build.$$"
STAGING_BUNDLE="$STAGING_ROOT/$APP_NAME.app"
APP_CONTENTS="$STAGING_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Sources/App/Resources/AppIcon.icns"
ENTITLEMENTS_FILE="$ROOT_DIR/Sources/App/KCDeepL.entitlements"
CODESIGN_IDENTITY="${KCDEEPL_CODESIGN_IDENTITY:-}"
REQUIREMENTS_FILE="$STAGING_ROOT/KCDeepL.requirements"
SIGNED_ENTITLEMENTS_FILE="$STAGING_ROOT/KCDeepL.signed.entitlements"
APPLICATION_BACKUP=""
HIDDEN_SWIFTPM_SCRATCH_PATH=""
CRASH_REPORT_MARKER=""

prepare_external_build_paths() {
  mkdir -p \
    "$SWIFTPM_SCRATCH_PATH" \
    "$MODULE_CACHE_ROOT/clang" \
    "$MODULE_CACHE_ROOT/swiftpm"

  SWIFTPM_SCRATCH_PATH="$(cd "$SWIFTPM_SCRATCH_PATH" && pwd -P)"
  MODULE_CACHE_ROOT="$(cd "$MODULE_CACHE_ROOT" && pwd -P)"

  local path
  for path in "$SWIFTPM_SCRATCH_PATH" "$MODULE_CACHE_ROOT"; do
    case "$path" in
      "$ROOT_DIR"|"$ROOT_DIR"/*)
        echo "error: Build and module caches must stay outside the project: $path" >&2
        exit 1
        ;;
    esac
  done
}

swift_build() {
  env \
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_ROOT/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_ROOT/swiftpm" \
    swift build \
      --scratch-path "$SWIFTPM_SCRATCH_PATH" \
      -c "$BUILD_CONFIGURATION" \
      "$@"
}

stop_running_application() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  echo "error: $APP_NAME is still running." >&2
  return 1
}

installed_application_pid() {
  local pid
  local command

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" == "$APPLICATION_BUNDLE/Contents/MacOS/$APP_NAME"* ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done < <(pgrep -x "$APP_NAME" 2>/dev/null || true)

  return 1
}

restore_hidden_build_scratch() {
  if [[ -n "$HIDDEN_SWIFTPM_SCRATCH_PATH" \
        && -d "$HIDDEN_SWIFTPM_SCRATCH_PATH" \
        && ! -e "$SWIFTPM_SCRATCH_PATH" ]]; then
    mv "$HIDDEN_SWIFTPM_SCRATCH_PATH" "$SWIFTPM_SCRATCH_PATH"
  fi
  HIDDEN_SWIFTPM_SCRATCH_PATH=""

  if [[ -n "$CRASH_REPORT_MARKER" && -e "$CRASH_REPORT_MARKER" ]]; then
    rm -f "$CRASH_REPORT_MARKER"
  fi
  CRASH_REPORT_MARKER=""
}

# Accessibility and login-item grants are keyed to the app's designated
# requirement. Never fall back to ad-hoc signing, which changes that identity.
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -v common_name="\"$EXPECTED_SIGNING_COMMON_NAME\"" \
          'index($0, common_name) && !found { print $2; found = 1 }'
  )"
fi

if [[ -z "$CODESIGN_IDENTITY" || "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "error: The required Apple signing identity is not installed." >&2
  echo "Expected: $EXPECTED_SIGNING_COMMON_NAME" >&2
  echo "Install that identity or set KCDEEPL_CODESIGN_IDENTITY explicitly." >&2
  exit 1
fi

if [[ "$IS_RELEASE_BUILD" == "true" && ! -f "$ENTITLEMENTS_FILE" ]]; then
  echo "error: Release entitlements file is missing: $ENTITLEMENTS_FILE" >&2
  exit 1
fi

cd "$ROOT_DIR"
prepare_external_build_paths
if [[ "$IS_RELEASE_BUILD" != "true" ]]; then
  stop_running_application
fi

printf 'SwiftPM scratch: %s\n' "$SWIFTPM_SCRATCH_PATH"
swift_build --product "$APP_NAME"
BUILD_OUTPUT_DIR="$(swift_build --show-bin-path)"
BUILD_BINARY="$BUILD_OUTPUT_DIR/$APP_NAME"
PACKAGE_RESOURCE_BUNDLE_SOURCE="$BUILD_OUTPUT_DIR/$PACKAGE_RESOURCE_BUNDLE_NAME"

if [[ ! -d "$PACKAGE_RESOURCE_BUNDLE_SOURCE" ]]; then
  echo "error: Swift package resource bundle is missing: $PACKAGE_RESOURCE_BUNDLE_SOURCE" >&2
  exit 1
fi

rm -rf "$STAGING_ROOT"
trap 'rm -rf "$STAGING_ROOT"' EXIT
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp -R \
  "$PACKAGE_RESOURCE_BUNDLE_SOURCE" \
  "$APP_RESOURCES/$PACKAGE_RESOURCE_BUNDLE_NAME"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
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
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>CFBundleURLName</key>
      <string>com.h0tshin.KCDeepL.translate</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>kcdeepl</string>
      </array>
    </dict>
  </array>
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

cat >"$REQUIREMENTS_FILE" <<REQUIREMENTS
designated => identifier "$BUNDLE_ID" and anchor apple generic and certificate leaf[subject.OU] = "$EXPECTED_TEAM_IDENTIFIER"
REQUIREMENTS

/usr/bin/xattr -cr "$STAGING_BUNDLE"
if [[ "$IS_RELEASE_BUILD" == "true" ]]; then
  codesign \
    --force \
    --deep \
    --sign "$CODESIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --requirements "$REQUIREMENTS_FILE" \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS_FILE" \
    "$STAGING_BUNDLE"
else
  codesign \
    --force \
    --deep \
    --sign "$CODESIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --requirements "$REQUIREMENTS_FILE" \
    "$STAGING_BUNDLE"
fi
/usr/bin/xattr -cr "$STAGING_BUNDLE"
codesign --verify --deep --strict "$STAGING_BUNDLE"

ACTUAL_BUNDLE_ID="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' \
    "$STAGING_BUNDLE/Contents/Info.plist"
)"
SIGNING_DETAILS="$(codesign -dv --verbose=4 "$STAGING_BUNDLE" 2>&1)"
ACTUAL_TEAM_IDENTIFIER="$(
  printf '%s\n' "$SIGNING_DETAILS" \
    | awk -F= '/^TeamIdentifier=/ && !found { print $2; found = 1 }'
)"
ACTUAL_SIGNING_AUTHORITY="$(
  printf '%s\n' "$SIGNING_DETAILS" \
    | awk -F= '/^Authority=/ && !found { print $2; found = 1 }'
)"
ACTUAL_CODE_DIRECTORY="$(
  printf '%s\n' "$SIGNING_DETAILS" \
    | awk '/^CodeDirectory / && !found { print; found = 1 }'
)"
ACTUAL_TIMESTAMP="$(
  printf '%s\n' "$SIGNING_DETAILS" \
    | awk -F= '/^Timestamp=/ && !found { print $2; found = 1 }'
)"

if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "error: Unexpected signed bundle identifier: $ACTUAL_BUNDLE_ID" >&2
  exit 1
fi

if [[ "$ACTUAL_TEAM_IDENTIFIER" != "$EXPECTED_TEAM_IDENTIFIER" ]]; then
  echo "error: Unexpected signing team: $ACTUAL_TEAM_IDENTIFIER" >&2
  echo "Expected team: $EXPECTED_TEAM_IDENTIFIER" >&2
  exit 1
fi

if [[ "$ACTUAL_SIGNING_AUTHORITY" != "$EXPECTED_SIGNING_COMMON_NAME" ]]; then
  echo "error: Unexpected signing authority: $ACTUAL_SIGNING_AUTHORITY" >&2
  echo "Expected authority: $EXPECTED_SIGNING_COMMON_NAME" >&2
  exit 1
fi

if [[ "$IS_RELEASE_BUILD" == "true" ]]; then
  if [[ "$ACTUAL_SIGNING_AUTHORITY" != Developer\ ID\ Application:* ]]; then
    echo "error: Release signing requires a Developer ID Application identity." >&2
    exit 1
  fi

  if [[ "$ACTUAL_CODE_DIRECTORY" != *"runtime"* ]]; then
    echo "error: Hardened Runtime is missing from the release signature." >&2
    exit 1
  fi

  if [[ -z "$ACTUAL_TIMESTAMP" || "$ACTUAL_TIMESTAMP" == "none" ]]; then
    echo "error: A secure timestamp is missing from the release signature." >&2
    exit 1
  fi

  codesign \
    --display \
    --entitlements "$SIGNED_ENTITLEMENTS_FILE" \
    --xml \
    "$STAGING_BUNDLE" \
    >/dev/null 2>&1
  ACTUAL_AUDIO_INPUT_ENTITLEMENT="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.security.device.audio-input' \
      "$SIGNED_ENTITLEMENTS_FILE" \
      2>/dev/null || true
  )"
  if [[ "$ACTUAL_AUDIO_INPUT_ENTITLEMENT" != "true" ]]; then
    echo "error: The signed release is missing the audio input entitlement." >&2
    exit 1
  fi
fi

codesign --verify \
  --deep \
  --strict \
  --test-requirement \
  "=identifier \"$BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_IDENTIFIER\"" \
  "$STAGING_BUNDLE"

mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
mv "$STAGING_BUNDLE" "$APP_BUNDLE"
rm -rf "$STAGING_ROOT"
trap - EXIT
codesign --verify --deep "$APP_BUNDLE"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

# `/Applications` is the user-facing install location, not the normal debug
# output. Keep the default run path in `dist/`, and require this explicit mode
# before replacing the copy a user may launch directly from Finder.
install_application_bundle() {
  local install_staging="$APPLICATION_DIR/.${APP_NAME}.app.staging.$$"
  APPLICATION_BACKUP="$APPLICATION_DIR/.${APP_NAME}.app.backup.$$"

  mkdir -p "$APPLICATION_DIR"
  rm -rf "$install_staging" "$APPLICATION_BACKUP"
  /usr/bin/ditto "$APP_BUNDLE" "$install_staging"
  # Copying through a file-provider-backed folder can add Finder metadata to
  # the staging bundle. It is not executable content, but codesign correctly
  # rejects it if left attached to the app package.
  /usr/bin/xattr -cr "$install_staging"
  codesign --verify --deep --strict "$install_staging"

  # Replacing a running bundle can leave Finder launching an old executable.
  # Stop only this app name, then wait briefly for its process to exit.
  stop_running_application

  if [[ -d "$APPLICATION_BUNDLE" ]]; then
    mv "$APPLICATION_BUNDLE" "$APPLICATION_BACKUP"
  fi
  # From the first replacement until verification succeeds, every failure
  # and interrupt follows the same rollback path.
  trap rollback_application_install EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mv "$install_staging" "$APPLICATION_BUNDLE"
  /usr/bin/xattr -cr "$APPLICATION_BUNDLE"
  codesign --verify --deep --strict "$APPLICATION_BUNDLE"
  echo "Installed bundle: $APPLICATION_BUNDLE"
}

finalize_application_install() {
  if [[ -n "$APPLICATION_BACKUP" && -d "$APPLICATION_BACKUP" ]]; then
    rm -rf "$APPLICATION_BACKUP"
  fi
  APPLICATION_BACKUP=""
  trap - EXIT INT TERM
}

rollback_application_install() {
  stop_running_application || return 1
  if [[ -d "$APPLICATION_BUNDLE" ]]; then
    rm -rf "$APPLICATION_BUNDLE"
  fi
  if [[ -n "$APPLICATION_BACKUP" && -d "$APPLICATION_BACKUP" ]]; then
    mv "$APPLICATION_BACKUP" "$APPLICATION_BUNDLE"
    echo "Restored previous bundle: $APPLICATION_BUNDLE" >&2
  fi
  APPLICATION_BACKUP=""
}

verify_installed_application_without_build_scratch() {
  local installed_pid
  local new_crash_report

  if [[ -e "$ROOT_DIR/.build" ]]; then
    echo "error: Workspace .build must be absent for installed-app verification." >&2
    return 1
  fi
  if [[ ! -d "$APPLICATION_BUNDLE/Contents/Resources/$PACKAGE_RESOURCE_BUNDLE_NAME" ]]; then
    echo "error: Installed resource bundle is missing from Contents/Resources." >&2
    return 1
  fi
  if [[ -e "$APPLICATION_BUNDLE/$PACKAGE_RESOURCE_BUNDLE_NAME" ]]; then
    echo "error: Unexpected app-root resource bundle would mask the regression." >&2
    return 1
  fi
  if [[ ! -d "$SWIFTPM_SCRATCH_PATH" ]]; then
    echo "error: SwiftPM scratch path is unavailable: $SWIFTPM_SCRATCH_PATH" >&2
    return 1
  fi

  HIDDEN_SWIFTPM_SCRATCH_PATH="${SWIFTPM_SCRATCH_PATH}.runtime-hidden.$$"
  if [[ -e "$HIDDEN_SWIFTPM_SCRATCH_PATH" ]]; then
    echo "error: Runtime verification path already exists: $HIDDEN_SWIFTPM_SCRATCH_PATH" >&2
    HIDDEN_SWIFTPM_SCRATCH_PATH=""
    return 1
  fi
  CRASH_REPORT_MARKER="$(mktemp "${TMPDIR:-/tmp}/KCDeepL-crash-marker.XXXXXX")"

  trap 'restore_hidden_build_scratch; rollback_application_install' EXIT
  mv "$SWIFTPM_SCRATCH_PATH" "$HIDDEN_SWIFTPM_SCRATCH_PATH"

  if ! /usr/bin/open -n "$APPLICATION_BUNDLE"; then
    echo "error: Could not launch installed bundle." >&2
    return 1
  fi

  for _ in {1..30}; do
    installed_pid="$(installed_application_pid || true)"
    if [[ -n "$installed_pid" ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ -z "$installed_pid" ]]; then
    echo "error: Installed application did not start." >&2
    return 1
  fi

  sleep 3
  if ! kill -0 "$installed_pid" 2>/dev/null; then
    echo "error: Installed application exited during runtime verification." >&2
    return 1
  fi

  new_crash_report="$(
    find "$HOME/Library/Logs/DiagnosticReports" \
      -maxdepth 1 \
      -type f \
      -name "${APP_NAME}-*.ips" \
      -newer "$CRASH_REPORT_MARKER" \
      -print \
      -quit \
      2>/dev/null || true
  )"
  if [[ -n "$new_crash_report" ]]; then
    echo "error: A new crash report was generated: $new_crash_report" >&2
    return 1
  fi

  restore_hidden_build_scratch
  trap rollback_application_install EXIT

  if [[ -e "$ROOT_DIR/.build" ]]; then
    echo "error: Runtime verification created workspace .build." >&2
    return 1
  fi

  printf 'Verified installed bundle without build scratch: %s (pid %s)\n' \
    "$APPLICATION_BUNDLE" \
    "$installed_pid"
}

case "$MODE" in
  --release|release)
    echo "Release bundle: $APP_BUNDLE"
    ;;
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
  --install-application|install-application)
    install_application_bundle
    finalize_application_install
    ;;
  --install-and-verify|install-and-verify)
    install_application_bundle
    verify_installed_application_without_build_scratch
    finalize_application_install
    ;;
esac
