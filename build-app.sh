#!/bin/sh
# Builds Joey.app in an ignored, Spotlight-excluded build directory.
# Requires macOS with the Xcode command line tools (xcode-select --install)
# and Vendor/libssh.xcframework (build once with ./Vendor/build-libssh.sh).
set -eu
cd "$(dirname "$0")"

FAMILY_CONTRACT="../leafiy-ui/scripts/check-app-family-contract.sh"
[ -x "$FAMILY_CONTRACT" ] || { echo "error: shared app-family contract not found: $FAMILY_CONTRACT"; exit 1; }
BUILD_COMMON="../leafiy-ui/scripts/macos-app-build-common.sh"
[ -r "$BUILD_COMMON" ] || { echo "error: shared macOS build policy not found: $BUILD_COMMON"; exit 1; }
. "$BUILD_COMMON"
"$FAMILY_CONTRACT" "$PWD"

[ -d "Vendor/libssh.xcframework" ] || {
    echo "error: Vendor/libssh.xcframework missing — run ./Vendor/build-libssh.sh first"
    exit 1
}

APP_ICON_SOURCE="joey.png"
MENU_ICON_SOURCE="Sources/Joey/Resources/Icons/joey.png"
ICON_COMPILER="../leafiy-ui/scripts/compile-macos-app-icon.sh"
[ -f "$APP_ICON_SOURCE" ] || { echo "error: $APP_ICON_SOURCE not found"; exit 1; }
[ -f "$MENU_ICON_SOURCE" ] || { echo "error: $MENU_ICON_SOURCE not found"; exit 1; }
[ -x "$ICON_COMPILER" ] || { echo "error: shared icon compiler not found: $ICON_COMPILER"; exit 1; }

TEAM_ID="${TEAM_ID:-Q478GZN2AV}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

# Native build for this Mac's CPU by default (works on Intel and Apple
# Silicon alike). UNIVERSAL=1 sh build-app.sh builds one app for both.
set --
if [ "${UNIVERSAL:-0}" = "1" ]; then
    set -- --arch arm64 --arch x86_64
fi

# Local path dependencies can gain source files without invalidating SwiftPM's
# cached build description. Always re-plan so LeafiyUI's source list is current.
SCRATCH_PATH="${SCRATCH_PATH:-"${TMPDIR%/}/leafiy-swift-builds/joey"}"
leafiy_swift_release_build "$SCRATCH_PATH" "$@" --product joey
BIN_DIR=$(leafiy_swift_release_bin_path "$SCRATCH_PATH" "$@" --product joey)
BUILD_ROOT="${BUILD_ROOT:-"$PWD/build.noindex"}"
APP_OUTPUT_DIR="${APP_OUTPUT_DIR:-"$BUILD_ROOT/app"}"
mkdir -p "$BUILD_ROOT"

APP="$APP_OUTPUT_DIR/Joey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Info.plist "$APP/Contents/Info.plist"
leafiy_install_release_executable "$BIN_DIR/joey" "$APP/Contents/MacOS/Joey"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The libssh dylib ships inside the bundle; use a bundle-relative load path.
LIBSSH_DYLIB=$(find Vendor/libssh.xcframework -name 'libssh.dylib' | head -n 1)
[ -n "$LIBSSH_DYLIB" ] || { echo "error: libssh.dylib not found inside the xcframework"; exit 1; }
cp "$LIBSSH_DYLIB" "$APP/Contents/Frameworks/libssh.dylib"
install_name_tool -change "@rpath/libssh.dylib" \
    "@executable_path/../Frameworks/libssh.dylib" \
    "$APP/Contents/MacOS/Joey"

"$ICON_COMPILER" "$APP_ICON_SOURCE" "$APP/Contents/Resources" "$BUILD_ROOT/appicon-work"
cp "$MENU_ICON_SOURCE" "$APP/Contents/Resources/joey.png"

if [ -d "$BIN_DIR/joey_Joey.bundle" ]; then
    cp -R "$BIN_DIR/joey_Joey.bundle" "$APP/Contents/Resources/"
fi
if [ -d "$BIN_DIR/LeafiyUI_LeafiyUI.bundle" ]; then
    cp -R "$BIN_DIR/LeafiyUI_LeafiyUI.bundle" "$APP/Contents/Resources/"
fi

leafiy_validate_app_icon_contract "$APP" "$MENU_ICON_SOURCE" "joey.png"

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\".*/\1/p" \
        | head -n 1)
fi

if [ -n "$SIGN_IDENTITY" ]; then
    # Hardened runtime + secure timestamp are required for notarized
    # distribution. disable-library-validation lets the app load the locally
    # built libssh dylib (LGPL §6(b) replaceability, joey ADR-0001).
    cat > "$BUILD_ROOT/joey.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
EOF
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/libssh.dylib"
    codesign --force --options runtime --timestamp \
        --entitlements "$BUILD_ROOT/joey.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP"
else
    echo "warning: Developer ID Application certificate for team $TEAM_ID not found; using ad-hoc signature"
    codesign --force --sign - "$APP/Contents/Frameworks/libssh.dylib"
    codesign --force --sign - "$APP"
fi

echo "Done: $APP"
