# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Persist Preferences (enabled add-ons, settings) on visionOS / iOS.

Desktop Blender writes ``userpref.blend`` from ``WM_exit`` when preferences are
dirty. visionOS never calls ``WM_exit``: the system suspends and kills the
process, so enabled add-ons and changed settings were lost on every launch.

Here preferences are written as soon as they change:

* ``addon_utils.enable`` / ``disable`` with ``default_set=True`` (Preferences
  checkbox, Install…, scripts) save immediately.
* Preference property edits are caught via ``bpy.msgbus`` (any property of the
  Preferences structs) and saved, debounced by a timer with handler fallbacks
  (``depsgraph_update_post`` / ``save_post`` / ``undo_post``).

``Auto-Save Preferences`` (``use_preferences_save``) is respected for property
edits, like desktop. Enabled add-ons are additionally mirrored to
``Documents/Blender/config/enabled_addons.json`` and re-enabled at startup if
``userpref.blend`` could not be read.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

_DOC_ROOT = Path.home() / "Documents" / "Blender"
_LOG = _DOC_ROOT / "prefs_persist.log"
_MANIFEST = _DOC_ROOT / "config" / "enabled_addons.json"

_MIN_INTERVAL = 0.75
_MSGBUS_INTERVAL = 0.1

_state = {
    "ready": False,
    "patched": False,
    "pending": False,
    "last_save": 0.0,
    "saving": False,
    "rna_changed": False,
    "msgbus_hits": 0,
}
_msgbus_owner = object()


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


def _log(msg: str) -> None:
    try:
        _LOG.parent.mkdir(parents=True, exist_ok=True)
        if _LOG.is_file() and _LOG.stat().st_size > 256 * 1024:
            _LOG.unlink()
        with _LOG.open("a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg.rstrip()}\n")
    except Exception:
        pass


def _prefs():
    import bpy

    return bpy.context.preferences


def _config_dir() -> Path | None:
    try:
        import bpy

        path = bpy.utils.user_resource('CONFIG', create=True)
        return Path(path) if path else None
    except Exception as exc:
        _log(f"config_dir_fail {exc}")
        return None


def _enabled_modules() -> list[str]:
    try:
        return sorted(a.module for a in _prefs().addons)
    except Exception:
        return []


def _write_manifest() -> None:
    try:
        _MANIFEST.parent.mkdir(parents=True, exist_ok=True)
        tmp = _MANIFEST.with_suffix(".tmp")
        tmp.write_text(json.dumps({"addons": _enabled_modules()}, indent=1), encoding="utf-8")
        os.replace(tmp, _MANIFEST)
    except Exception as exc:
        _log(f"manifest_write_fail {exc}")


def _read_manifest() -> list[str]:
    try:
        data = json.loads(_MANIFEST.read_text(encoding="utf-8"))
        return [str(m) for m in data.get("addons", []) if m]
    except Exception:
        return []


def _mirror_backup(cfg: Path | None) -> None:
    """Copy the config files next to the manifest so they are visible in Files."""
    if cfg is None:
        return
    try:
        import shutil

        dst = _MANIFEST.parent
        dst.mkdir(parents=True, exist_ok=True)
        for name in ("userpref.blend", "bookmarks.txt", "recent-files.txt"):
            src = cfg / name
            if src.is_file():
                shutil.copy2(src, dst / name)
    except Exception as exc:
        _log(f"backup_fail {exc}")


def save_now(reason: str, *, force: bool = False) -> bool:
    """Write ``userpref.blend`` now. Returns True when written."""
    if not _state["ready"] or _state["saving"]:
        _state["pending"] = True
        return False
    try:
        import bpy

        prefs = _prefs()
        # Keymap edits do not always set ``is_dirty``; a msgbus hit is enough.
        if not force and not (prefs.is_dirty or _state["rna_changed"]):
            _state["pending"] = False
            return False
        if not force and not prefs.use_preferences_save:
            _state["pending"] = False
            _state["rna_changed"] = False
            return False
        _state["saving"] = True
        cfg = _config_dir()
        result = bpy.ops.wm.save_userpref()
        _state["last_save"] = time.monotonic()
        _state["pending"] = False
        _state["rna_changed"] = False
        _write_manifest()
        _mirror_backup(cfg)
        ok = 'FINISHED' in result
        _log(f"save reason={reason} result={sorted(result)} addons={len(prefs.addons)}")
        return ok
    except Exception as exc:
        _log(f"save_fail reason={reason} {exc}")
        return False
    finally:
        _state["saving"] = False


def request_save(reason: str) -> None:
    """Debounced save: immediate when idle, otherwise picked up by the timer/handlers."""
    _state["pending"] = True
    if time.monotonic() - _state["last_save"] >= _MIN_INTERVAL:
        save_now(reason)


def _flush_pending(reason: str) -> None:
    if not _state["ready"]:
        return
    try:
        if _state["pending"] or _prefs().is_dirty:
            if time.monotonic() - _state["last_save"] >= _MIN_INTERVAL:
                save_now(reason)
    except Exception:
        pass


def _patch_addon_utils() -> None:
    if _state["patched"]:
        return
    import addon_utils

    orig_enable = addon_utils.enable
    orig_disable = addon_utils.disable

    def enable(module_name, *args, **kwargs):
        mod = orig_enable(module_name, *args, **kwargs)
        if kwargs.get("default_set") and mod is not None and _state["ready"]:
            _log(f"addon_enable {module_name}")
            save_now(f"addon_enable:{module_name}", force=True)
        return mod

    def disable(module_name, *args, **kwargs):
        result = orig_disable(module_name, *args, **kwargs)
        if kwargs.get("default_set") and _state["ready"]:
            _log(f"addon_disable {module_name}")
            save_now(f"addon_disable:{module_name}", force=True)
        return result

    enable.__wrapped__ = orig_enable
    disable.__wrapped__ = orig_disable
    enable.__doc__ = orig_enable.__doc__
    disable.__doc__ = orig_disable.__doc__
    addon_utils.enable = enable
    addon_utils.disable = disable
    _state["patched"] = True


