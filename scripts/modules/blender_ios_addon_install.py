# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""visionOS / iOS safe add-on ZIP install.

Desktop ``extractall`` can jetsam the process on device when a ZIP holds large
``.blend`` payloads (tens of MB) in the same frame as the file picker teardown.
This module:

1. Copies the source ZIP into Documents (security-scoped / iCloud → local).
2. Validates root folder names are importable identifiers.
3. Rejects native extensions (``.so`` / ``.dylib`` / …).
4. Extracts member-by-member with small I/O chunks, ``.py`` first.
5. Optionally spreads work across ``bpy.app.timers`` ticks.
"""

from __future__ import annotations

import gc
import os
import shutil
import traceback
import zipfile
from pathlib import Path

_LOG = Path.home() / "Documents" / "Blender" / "addon_install.log"
_STAGING = Path.home() / "Documents" / "Blender" / "_install_staging"
_CHUNK = 256 * 1024
_NATIVE_SUFFIX = {".so", ".dylib", ".pyd", ".dll"}
_SKIP_SUFFIX = {".pyc", ".pyo"}
_SKIP_DIR = {"__pycache__", ".git", ".DS_Store"}

_STATE: dict | None = None


def _log(msg: str) -> None:
    try:
        _LOG.parent.mkdir(parents=True, exist_ok=True)
        with _LOG.open("a", encoding="utf-8") as fh:
            fh.write(msg.rstrip() + "\n")
    except Exception:
        pass
    print(f"blender_ios_addon_install: {msg}", flush=True)


def _is_mobile() -> bool:
    try:
        import blender_ios_user_scripts as us

        return us.is_apple_mobile()
    except Exception:
        return False


def stage_source(src: str) -> Path:
    """Copy *src* into Documents staging with chunked I/O. Returns local path."""
    _STAGING.mkdir(parents=True, exist_ok=True)
    src_path = Path(src)
    name = src_path.name or "pending.zip"
    dest = _STAGING / name
    if dest.exists():
        try:
            dest.unlink()
        except Exception:
            pass
    # Prefer hardlink / same-volume rename when already under Documents.
    try:
        src_resolved = src_path.resolve()
        if str(src_resolved).startswith(str(Path.home() / "Documents")):
            shutil.copyfile(src_resolved, dest)
            _log(f"stage_copy_local {src_resolved} -> {dest}")
            return dest
    except Exception:
        pass
    with open(src, "rb") as rf, open(dest, "wb") as wf:
        while True:
            buf = rf.read(_CHUNK)
            if not buf:
                break
            wf.write(buf)
    _log(f"stage_copy_chunked {src} -> {dest} bytes={dest.stat().st_size}")
    return dest


def _root_namelist(zf: zipfile.ZipFile) -> list[str]:
    import os as _os

    roots: list[str] = []
    for f in zf.namelist():
        f = _os.path.normpath(f)
        if _os.sep not in f:
            roots.append(f)
    return roots


def _safe_dest(path_addons: Path, member_name: str) -> Path | None:
    """Resolve member path under path_addons; reject zip-slip."""
    # Zip members use forward slashes.
    parts = [p for p in member_name.replace("\\", "/").split("/") if p and p != "."]
    if any(p == ".." for p in parts):
        return None
    if any(p in _SKIP_DIR for p in parts):
        return None
    dest = path_addons.joinpath(*parts)
    try:
        dest.resolve().relative_to(path_addons.resolve())
    except Exception:
        return None
    return dest


def _should_skip_member(name: str) -> bool:
    base = os.path.basename(name.rstrip("/"))
    if base in _SKIP_DIR:
        return True
    _root, ext = os.path.splitext(base)
    if ext.lower() in _SKIP_SUFFIX:
        return True
    parts = name.replace("\\", "/").split("/")
    return any(p in _SKIP_DIR for p in parts)


def _is_native_member(name: str) -> bool:
    _root, ext = os.path.splitext(name.rstrip("/"))
    return ext.lower() in _NATIVE_SUFFIX


def _member_priority(name: str) -> int:
    """Lower = earlier. Python first, large blends last."""
    lower = name.lower()
    if lower.endswith(".py"):
        return 0
    if lower.endswith((".txt", ".md", ".json", ".xml", ".csv")):
        return 1
    if lower.endswith((".blend", ".blend1")):
        return 9
    if _is_native_member(name):
        return 99
    return 5


def validate_roots(roots: list[str]) -> str | None:
    """Return error message if roots are not valid add-on module names."""
    if not roots:
        return "ZIP has no top-level entries"
    if "__init__.py" in roots:
        return "ZIP packaged incorrectly; __init__.py should be in a directory, not at top-level"
    bad = []
    for r in roots:
        stem = os.path.splitext(r)[0]
        if not stem.isidentifier():
            bad.append(r)
    if bad:
        return (
            "ZIP top-level name is not a valid Python module id "
            f"(no spaces/symbols): {bad!r}. Rename the folder inside the ZIP."
        )
    return None


def extract_member_chunked(zf: zipfile.ZipFile, info: zipfile.ZipInfo, dest: Path) -> None:
    if info.is_dir() or info.filename.endswith("/"):
        dest.mkdir(parents=True, exist_ok=True)
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    with zf.open(info, "r") as src, open(dest, "wb") as out:
        while True:
            buf = src.read(_CHUNK)
            if not buf:
                break
            out.write(buf)


def install_zip_sync(
    zip_path: str | Path,
    path_addons: str | Path,
    *,
    overwrite: bool = True,
) -> tuple[list[str], list[str]]:
    """Extract ZIP synchronously (chunked). Returns (roots, skipped_native)."""
    path_addons = Path(path_addons)
    path_addons.mkdir(parents=True, exist_ok=True)
    skipped_native: list[str] = []
    with zipfile.ZipFile(zip_path, "r") as zf:
        roots = _root_namelist(zf)
        err = validate_roots(roots)
        if err:
            raise RuntimeError(err)
        if overwrite:
            for r in roots:
                target = path_addons / os.path.basename(r)
                if target.is_dir() and not target.is_symlink():
                    shutil.rmtree(target, ignore_errors=True)
                elif target.exists():
                    try:
                        target.unlink()
                    except Exception:
                        pass
        infos = sorted(zf.infolist(), key=lambda i: (_member_priority(i.filename), i.filename))
        for info in infos:
            name = info.filename
            if _should_skip_member(name):
                continue
            if _is_native_member(name):
                skipped_native.append(name)
                _log(f"skip_native {name}")
                continue
            dest = _safe_dest(path_addons, name)
            if dest is None:
                _log(f"skip_unsafe {name}")
                continue
            extract_member_chunked(zf, info, dest)
            if _member_priority(name) >= 9:
                gc.collect()
    _log(f"extract_done roots={roots} skipped_native={len(skipped_native)}")
    return roots, skipped_native


def _finish_refresh(addons_new: set[str], enable_on_install: bool) -> None:
    import addon_utils
    import bpy

    bpy.utils.refresh_script_paths()
    addon_utils.modules_refresh()
    for name in sorted(addons_new):
        try:
            addon_utils.disable(name, default_set=True)
        except Exception:
            pass
    if enable_on_install:
        for name in sorted(addons_new):
            try:
                addon_utils.enable(name, default_set=True, persistent=True)
                _log(f"enabled {name}")
            except Exception as exc:
                _log(f"enable_fail {name} {exc}")


def _async_tick() -> float | None:
    global _STATE
    st = _STATE
    if not st:
        return None
    try:
        if st.get("phase") == "extract":
            zf: zipfile.ZipFile = st["zf"]
            infos: list = st["infos"]
            idx: int = st["idx"]
            path_addons = Path(st["path_addons"])
            # One large member or a few small ones per tick.
            budget = 1
            processed = 0
            while idx < len(infos) and processed < budget:
                info = infos[idx]
                idx += 1
                name = info.filename
                if _should_skip_member(name):
                    continue
                if _is_native_member(name):
                    st["skipped_native"].append(name)
                    continue
                dest = _safe_dest(path_addons, name)
                if dest is None:
                    continue
                extract_member_chunked(zf, info, dest)
                processed += 1
                if _member_priority(name) >= 9:
                    gc.collect()
            st["idx"] = idx
            if idx < len(infos):
                return 0.05
            # Done extracting.
            try:
                zf.close()
            except Exception:
                pass
            st["phase"] = "finish"
            return 0.05

        if st.get("phase") == "finish":
            roots = st["roots"]
            addons_new = {os.path.splitext(r)[0] for r in roots}
            _finish_refresh(addons_new, st.get("enable_on_install", False))
            skipped = st.get("skipped_native") or []
            msg = (
                f"Modules Installed ({', '.join(sorted(addons_new))}) "
                f"into {st['path_addons']}"
            )
            if skipped:
                msg += f" (skipped {len(skipped)} native file(s))"
            _log(msg)
            try:
                import bpy

                # Best-effort UI report.
                wm = bpy.context.window_manager
                if wm:
                    # Operators may be gone; print is enough.
                    pass
            except Exception:
                pass
            # Cleanup staging zip (keep log).
            try:
                staged = Path(st.get("staged", ""))
                if staged.is_file():
                    staged.unlink()
            except Exception:
                pass
            _STATE = None
            return None
    except Exception:
        _log("async_fail\n" + traceback.format_exc())
        try:
            if st and st.get("zf"):
                st["zf"].close()
        except Exception:
            pass
        _STATE = None
        return None
    return None


def begin_async_install(
    *,
    filepath: str,
    path_addons: str,
    overwrite: bool = True,
    enable_on_install: bool = False,
) -> str:
    """Stage ZIP and schedule timer extract. Returns status message."""
    global _STATE
    import bpy

    if _STATE is not None:
        return "Another add-on install is already in progress"

    staged = stage_source(filepath)
    if not zipfile.is_zipfile(staged):
        raise RuntimeError(f"Not a ZIP file: {filepath}")

    path_addons_p = Path(path_addons)
    path_addons_p.mkdir(parents=True, exist_ok=True)

    zf = zipfile.ZipFile(staged, "r")
    roots = _root_namelist(zf)
    err = validate_roots(roots)
    if err:
        zf.close()
        raise RuntimeError(err)

    if overwrite:
        for r in roots:
            target = path_addons_p / os.path.basename(r)
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target, ignore_errors=True)
            elif target.exists():
                try:
                    target.unlink()
                except Exception:
                    pass

    infos = sorted(zf.infolist(), key=lambda i: (_member_priority(i.filename), i.filename))
    _STATE = {
        "phase": "extract",
        "zf": zf,
        "infos": infos,
        "idx": 0,
        "roots": roots,
        "path_addons": str(path_addons_p),
        "enable_on_install": enable_on_install,
        "skipped_native": [],
        "staged": str(staged),
    }
    bpy.app.timers.register(_async_tick, first_interval=0.05, persistent=False)
    _log(f"async_start roots={roots} members={len(infos)}")
    return (
        f"Installing {', '.join(roots)} in background "
        f"({len(infos)} files) → {path_addons_p}"
    )


def install_py_file(src: str, path_addons: str, *, overwrite: bool = True) -> str:
    path_addons_p = Path(path_addons)
    path_addons_p.mkdir(parents=True, exist_ok=True)
    name = os.path.basename(src)
    stem = os.path.splitext(name)[0]
    if not stem.isidentifier():
        raise RuntimeError(
            f"File name is not a valid Python module id: {name!r}"
        )
    dest = path_addons_p / name
    if dest.exists() and overwrite:
        try:
            dest.unlink()
        except Exception:
            pass
    staged = stage_source(src)
    shutil.copyfile(staged, dest)
    try:
        staged.unlink()
    except Exception:
        pass
    return stem
