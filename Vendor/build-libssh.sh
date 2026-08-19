#!/bin/bash
# Builds Vendor/libssh.xcframework: libssh (fat dylib, arm64+x86_64) with a
# statically absorbed universal OpenSSL libcrypto. Follows the checklist in
# docs/research/ssh-c-library-packaging.md (ticket 01).
#
# Run this on macOS. Prerequisites: Xcode command line tools, cmake, curl.
# All intermediates live in Vendor/_work/ (gitignored); the only output is
# Vendor/libssh.xcframework.
#
# Known fallbacks (see the research doc "风险"):
# - If the fat CMake build misbehaves (feature detection runs on the host arch
#   only), build libssh once per arch and lipo the dylibs together.
# - If CMake cannot find zlib in the SDK, re-run with EXTRA_CMAKE_FLAGS=-DWITH_ZLIB=OFF.
set -euo pipefail

OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.1}"
LIBSSH_VERSION="${LIBSSH_VERSION:-0.12.2}"
LIBSSH_SERIES="${LIBSSH_VERSION%.*}"
MACOS_MIN="14.0"
JOBS="$(sysctl -n hw.ncpu)"

VENDOR_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$VENDOR_DIR/_work"
DL="$WORK/downloads"
OUT="$VENDOR_DIR/libssh.xcframework"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v cmake >/dev/null || die "cmake not found (brew install cmake)"
command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode command line tools)"
command -v curl >/dev/null || die "curl not found"

mkdir -p "$DL"

fetch() { # url dest
    local url="$1" dest="$2"
    if [[ -f "$dest" ]]; then
        say "reusing $(basename "$dest")"
    else
        say "downloading $url"
        curl -fL --retry 3 -o "$dest" "$url"
    fi
    shasum -a 256 "$dest"
}

OPENSSL_TGZ="$DL/openssl-$OPENSSL_VERSION.tar.gz"
LIBSSH_TXZ="$DL/libssh-$LIBSSH_VERSION.tar.xz"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_TGZ"
fetch "https://www.libssh.org/files/$LIBSSH_SERIES/libssh-$LIBSSH_VERSION.tar.xz" "$LIBSSH_TXZ"
echo
echo "^ verify these SHA-256 sums against the upstream release pages before shipping."

build_openssl_arch() { # arch configure-target
    local arch="$1" target="$2"
    local srcdir="$WORK/openssl-$arch"
    local prefix="$WORK/openssl-out/$arch"
    if [[ -f "$prefix/lib/libcrypto.a" ]]; then
        say "OpenSSL $arch already built, skipping"
        return
    fi
    say "building OpenSSL $OPENSSL_VERSION for $arch"
    rm -rf "$srcdir"
    mkdir -p "$srcdir"
    tar xf "$OPENSSL_TGZ" -C "$srcdir" --strip-components 1
    (
        cd "$srcdir"
        ./Configure "$target" no-shared no-tests \
            -mmacosx-version-min="$MACOS_MIN" --prefix="$prefix" >/dev/null
        make -j"$JOBS" >/dev/null
        make install_sw >/dev/null
    )
}

build_openssl_arch arm64 darwin64-arm64-cc
build_openssl_arch x86_64 darwin64-x86_64-cc

UNIV="$WORK/openssl-out/universal"
say "creating universal static libcrypto/libssl"
mkdir -p "$UNIV/lib"
rm -rf "$UNIV/include"
cp -R "$WORK/openssl-out/arm64/include" "$UNIV/include"
# Only libcrypto gets linked (libssh never uses libssl), but CMake's FindOpenSSL
# probes for both libraries — keep libssl so the configure step succeeds.
for lib in libcrypto libssl; do
    lipo -create \
        "$WORK/openssl-out/arm64/lib/$lib.a" \
        "$WORK/openssl-out/x86_64/lib/$lib.a" \
        -output "$UNIV/lib/$lib.a"
done
lipo -info "$UNIV/lib/libcrypto.a"

LIBSSH_SRC="$WORK/libssh-src"
LIBSSH_BUILD="$WORK/libssh-build"
say "building libssh $LIBSSH_VERSION (fat dylib)"
rm -rf "$LIBSSH_SRC"
mkdir -p "$LIBSSH_SRC"
tar xf "$LIBSSH_TXZ" -C "$LIBSSH_SRC" --strip-components 1
cmake -S "$LIBSSH_SRC" -B "$LIBSSH_BUILD" \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DWITH_SERVER=OFF \
    -DWITH_EXAMPLES=OFF \
    -DUNIT_TESTING=OFF \
    -DWITH_GSSAPI=OFF \
    -DOPENSSL_ROOT_DIR="$UNIV" \
    -DOPENSSL_USE_STATIC_LIBS=ON \
    ${EXTRA_CMAKE_FLAGS:-}
cmake --build "$LIBSSH_BUILD" -j "$JOBS"

DYLIB="$WORK/libssh.dylib"
cp -L "$LIBSSH_BUILD/src/libssh.dylib" "$DYLIB"

say "sanity checks"
lipo -info "$DYLIB"
lipo -info "$DYLIB" | grep -q "arm64" || die "arm64 slice missing"
lipo -info "$DYLIB" | grep -q "x86_64" || die "x86_64 slice missing"
if otool -L "$DYLIB" | grep -q libcrypto; then
    die "dylib still references an external libcrypto — static absorb failed"
fi
otool -L "$DYLIB"

# install_name_tool invalidates the linker signature; arm64 refuses to load
# unsigned code, so ad-hoc re-sign (distribution signing happens at app packaging).
install_name_tool -id @rpath/libssh.dylib "$DYLIB"
codesign --force -s - "$DYLIB"

say "staging headers + modulemap"
STAGE="$WORK/staged-include"
rm -rf "$STAGE"
mkdir -p "$STAGE/libssh"
cp "$LIBSSH_SRC/include/libssh/"*.h "$STAGE/libssh/"
cp "$LIBSSH_BUILD/include/libssh/libssh_version.h" "$STAGE/libssh/"
cat > "$STAGE/module.modulemap" <<'EOF'
module CLibssh {
    header "libssh/libssh.h"
    header "libssh/sftp.h"
    link "ssh"
    export *
}
EOF

say "creating xcframework"
rm -rf "$OUT"
xcodebuild -create-xcframework -library "$DYLIB" -headers "$STAGE" -output "$OUT"

say "done: $OUT"
echo "Next: swift build && .build/debug/joey-spike --help"
echo "Keep $LIBSSH_TXZ — the LGPL source offer must match this exact dylib."
