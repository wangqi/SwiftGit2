#!/usr/bin/env bash
#
# build-xcframework.sh — build libgit2 as a multi-platform xcframework for this app.
#
# wangqi added 2026-07-07 — turns the Carthage-era SwiftGit2 Xcode project into an
# importable Swift Package (see Package.swift). This script builds only the C dependency
# (libgit2); the Swift bindings are compiled from source by SPM.
#
# Scope: the app's Git integration is HTTPS + Personal Access Token only (see
# helper/docs/git.md). That lets us build libgit2 with Apple-native crypto/TLS and NO
# third-party crypto libraries:
#   - TLS  : Secure Transport (system Security.framework)   -> no OpenSSL
#   - SHA1 : CollisionDetection (libgit2 builtin sha1dc)     -> no OpenSSL
#   - SHA256: CommonCrypto (system)                          -> no OpenSSL
#   - SSH  : OFF                                             -> no libssh2
# Result: a single static libgit2.a per platform, linking only Security + CoreFoundation.
#
# Output: build/libgit2.xcframework  (consumed by Package.swift's Clibgit2 binaryTarget)
# Slices: iOS device (arm64), iOS simulator (arm64+x86_64), macOS (arm64+x86_64).
#
# Usage:
#   ./build-xcframework.sh              # full build
#   ./build-xcframework.sh --clean      # wipe build/ first
#
# Requires: cmake, Xcode command-line tools. The libgit2 submodule is checked out
# automatically if missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBGIT2_SRC="$SCRIPT_DIR/External/libgit2"
BUILD_ROOT="$SCRIPT_DIR/build"
XCFRAMEWORK="$BUILD_ROOT/libgit2.xcframework"
HEADERS_DIR="$BUILD_ROOT/Headers"
MODULEMAP="$SCRIPT_DIR/libgit2/module.modulemap"

# Deployment targets: must be <= the app's (iOS 18.0 / macOS 15.2). Kept lower for headroom.
IOS_MIN="16.0"
MACOS_MIN="13.0"

# Logs go to stderr so `$(build_slice ...)` captures only the library path on stdout.
log()  { echo -e "\033[0;34m[build-xcframework]\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m[build-xcframework]\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[build-xcframework] ERROR:\033[0m $*" >&2; exit 1; }

# --- args ---------------------------------------------------------------------
CLEAN=false
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=true ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done

command -v cmake   >/dev/null || die "cmake not found (brew install cmake)"
command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)"

# --- 1. ensure libgit2 source -------------------------------------------------
if [ ! -f "$LIBGIT2_SRC/CMakeLists.txt" ]; then
  log "libgit2 submodule missing — checking out..."
  git -C "$SCRIPT_DIR" submodule update --init --depth 1 External/libgit2 \
    || die "failed to init libgit2 submodule"
fi
LIBGIT2_VERSION="$(sed -n 's/.*LIBGIT2_VERSION "\(.*\)".*/\1/p' "$LIBGIT2_SRC/include/git2/version.h" 2>/dev/null | head -1)"
log "libgit2 version: ${LIBGIT2_VERSION:-unknown}"

$CLEAN && { log "cleaning $BUILD_ROOT"; rm -rf "$BUILD_ROOT"; }
mkdir -p "$BUILD_ROOT"

# --- shared cmake flags -------------------------------------------------------
# CMAKE_POLICY_VERSION_MINIMUM keeps cmake 4.x happy with libgit2's older minimum.
# TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY is required for iOS cross-compiles (no exe linking).
# Flag names are pinned to the vendored libgit2 (1.1.0): tests = BUILD_CLAR, no BUILD_CLI,
# no USE_SHA256. SHA1 = CollisionDetection is libgit2's builtin sha1dc (no OpenSSL).
COMMON_FLAGS=(
  -DBUILD_SHARED_LIBS=OFF
  -DBUILD_CLAR=OFF
  -DBUILD_EXAMPLES=OFF
  -DBUILD_FUZZERS=OFF
  -DUSE_SSH=OFF
  -DUSE_HTTPS=SecureTransport
  -DUSE_SHA1=CollisionDetection
  -DREGEX_BACKEND=regcomp
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
  # Under the iOS sysroot, libgit2's FIND_PATH/FIND_LIBRARY can't locate the
  # CoreFoundation/Security frameworks (root-path search restriction), yet the compiler
  # still resolves their headers via -isysroot and we link them in Package.swift. Pre-seed
  # the detection gates so the SecureTransport backend is accepted. (No-op on macOS, where
  # detection succeeds on its own.)
  -DCOREFOUNDATION_FOUND=TRUE
  -DSECURITY_FOUND=TRUE
  -DSECURITY_HAS_SSLCREATECONTEXT=TRUE
)