def _restore_manifest_addons() -> None:
    """Fallback when ``userpref.blend`` was not loaded (missing / unreadable)."""
    wanted = _read_manifest()
    if not wanted:
        return
    try:
        import addon_utils

        enabled = set(_enabled_modules())
        available = {m.__name__ for m in addon_utils.modules(refresh=False)}
        restored = []
        for name in wanted:
            if name in enabled or name not in available:
                continue
            try:
                if addon_utils.enable(name, default_set=True, persistent=True) is not None:
                    restored.append(name)
            except Exception as exc:
                _log(f"restore_fail {name} {exc}")
        if restored:
            _log(f"restored_from_manifest {restored}")
    except Exception as exc:
        _log(f"restore_manifest_fail {exc}")


def _on_pref_changed(*_args) -> None:
    if _state["saving"]:
        return
    _state["rna_changed"] = True
    _state["msgbus_hits"] += 1
    if _state["msgbus_hits"] <= 3:
        _log(f"msgbus_hit {_state['msgbus_hits']}")
    # Same-tick notifications arrive within microseconds; the interval only
    # collapses those and slider drags. Trailing edits are flushed by the
    # timer / handlers.
    _state["pending"] = True
    if time.monotonic() - _state["last_save"] >= _MSGBUS_INTERVAL:
        save_now("msgbus")
    else:
        _ensure_flush_timer()


def _subscribe_msgbus() -> None:
    import bpy

    bpy.msgbus.clear_by_owner(_msgbus_owner)
    types = bpy.types
    names = (
        "Preferences",
        "PreferencesEdit",
        "PreferencesView",
        "PreferencesInput",
        "PreferencesSystem",
        "PreferencesFilePaths",
        "PreferencesKeymap",
        "PreferencesApps",
        "PreferencesExperimental",
        "PreferencesExtensions",
        "Theme",
        "ThemeView3D",
        "ThemeUserInterface",
        "UserSolidLight",
        "UserAssetLibrary",
        "ScriptDirectory",
        "AddonPreferences",
        "KeyConfig",
        "KeyMap",
        "KeyMapItem",
        "KeyConfigPreferences",
        "ThemeSpaceGeneric",
        "ThemeWidgetColors",
        "ThemeGeneralSettings",
        "ThemeSpaceGradient",
        "ThemeSpaceListGeneric",
        "ThemeTextEditor",
        "ThemeNodeEditor",
        "ThemeOutliner",
        "ThemeProperties",
    )
    count = 0
    for name in names:
        struct = getattr(types, name, None)
        if struct is None:
            continue
        try:
            bpy.msgbus.subscribe_rna(
                key=struct,
                owner=_msgbus_owner,
                args=(),
                notify=_on_pref_changed,
                options={'PERSISTENT'},
            )
            count += 1
        except Exception as exc:
            _log(f"msgbus_fail {name} {exc}")
    _log(f"msgbus_subscribed {count}")


def _timer_tick():
    _flush_pending("timer")
    return 2.0


def _flush_once():
    if _state["pending"] or _state["rna_changed"]:
        save_now("flush_timer")
    return None


def _ensure_flush_timer() -> None:
    try:
        import bpy

        if not bpy.app.timers.is_registered(_flush_once):
            bpy.app.timers.register(_flush_once, first_interval=_MSGBUS_INTERVAL + 0.05)
    except Exception:
        pass


def _handler_flush(*_args):
    _flush_pending("handler")


def _register_handlers() -> None:
    import bpy
    from bpy.app.handlers import persistent

    flush = persistent(_handler_flush)
    for hlist in (
        bpy.app.handlers.depsgraph_update_post,
        bpy.app.handlers.save_post,
        bpy.app.handlers.undo_post,
        bpy.app.handlers.redo_post,
    ):
        if not any(getattr(h, "__name__", "") == "_handler_flush" for h in hlist):
            hlist.append(flush)

    @persistent
    def _prefs_persist_load_post(*_a):
        first = not _state["ready"]
        _state["ready"] = True
        try:
            _subscribe_msgbus()
        except Exception as exc:
            _log(f"msgbus_setup_fail {exc}")
        if first:
            cfg = _config_dir()
            userpref = (cfg / "userpref.blend") if cfg else None
            had_file = bool(userpref and userpref.is_file())
            _log(f"startup cfg={cfg} userpref_exists={int(had_file)} addons={_enabled_modules()}")
            if not had_file:
                _restore_manifest_addons()
            # Persist startup-time additions (script directory, restored add-ons).
            save_now("startup", force=not had_file)
            _write_manifest()

    if not any(getattr(h, "__name__", "") == "_prefs_persist_load_post"
               for h in bpy.app.handlers.load_post):
        bpy.app.handlers.load_post.append(_prefs_persist_load_post)

    try:
        if not bpy.app.timers.is_registered(_timer_tick):
            bpy.app.timers.register(_timer_tick, first_interval=3.0, persistent=True)
    except Exception as exc:
        _log(f"timer_fail {exc}")


def bootstrap_at_startup() -> None:
    if not is_apple_mobile():
        return
    try:
        _patch_addon_utils()
        _register_handlers()
        _log("bootstrap ok")
    except Exception as exc:
        _log(f"bootstrap failed: {exc}")
        print(f"blender_ios_prefs_persist: bootstrap failed: {exc}", flush=True)
