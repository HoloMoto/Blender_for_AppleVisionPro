# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Writable external scripts/addons under Documents (visionOS / iOS).

Desktop Blender installs add-ons into the user SCRIPTS tree. On Apple mobile the
default Application Support path is easy to miss and Install can write somewhere
that does not show up in Files. Mirror the pip layout:

  Documents/Blender/scripts/addons/   ← custom / zip-installed add-ons
  Documents/Blender/scripts/modules/
  Documents/Blender/scripts/startup/

Sets ``BLENDER_USER_SCRIPTS`` so ``preferences.addon_install`` and
``addon_utils.paths()`` use this tree. Pure-Python only — native ``.so`` add-ons
will not load on visionOS.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


_ENV = "BLENDER_USER_SCRIPTS"
_LOG = Path.home() / "Documents" / "Blender" / "user_scripts_bootstrap.log"
_SMOKE = Path.home() / "Documents" / "Blender" / "addon_user_scripts_smoke.txt"


def is_apple_mobile() -> bool:
    if os.environ.get("BLENDER_USER_SITE_PACKAGES"):
        return True
    if sys.platform == "ios":
        return True
    home = str(Path.home())
    if "CoreSimulator" in home or "/Containers/Data/" in home:
        return True
    py = os.environ.get("BLENDER_SYSTEM_PYTHON", "")
    return "Assets" in py.replace("\\", "/")


def scripts_root() -> Path:
    override = os.environ.get(_ENV)
    if override:
        return Path(override)
    return Path.home() / "Documents" / "Blender" / "scripts"


def addons_dir() -> Path:
    return scripts_root() / "addons"


def _log(msg: str) -> None:
    try:
        _LOG.parent.mkdir(parents=True, exist_ok=True)
        with _LOG.open("a", encoding="utf-8") as fh:
            fh.write(msg.rstrip() + "\n")
    except Exception:
        pass


def ensure_user_scripts(*, create: bool = True) -> Path:
    """Create Documents scripts tree and point ``BLENDER_USER_SCRIPTS`` at it."""
    root = scripts_root()
    if create:
        for sub in ("addons", "modules", "startup"):
            (root / sub).mkdir(parents=True, exist_ok=True)
    # C++ BKE_appdir reads getenv each call — set before user_resource / install.
    os.environ[_ENV] = str(root)
    return root


def ensure_pref_script_directory() -> None:
    """Expose Documents scripts in Preferences → File Paths → Script Directories."""
    try:
        import bpy
    except Exception:
        return
    root = str(scripts_root())
    paths = bpy.context.preferences.filepaths
    for item in paths.script_directories:
        if item.directory == root or item.name == "Documents":
            if item.directory != root:
                item.directory = root
            return
    try:
        item = paths.script_directories.new()
        item.name = "Documents"
        item.directory = root
        _log(f"script_directory_added {root}")
    except Exception as exc:
        _log(f"script_directory_add_fail {exc}")


def refresh() -> None:
    try:
        import bpy

        bpy.utils.refresh_script_paths()
    except Exception as exc:
        _log(f"refresh_fail {exc}")


def status() -> dict:
    root = ensure_user_scripts(create=True)
    addons = addons_dir()
    entries = sorted(p.name for p in addons.iterdir()) if addons.is_dir() else []
    info = {
        "scripts_root": str(root),
        "addons": str(addons),
        "env": os.environ.get(_ENV, ""),
        "entries": entries[:40],
        "entry_count": len(entries),
    }
    print(
        f"blender_ios_user_scripts: root={root} addons≈{len(entries)}",
        flush=True,
    )
    return info


def _write_smoke_addon() -> Path:
    """Drop a tiny pure-Python add-on for simulator / Files-path verification."""
    path = addons_dir() / "ios_ext_smoke.py"
    path.write_text(
        '''# SPDX-FileCopyrightText: 2026 Blender Authors
# SPDX-License-Identifier: GPL-2.0-or-later
bl_info = {
    "name": "visionOS External Addon Smoke",
    "author": "Blender Vision Pro",
    "version": (1, 0, 0),
    "blender": (4, 2, 0),
    "location": "Preferences → Add-ons",
    "description": "Confirms Documents/Blender/scripts/addons loading",
    "category": "System",
}

def register():
    print("ios_ext_smoke: register", flush=True)

def unregister():
    print("ios_ext_smoke: unregister", flush=True)
''',
        encoding="utf-8",
    )
    return path


def run_smoke() -> None:
    """Verify the Documents add-ons path is discovered (and preferably enableable)."""
    lines: list[str] = []
    try:
        root = ensure_user_scripts(create=True)
        ensure_pref_script_directory()
        refresh()
        smoke_path = _write_smoke_addon()
        refresh()
        lines.append(f"scripts_root={root}")
        lines.append(f"addons={addons_dir()}")
        lines.append(f"env={os.environ.get(_ENV, '')}")
        lines.append(f"smoke_file={smoke_path.is_file()}")

        import addon_utils
        import bpy

        ur = bpy.utils.user_resource("SCRIPTS", path="addons", create=True)
        lines.append(f"user_resource_addons={ur}")
        names = [getattr(m, "__name__", "") for m in addon_utils.modules()]
        found = "ios_ext_smoke" in names
        lines.append(f"modules_found={int(found)}")
        if found:
            # Enable without crashing the host — pure Python only.
            mod = addon_utils.enable("ios_ext_smoke", default_set=True, persistent=True)
            lines.append(f"enable_ok={int(mod is not None)}")
            if mod is not None:
                addon_utils.disable("ios_ext_smoke", default_set=True)
                lines.append("disable_ok=1")
        else:
            lines.append("enable_ok=0")
            # List a few module names for diagnosis.
            lines.append("modules_sample=" + ",".join(n for n in names if n)[:500])
        lines.append(f"register_ok={int(found)}")
    except Exception as exc:
        lines.append(f"register_ok=0")
        lines.append(f"error={exc}")
        _log(f"smoke_fail {exc}")
    try:
        _SMOKE.parent.mkdir(parents=True, exist_ok=True)
        _SMOKE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    except Exception as exc:
        _log(f"smoke_write_fail {exc}")
    _log("smoke " + " | ".join(lines))


def bootstrap_at_startup() -> None:
    if not is_apple_mobile():
        return
    try:
        root = ensure_user_scripts(create=True)
        ensure_pref_script_directory()
        refresh()
        _log(f"bootstrap ok root={root}")
        print(f"blender_ios_user_scripts: user scripts → {root}", flush=True)
        # Simulator / CI: always write smoke. Device: only if request file exists.
        home = str(Path.home())
        req = Path.home() / "Documents" / "Blender" / "addon_smoke_request.txt"
        if "CoreSimulator" in home or req.is_file():
            if req.is_file():
                try:
                    req.unlink()
                except Exception:
                    pass
            run_smoke()
    except Exception as exc:
        _log(f"bootstrap failed: {exc}")
        print(f"blender_ios_user_scripts: bootstrap failed: {exc}", flush=True)
