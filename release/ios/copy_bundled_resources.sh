#!/bin/bash
# SPDX-FileCopyrightText: Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copy minimum runtime resources into Blender.app/Assets/<version> for iOS runs
# that don't execute `cmake --install`.

set -uo pipefail

fallback_app="${1:-}"
cmake_binary_dir="${2:-}"
blender_version="${3:-}"
source_dir="${4:-}"
python_libpath="${5:-}"
python_version="${6:-}"

declare -a candidates=()

append_unique() {
  local d="$1"
  [[ -z "$d" ]] && return
  local c
  if ((${#candidates[@]} > 0)); then
    for c in "${candidates[@]}"; do
      [[ "$c" == "$d" ]] && return
    done
  fi
  candidates+=("$d")
}

if [[ -n "${CODESIGNING_FOLDER_PATH:-}" ]]; then
  append_unique "${CODESIGNING_FOLDER_PATH}"
fi
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${FULL_PRODUCT_NAME:-}" ]]; then
  append_unique "${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
fi
if [[ -n "${BUILT_PRODUCTS_DIR:-}" && -n "${FULL_PRODUCT_NAME:-}" ]]; then
  append_unique "${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"
fi
if [[ -n "${CONFIGURATION_BUILD_DIR:-}" && -n "${FULL_PRODUCT_NAME:-}" ]]; then
  append_unique "${CONFIGURATION_BUILD_DIR}/${FULL_PRODUCT_NAME}"
fi
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${WRAPPER_NAME:-}" ]]; then
  append_unique "${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
fi
if [[ -n "${BUILT_PRODUCTS_DIR:-}" && -n "${WRAPPER_NAME:-}" ]]; then
  append_unique "${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
fi
if [[ -n "${fallback_app}" ]]; then
  append_unique "${fallback_app}"
fi

if [[ -n "${OBJROOT:-}" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] && append_unique "$d"
  done < <(find "${OBJROOT}" -maxdepth 14 -name 'Blender.app' -type d 2>/dev/null || true)
fi
if [[ -n "${SYMROOT:-}" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] && append_unique "$d"
  done < <(find "${SYMROOT}" -maxdepth 8 -name 'Blender.app' -type d 2>/dev/null || true)
fi
if [[ -n "${TARGET_BUILD_DIR:-}" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] && append_unique "$d"
  done < <(find "${TARGET_BUILD_DIR}" -maxdepth 3 -name 'Blender.app' -type d 2>/dev/null || true)
fi
if [[ -n "${cmake_binary_dir}" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] && append_unique "$d"
  done < <(find "${cmake_binary_dir}" -maxdepth 6 -name 'Blender.app' -type d 2>/dev/null || true)
fi

is_bundle_root() {
  local root="$1"
  [[ -d "$root" ]] || return 1
  [[ -f "${root}/Blender" || -f "${root}/Info.plist" ]] && return 0
  return 1
}

copy_if_dir() {
  local src="$1"
  local dst="$2"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"
  cp -Rf "${src}/." "$dst/" || true
  return 0
}

copied_any=0
if ((${#candidates[@]} > 0)); then
  for root in "${candidates[@]}"; do
    if ! is_bundle_root "$root"; then
      continue
    fi
    if [[ -z "${blender_version}" ]]; then
      continue
    fi

    assets_root="${root}/Assets/${blender_version}"
    mkdir -p "${assets_root}"

    copy_if_dir "${source_dir}/scripts" "${assets_root}/scripts"
    # `cycles` is a bundled add-on and must live in `addons_core` to be discovered at startup.
    copy_if_dir "${source_dir}/intern/cycles/blender/addon" "${assets_root}/scripts/addons_core/cycles"
    copy_if_dir "${source_dir}/release/datafiles/fonts" "${assets_root}/datafiles/fonts"
    copy_if_dir "${source_dir}/release/datafiles/colormanagement" "${assets_root}/datafiles/colormanagement"
    copy_if_dir "${source_dir}/release/datafiles/studiolights" "${assets_root}/datafiles/studiolights"
    # Essentials asset library (brush assets, catalogs, etc.).
    copy_if_dir "${source_dir}/assets" "${assets_root}/datafiles/assets"
    copy_if_dir "${cmake_binary_dir}/release/datafiles/icons" "${assets_root}/datafiles/icons"
    copy_if_dir "${source_dir}/release/datafiles/icons" "${assets_root}/datafiles/icons"

    if [[ -n "${python_libpath}" && -n "${python_version}" ]]; then
      copy_if_dir "${python_libpath}/python${python_version}" \
                  "${assets_root}/python/lib/python${python_version}"
    fi

    echo "copy_bundled_resources: synced runtime assets into ${assets_root}"
    copied_any=1
  done
fi

if [[ "$copied_any" -eq 0 ]]; then
  echo "copy_bundled_resources.sh: WARNING: no Blender.app destination found. Build continues." >&2
fi

exit 0
