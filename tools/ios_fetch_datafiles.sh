#!/usr/bin/env bash
# Fetch real startup.blend and geometry icon .dat files from the official Blender source release.
# GitHub LFS objects for the git checkout often 404; without binary data the iOS app embeds
# LFS pointer text instead of real files.
set -euo pipefail

BLENDER_VERSION="${BLENDER_VERSION:-4.4.0}"
ARCHIVE="blender-${BLENDER_VERSION}.tar.xz"
URL="https://download.blender.org/source/${ARCHIVE}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATAFILES="${ROOT}/release/datafiles"
ICONS="${DATAFILES}/icons"
TMP="${TMPDIR:-/tmp}/blender_ios_datafiles_$$"

cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

mkdir -p "${TMP}" "${ICONS}"

echo "Downloading ${URL} and extracting datafiles (streaming, ~350 MiB download)..."
curl -fL --progress-bar "${URL}" | tar -xJ -C "${TMP}" \
  "blender-${BLENDER_VERSION}/release/datafiles/startup.blend" \
  "blender-${BLENDER_VERSION}/release/datafiles/icons"

SRC="${TMP}/blender-${BLENDER_VERSION}/release/datafiles"
STARTUP="${SRC}/startup.blend"

if [[ ! -f "${STARTUP}" ]]; then
  echo "Could not extract startup.blend from the source archive." >&2
  exit 1
fi

if head -c 8 "${STARTUP}" | grep -q "BLENDER"; then
  cp "${STARTUP}" "${DATAFILES}/startup.blend"
  echo "Installed ${DATAFILES}/startup.blend"
else
  echo "startup.blend is not a valid blend file (still an LFS pointer?)." >&2
  exit 1
fi

count=0
for dat in "${SRC}"/icons/*.dat; do
  [[ -f "${dat}" ]] || continue
  if head -c 4 "${dat}" | grep -q "VCO"; then
    cp "${dat}" "${ICONS}/"
    count=$((count + 1))
  fi
done
echo "Installed ${count} geometry icons into ${ICONS}/"

echo "Done. Clean-rebuild the iOS app (scheme blender) and reinstall on device."
