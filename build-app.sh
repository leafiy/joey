#!/bin/sh
# Builds Joey.app in an ignored, Spotlight-excluded build directory.
# Requires macOS with the Xcode command line tools (xcode-select --install).
# The flow lives in ../leafiy-ui/scripts/macos-app-build-common.sh (ADR-0012);
# this file only declares the app. UNIVERSAL=1 builds one app for both CPUs.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"

APP_SLUG="joey"
APP_EXECUTABLE_PRODUCT="joey"
# Package.swift also declares joey-spike; build only the app product.
SWIFT_BUILD_ARGS="--product joey"
APP_ICON_SOURCE="joey.png"
MENU_ICON_SOURCE="Sources/Joey/Resources/Icons/joey.png"
# libssh ships inside the bundle (joey ADR-0001); library validation stays off
# so users keep LGPL section 6(b) replacement rights.
APP_EMBEDDED_XCFRAMEWORKS="Vendor/libssh.xcframework"
APP_EMBEDDED_XCFRAMEWORKS_HINT="run ./Vendor/build-libssh.sh first"
APP_DISABLE_LIBRARY_VALIDATION=1
BUILD_COMMON="../leafiy-ui/scripts/macos-app-build-common.sh"
[ -r "$BUILD_COMMON" ] || { echo "error: shared macOS build policy not found: $BUILD_COMMON"; exit 1; }
. "$BUILD_COMMON"
leafiy_build_app_main "$@"
