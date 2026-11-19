#!/usr/bin/env bash
# Builds the Linphone iPhone SDK (linphone-sdk 5.5.19) with the "bound interface" patches.
# Run on a Mac with Xcode (>= 15), cmake (>= 3.22), ninja, python3 (+pip), git and ~30 GB free.
# Read each step's output and stop at the first failure.
#
#   ./build_patched_sdk.sh fetch      get the 5.5.19 source (GitLab, or local git bundles)
#   ./build_patched_sdk.sh verify     check the patches apply to that source (changes nothing)
#   ./build_patched_sdk.sh stock       build WITHOUT the patches (proves the toolchain first)
#   ./build_patched_sdk.sh patched     apply the patches and build
#   ./build_patched_sdk.sh package     zip the xcframeworks and print their checksums
#
# Settings (environment variables):
#   WORK     work folder                         default: $HOME/linphone-sdk-build
#   BUNDLES  folder with local *.bundle files    default: empty = use the network
#   BASE_URL where the zipped frameworks will be hosted (https). Used in Package.swift.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HOME/linphone-sdk-build}"
SRC="$WORK/linphone-sdk"
BUNDLES="${BUNDLES:-}"
BASE_URL="${BASE_URL:-https://example.invalid/linphone-sdk-5.5.19-bound}"
TAG="5.5.19"
GITLAB="https://gitlab.linphone.org/BC/public"
MODULES="bctoolbox ortp belle-sip mediastreamer2 liblinphone"

say() { printf '\n== %s\n' "$*"; }

fetch() {
  mkdir -p "$WORK"
  if [ ! -d "$SRC/.git" ]; then
    say "Clone linphone-sdk $TAG"
    if [ -n "$BUNDLES" ]; then
      git clone "$BUNDLES/linphone-sdk.bundle" "$SRC"
    else
      git clone "$GITLAB/linphone-sdk.git" "$SRC"
    fi
  fi
  cd "$SRC"
  git checkout "$TAG"
  if [ -n "$BUNDLES" ]; then
    # Point every submodule at its offline bundle; bcg729/bcmatroska2 are top-level, the rest are external/*.
    git submodule init
    for path in $(git config -f .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}'); do
      name="$(basename "$path")"
      [ "$path" = "msoboe/oboe" ] && name="oboe"
      if [ -f "$BUNDLES/$name.bundle" ]; then
        git config "submodule.$path.url" "$BUNDLES/$name.bundle"
      else
        echo "no bundle for $path ($name); the network URL will be used"
      fi
    done
  fi
  git submodule update --init --recursive
  say "Source ready at $SRC ($(git rev-parse --short HEAD))"
}

apply_patches() {
  cd "$SRC"
  for m in $MODULES; do
    p="$HERE/$m-bound-interface.patch"
    if git apply --check --directory="$m" "$p" 2>/dev/null; then
      git apply --directory="$m" "$p"
      echo "applied   $m"
    elif git apply --check --reverse --directory="$m" "$p" 2>/dev/null; then
      echo "already applied: $m"
    else
      echo "PATCH DOES NOT APPLY: $m (the source is not the exact $TAG tree)"; exit 1
    fi
  done
}

verify() {
  cd "$SRC"
  for m in $MODULES; do
    git apply --check --directory="$m" "$HERE/$m-bound-interface.patch" \
      && echo "ok $m" || { echo "FAIL $m"; exit 1; }
  done
}

build() {
  cd "$SRC"
  # Options: arm64 device only, no video (the published package is "novideo"). Check the exact flags the
  # published 5.5.19-novideo package used before shipping; ENABLE_VIDEO=OFF is the main one.
  cmake --preset=ios-sdk -G Ninja -B build-ios \
    -DLINPHONESDK_IOS_ARCHS="arm64" \
    -DENABLE_VIDEO=OFF \
    -DLINPHONESDK_IOS_BASE_URL="$BASE_URL"
  cmake --build build-ios
  say "Swift package: $SRC/build-ios/linphone-sdk-swift-ios"
}

package_sdk() {
  cd "$SRC/build-ios/linphone-sdk-swift-ios"
  ls
  if [ -d XCFrameworks ]; then
    cd XCFrameworks
    for x in *.xcframework; do
      zip -qry "$x.zip" "$x"
      printf '%s  %s\n' "$(swift package compute-checksum "$x.zip")" "$x.zip"
    done
  fi
  say "Upload the .zip files to $BASE_URL and use these checksums in our own Package.swift"
}

case "${1:-}" in
  fetch)   fetch ;;
  verify)  verify ;;
  stock)   build ;;
  patched) apply_patches; build ;;
  package) package_sdk ;;
  *) sed -n '2,19p' "$0"; exit 2 ;;
esac
