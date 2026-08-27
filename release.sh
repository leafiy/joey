#!/bin/sh
# Releases Joey: two notarized DMGs, the leafiy.com update feed, GitHub source
# and release, optional Gitea mirror. The flow, every environment knob, and the
# usage lines live in ../leafiy-ui/scripts/macos-app-release-common.sh
# (ADR-0012); this file only declares the app.
#   sh release.sh --prepare [v1.2.3]   sh release.sh [v1.2.3]   PUBLISH_TO_LEAFIY=0 PUBLISH_TO_GITHUB=0 sh release.sh
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
GITEA_RELEASE_SUMMARY="Native macOS SSH and SFTP client for remote file workflows."
# Joey's update feed is registered on leafiy.com before each publish.
REGISTER_UPDATE_FEED=1
RELEASE_COMMON="../leafiy-ui/scripts/macos-app-release-common.sh"
[ -r "$RELEASE_COMMON" ] || { echo "error: shared release flow not found: $RELEASE_COMMON"; exit 1; }
. "$RELEASE_COMMON"
leafiy_release_main "$@"
