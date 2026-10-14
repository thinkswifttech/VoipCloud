#!/bin/bash
set -euo pipefail

# Linphone's macOS framework links libhidapi dynamically, but the 5.5.16
# Swift package does not always copy that dylib into the application bundle.
# Embed it here so development and distributed builds do not depend on the
# destination Mac having Homebrew installed.

readonly library_name="libhidapi.0.dylib"
readonly frameworks_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
readonly destination="${frameworks_dir}/${library_name}"

find_library() {
  local candidate
  local source_packages_root=""

  # An explicit, universal build of the library wins (for example a lipo of the
  # arm64 and x86_64 Homebrew copies) so universal archives can be produced.
  if [[ -n "${HIDAPI_DYLIB:-}" && -f "${HIDAPI_DYLIB}" ]]; then
    printf '%s\n' "${HIDAPI_DYLIB}"
  fi

  if [[ -n "${BUILD_DIR:-}" ]]; then
    source_packages_root="${BUILD_DIR%%/Build/*}/SourcePackages"
  fi

  for candidate in \
    "${source_packages_root}" \
    "${PROJECT_DIR}/../build/macos/SourcePackages"; do
    if [[ -n "$candidate" && -d "$candidate" ]]; then
      find "$candidate" -name "$library_name" -print -quit 2>/dev/null || true
    fi
  done

  for candidate in \
    "/opt/homebrew/opt/hidapi/lib/${library_name}" \
    "/usr/local/opt/hidapi/lib/${library_name}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
    fi
  done
}

# `sed -n 1p` reads all of the output; `head -n 1` would close the pipe early
# and, with pipefail, silently fail the script when there are several matches.
source_library="$(find_library | sed -n 1p)"
if [[ -z "$source_library" ]]; then
  cat >&2 <<EOF
error: Linphone requires ${library_name}, but it was not found in the resolved
Swift package or on this build Mac. Install the build dependency with:

  brew install hidapi

Then clean and rebuild. The library will be copied into the app; end users do
not need Homebrew or any separate runtime installation.
EOF
  exit 1
fi

mkdir -p "$frameworks_dir"
cp -fL "$source_library" "$destination"
chmod 755 "$destination"
install_name_tool -id "@rpath/${library_name}" "$destination"

# Reject an installer/archive that contains a dylib for only some of the
# executable's architectures (for example arm64 Homebrew in a universal app).
if [[ -n "${EXECUTABLE_PATH:-}" && -f "${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}" ]]; then
  app_architectures="$(lipo -archs "${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}")"
  library_architectures="$(lipo -archs "$destination")"
  for architecture in $app_architectures; do
    if [[ " $library_architectures " != *" $architecture "* ]]; then
      echo "error: ${library_name} lacks required ${architecture} architecture (has: ${library_architectures})." >&2
      exit 1
    fi
  done
fi

signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="-"
fi
codesign --force --sign "$signing_identity" "$destination"

echo "Embedded Linphone runtime dependency: ${source_library} -> ${destination}"
