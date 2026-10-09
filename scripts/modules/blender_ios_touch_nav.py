# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Nomad-style touch navigation for the Vision Pro window 3D viewport.

With the setting on (default), finger input in the 3D viewport maps to:

* Two-finger drag: pan. Two-finger pinch: zoom (unchanged).
* One-finger drag starting on empty space: orbit.
  Sculpt / paint modes with a brush tool: "empty" = the active object is not under
  the finger, so strokes that start on the mesh still sculpt / paint.
  Object / Edit / Pose modes with a select tool: "empty" = no geometry under the finger,
  the drag orbits instead of box-selecting. Other tools (move, cursor, annotate, ...)
  are untouched.

Pen / Muse and mouse / trackpad input are never remapped. With the setting off,
two-finger drag orbits and one-finger drag always reaches the tool (TF-157 behavior).

The setting is stored in ``<config>/touch_navigation.json`` and pushed to the native
host through :mod:`blender_visionos._native`.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

_FILENAME = "touch_navigation.json"
_state = {"enabled": True, "drag_pan": False, "loaded": False}


def _native():
    try:
        from blender_visionos import _native

        return _native
    except Exception:
        return None


def available() -> bool:
    n = _native()
    try:
        return bool(n and n.touch_navigation_available())
    except Exception:
        return False


def _config_path() -> Path | None:
    try:
        import bpy

        path = bpy.utils.user_resource('CONFIG', create=True)
        return Path(path) / _FILENAME if path else None
    except Exception:
        return None


def _load() -> None:
    _state["loaded"] = True
    path = _config_path()
    if path is None or not path.is_file():
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        _state["enabled"] = bool(data.get("enabled", True))
    except Exception:
        pass


def _save() -> None:
    path = _config_path()
    if path is None:
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"enabled": _state["enabled"]}), encoding="utf-8")
        os.replace(tmp, path)
    except Exception:
        pass


def flags() -> int:
    n = _native()
    if n is None:
        return 0
    value = n.TOUCH_NAV_DEFAULT if _state["enabled"] else 0
    if _state["drag_pan"]:
        value |= n.TOUCH_NAV_DRAG_PAN
    return value


def apply() -> bool:
    n = _native()
    if n is None:
        return False
    try:
        return bool(n.set_touch_navigation(flags()))
    except Exception:
        return False


def is_enabled() -> bool:
    if not _state["loaded"]:
        _load()
    return _state["enabled"]


def set_enabled(value: bool) -> None:
    if not _state["loaded"]:
        _load()
    _state["enabled"] = bool(value)
    _save()
    apply()


def set_drag_pan_override(value: bool) -> None:
    """While True, every one-finger viewport drag pans (used by hand-pose navigation)."""
    if _state["drag_pan"] == bool(value):
        return
    _state["drag_pan"] = bool(value)
    apply()


# -----------------------------------------------------------------------------
# UI


_PROP = "vp_touch_nomad_navigation"


def _prop_get(_self):
    return is_enabled()


def _prop_set(_self, value):
    set_enabled(value)


def _draw_prefs(self, context):
    if not available():
        return
    layout = self.layout
    layout.separator()
    col = layout.column(heading="Touch (Vision Pro)")
    col.prop(context.window_manager, _PROP, text="Nomad-Style Navigation")


def _draw_view_menu(self, context):
    if not available():
        return
    layout = self.layout
    layout.separator()
    layout.prop(context.window_manager, _PROP, text="Nomad-Style Touch Navigation")


def register() -> None:
    import bpy

    _load()
    apply()
    setattr(
        bpy.types.WindowManager,
        _PROP,
        bpy.props.BoolProperty(
            name="Nomad-Style Touch Navigation",
            description=(
                "Window 3D viewport, finger input only: two-finger drag pans, "
                "one-finger drag starting on empty space orbits "
                "(off the mesh with sculpt/paint brushes, off geometry with select tools). "
                "Off: two-finger drag orbits, one-finger drag always uses the tool"
            ),
            get=_prop_get,
            set=_prop_set,
        ),
    )
    for cls_name, fn in (("USERPREF_PT_navigation_orbit", _draw_prefs), ("VIEW3D_MT_view", _draw_view_menu)):
        cls = getattr(bpy.types, cls_name, None)
        if cls is not None:
            cls.append(fn)


def unregister() -> None:
    import bpy

    for cls_name, fn in (("USERPREF_PT_navigation_orbit", _draw_prefs), ("VIEW3D_MT_view", _draw_view_menu)):
        cls = getattr(bpy.types, cls_name, None)
        if cls is not None:
            try:
                cls.remove(fn)
            except Exception:
                pass
    if hasattr(bpy.types.WindowManager, _PROP):
        delattr(bpy.types.WindowManager, _PROP)