# build_slice <name> <system> <sdk> <archs;semicolon> <deploy-target> <deploy-flag>
build_slice() {
  local name="$1" system="$2" sdk="$3" archs="$4" deploy="$5" deployflag="$6"
  local out="$BUILD_ROOT/$name"
  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    || die "SDK '$sdk' not available"

  log "configuring $name ($system, $sdk, archs=$archs, min=$deploy)"
  rm -rf "$out"
  cmake -S "$LIBGIT2_SRC" -B "$out" \
    -DCMAKE_SYSTEM_NAME="$system" \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$archs" \
    "$deployflag=$deploy" \
    "${COMMON_FLAGS[@]}" >/dev/null

  log "building $name"
  cmake --build "$out" --config Release -j"$(sysctl -n hw.ncpu)" >/dev/null

  local lib; lib="$(find "$out" -name 'libgit2.a' -print -quit)"
  [ -n "$lib" ] || die "libgit2.a not produced for $name"
  echo "$lib"
}

# --- 2. build the three slices ------------------------------------------------
IOS_LIB="$(build_slice ios-arm64      iOS    iphoneos        'arm64'         "$IOS_MIN"   -DCMAKE_OSX_DEPLOYMENT_TARGET)"
SIM_LIB="$(build_slice ios-sim        iOS    iphonesimulator 'arm64;x86_64'  "$IOS_MIN"   -DCMAKE_OSX_DEPLOYMENT_TARGET)"
MAC_LIB="$(build_slice macos          Darwin macosx          'arm64;x86_64'  "$MACOS_MIN" -DCMAKE_OSX_DEPLOYMENT_TARGET)"

# --- 3. assemble the public headers + module map ------------------------------
# Source headers from the submodule include/ (authoritative for the built lib), then
# drop in the Clibgit2 module map so `import Clibgit2` resolves.
log "assembling headers"
rm -rf "$HEADERS_DIR"; mkdir -p "$HEADERS_DIR"
cp -R "$LIBGIT2_SRC/include/git2"   "$HEADERS_DIR/"
cp    "$LIBGIT2_SRC/include/git2.h" "$HEADERS_DIR/"
# libgit2 generates git2/sys/features.h at configure time (into the build tree, not include/).
# The Clibgit2 module map's `sys` umbrella needs it. Merge any such generated public headers;
# the feature set is identical across slices for our flags. Process substitution keeps an
# empty result from tripping `set -o pipefail`.
while IFS= read -r gen; do
  rel="git2/${gen##*/git2/}"
  mkdir -p "$HEADERS_DIR/$(dirname "$rel")"
  cp "$gen" "$HEADERS_DIR/$rel"
done < <(find "$BUILD_ROOT/ios-arm64" -path '*/git2/*' -name '*.h' 2>/dev/null)
[ -f "$MODULEMAP" ] || die "module map missing at $MODULEMAP"
cp "$MODULEMAP" "$HEADERS_DIR/module.modulemap"

# --- 4. lipo the multi-arch slices, then create the xcframework ---------------
# create-xcframework needs one library per platform variant; sim & macOS are already
# multi-arch fat archives from CMAKE_OSX_ARCHITECTURES, so no extra lipo is required.
log "creating xcframework"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -library "$IOS_LIB" -headers "$HEADERS_DIR" \
  -library "$SIM_LIB" -headers "$HEADERS_DIR" \
  -library "$MAC_LIB" -headers "$HEADERS_DIR" \
  -output "$XCFRAMEWORK" >/dev/null

log "done -> $XCFRAMEWORK"
find "$XCFRAMEWORK" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | sed 's/^/  slice: /'
