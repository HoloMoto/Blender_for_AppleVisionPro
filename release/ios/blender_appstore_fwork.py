# SPDX-FileCopyrightText: 2026 Blender Authors
# SPDX-License-Identifier: GPL-2.0-or-later

"""App Store helpers for native Python extensions on visionOS/iOS.

Apple rejects:
- Mach-O under ``Assets/`` (ITMS-90171)
- ``MH_BUNDLE`` (``.so``) used as framework executables (ITMS-90124)

Packaging gzips extension modules to ``*.so.gz``. This module decompresses them
into the app's Application Support cache on first import and teaches importlib
to load the extracted files.
"""

from __future__ import annotations

import gzip
import importlib.machinery
import os
import sys
import tempfile


def _bundle_root() -> str | None:
    candidates = []
    for base in (getattr(sys, "prefix", None), getattr(sys, "exec_prefix", None), os.environ.get("PYTHONHOME")):
        if base:
            candidates.append(base)
    candidates.append(os.path.abspath(__file__))

    for start in candidates:
        path = os.path.abspath(start)
        for _ in range(10):
            if os.path.isdir(os.path.join(path, "Frameworks")) and (
                os.path.isfile(os.path.join(path, "Info.plist")) or os.path.isdir(os.path.join(path, "Assets"))
            ):
                return path
            parent = os.path.dirname(path)
            if parent == path:
                break
            path = parent
    return None


def _cache_dir() -> str:
    # Prefer Application Support so files persist across launches.
    home = os.path.expanduser("~")
    base = os.path.join(home, "Library", "Application Support", "Blender", "python_native_ext")
    try:
        os.makedirs(base, exist_ok=True)
        return base
    except OSError:
        return tempfile.gettempdir()


def _decompress_so_gz(gz_path: str) -> str:
    """Return path to an extracted ``.so`` for ``gz_path`` (``*.so.gz``)."""
    # Keep a stable relative layout under the cache keyed by absolute gz path.
    key = gz_path.replace(":", "_").replace("/", "_").replace("\\", "_")
    if key.endswith(".so.gz"):
        out_name = key[: -len(".gz")]
    elif key.endswith(".dylib.gz"):
        out_name = key[: -len(".gz")]
    else:
        out_name = key + ".so"
    out_path = os.path.join(_cache_dir(), out_name)
    try:
        gz_mtime = os.path.getmtime(gz_path)
        if os.path.isfile(out_path) and os.path.getmtime(out_path) >= gz_mtime:
            return out_path
    except OSError:
        pass
    with gzip.open(gz_path, "rb") as src, open(out_path, "wb") as dst:
        dst.write(src.read())
    return out_path


def _resolve_fwork(path: str) -> str:
    with open(path, "r", encoding="utf-8") as handle:
        rel = handle.read().strip()
    if os.path.isabs(rel) and os.path.isfile(rel):
        return rel
    root = _bundle_root()
    if root:
        candidate = os.path.join(root, rel)
        if os.path.isfile(candidate):
            return candidate
    guess = os.path.abspath(os.path.join(os.path.dirname(path), rel))
    if os.path.isfile(guess):
        return guess
    return rel


_orig_ext_init = importlib.machinery.ExtensionFileLoader.__init__


def _patched_ext_init(self, name, path):  # type: ignore[no-untyped-def]
    if isinstance(path, str):
        if path.endswith(".so.gz") or path.endswith(".dylib.gz"):
            path = _decompress_so_gz(path)
        elif path.endswith(".fwork"):
            path = _resolve_fwork(path)
            if path.endswith(".so.gz") or path.endswith(".dylib.gz"):
                path = _decompress_so_gz(path)
    _orig_ext_init(self, name, path)


def install() -> None:
    """Register gzipped extension suffixes and patch the extension loader."""
    importlib.machinery.ExtensionFileLoader.__init__ = _patched_ext_init  # type: ignore[method-assign]

    suffixes = importlib.machinery.EXTENSION_SUFFIXES
    extras = []
    for suf in list(suffixes):
        if suf.endswith(".so"):
            gz = suf + ".gz"
            if gz not in suffixes:
                extras.append(gz)
        elif suf.endswith(".dylib"):
            gz = suf + ".gz"
            if gz not in suffixes:
                extras.append(gz)
    for gz in reversed(extras):
        suffixes.insert(0, gz)

    sys.path_importer_cache.clear()
    import importlib

    importlib.invalidate_caches()
