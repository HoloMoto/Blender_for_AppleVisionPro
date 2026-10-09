# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Show the system keyboard for Text Editor and Python Console on visionOS/iOS.

GHOST only pops UITextField for RNA UI buttons. SPACE_TEXT / SPACE_CONSOLE never
call that path, so hardware UTF-8 events never arrive. This inject-only module
adds a header/footer string field that uses the existing GHOST keyboard, then
inserts the committed string into the editor.

Native GHOST is not rebuilt (108/112/119/122/124).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import bpy
from bpy.props import StringProperty
from bpy.types import Operator


_LOG = Path.home() / "Documents" / "ios_keyboard.log"
_SMOKE = Path.home() / "Documents" / "Blender" / "kb_smoke_result.txt"
_applying = False
_target_ptr = 0
_target_kind = ""
_header_attached = False


def _is_apple_mobile() -> bool:
    if sys.platform == "ios":
        return True
    py = os.environ.get("BLENDER_SYSTEM_PYTHON", "")
    return "Assets" in py.replace("\\", "/")


def _log(msg: str) -> None:
    try:
        _LOG.parent.mkdir(parents=True, exist_ok=True)
        with _LOG.open("a", encoding="utf-8") as fh:
            fh.write(msg.rstrip() + "\n")
    except Exception:
        pass


def _write_smoke(text: str) -> None:
    try:
        _SMOKE.parent.mkdir(parents=True, exist_ok=True)
        _SMOKE.write_text(text, encoding="utf-8")
    except Exception:
        pass


def _remember(context) -> None:
    global _target_ptr, _target_kind
    area = getattr(context, "area", None)
    if area and area.type in {"TEXT_EDITOR", "CONSOLE"}:
        _target_ptr = area.as_pointer()
        _target_kind = area.type


def _iter_targets():
    wm = bpy.context.window_manager
    if wm is None:
        return
    for window in wm.windows:
        screen = window.screen
        if screen is None:
            continue
        for area in screen.areas:
            if area.type not in {"TEXT_EDITOR", "CONSOLE"}:
                continue
            region = None
            for reg in area.regions:
                if reg.type == "WINDOW":
                    region = reg
                    break
            if region is None:
                continue
            yield window, area, region


def _override_for_target():
    preferred = None
    fallback = None
    for window, area, region in _iter_targets():
        item = (window, area, region)
        if fallback is None:
            fallback = item
        if _target_ptr and area.as_pointer() == _target_ptr:
            return item
        if _target_kind and area.type == _target_kind and preferred is None:
            preferred = item
    return preferred or fallback


def _insert_chunk(kind: str, chunk: str, ov) -> None:
    if not chunk:
        return
    window, area, region = ov
    with bpy.context.temp_override(window=window, area=area, region=region):
        if kind == "TEXT_EDITOR":
            st = area.spaces.active
            if st is not None and getattr(st, "text", None) is None:
                bpy.ops.text.new()
            bpy.ops.text.insert("EXEC_DEFAULT", text=chunk)
        elif kind == "CONSOLE":
            parts = chunk.split("\n")
            for i, part in enumerate(parts):
                if part:
                    bpy.ops.console.insert("EXEC_DEFAULT", text=part)
                if i < len(parts) - 1:
                    bpy.ops.console.execute("EXEC_DEFAULT")


def _on_line_update(self, context):
    global _applying
    if _applying:
        return
    line = self.ios_kb_line
    if not line:
        return
    _remember(context)
    ov = _override_for_target()
    if ov is None:
        return
    kind = ov[1].type
    _applying = True
    try:
        if kind == "CONSOLE":
            _insert_chunk(kind, line + "\n", ov)
        else:
            _insert_chunk(kind, line, ov)
        self.ios_kb_line = ""
    except Exception as exc:
        _log(f"line_update_fail {exc}")
    finally:
        _applying = False


class WM_OT_ios_editor_keyboard(Operator):
    """Open a string field that uses the system keyboard, then insert into the editor."""

    bl_idname = "wm.ios_editor_keyboard"
    bl_label = "Keyboard"
    bl_description = "Show the system keyboard and insert into the Text Editor or Python Console"
    bl_options = {"REGISTER"}

    text: StringProperty(
        name="Text",
        description="Inserted when you dismiss the keyboard",
        default="",
        maxlen=4096,
    )

    def invoke(self, context, event):
        _remember(context)
        return context.window_manager.invoke_props_dialog(self, width=420)

    def execute(self, context):
        _remember(context)
        if not self.text:
            return {"FINISHED"}
        ov = _override_for_target()
        if ov is None:
            return {"CANCELLED"}
        kind = ov[1].type
        chunk = self.text + ("\n" if kind == "CONSOLE" else "")
        try:
            _insert_chunk(kind, chunk, ov)
        except Exception as exc:
            self.report({"ERROR"}, str(exc))
            _log(f"dialog_insert_fail {exc}")
            return {"CANCELLED"}
        return {"FINISHED"}

    def draw(self, context):
        col = self.layout.column()
        col.label(text="キーボードで入力 → 確定で挿入")
        col.prop(self, "text", text="")


def _draw_header(self, context):
    if not _is_apple_mobile():
        return
    row = self.layout.row(align=True)
    row.operator("wm.ios_editor_keyboard", text="キーボード", icon="OUTLINER_DATA_FONT")
    row.prop(context.window_manager, "ios_kb_line", text="")


def _attach_headers() -> None:
    global _header_attached
    if _header_attached:
        return
    for attr in ("TEXT_HT_header", "CONSOLE_HT_header", "TEXT_HT_footer"):
        cls = getattr(bpy.types, attr, None)
        if cls is None:
            continue
        try:
            cls.append(_draw_header)
            _log(f"header_ok {attr}")
        except Exception as exc:
            _log(f"header_append_fail {attr} {exc}")
    _header_attached = True


def _boot():
    if not _is_apple_mobile():
        return None
    try:
        _attach_headers()
        _write_smoke(
            "register_ok=1\n"
            f"apple_mobile=1\n"
            f"header={int(_header_attached)}\n"
            "objc=0\n"
            "note=GHOST RNA field (no ctypes)\n"
        )
        _log("boot_ok")
    except Exception as exc:
        _log(f"boot_fail {exc}")
        _write_smoke(f"register_ok=0\nerror={exc}\n")
    return None


def register():
    if not _is_apple_mobile():
        _write_smoke("register_ok=0\napple_mobile=0\n")
        return
    try:
        bpy.utils.register_class(WM_OT_ios_editor_keyboard)
        bpy.types.WindowManager.ios_kb_line = StringProperty(
            name="Keyboard",
            description="Tap to show the system keyboard, then dismiss to insert",
            default="",
            maxlen=4096,
            update=_on_line_update,
            options={"SKIP_SAVE"},
        )
        bpy.app.timers.register(_boot, first_interval=0.8, persistent=False)
        _log("register_called")
    except Exception as exc:
        _log(f"register_fail {exc}")
        _write_smoke(f"register_ok=0\nerror={exc}\n")


def unregister():
    global _header_attached
    for attr in ("TEXT_HT_header", "CONSOLE_HT_header", "TEXT_HT_footer"):
        cls = getattr(bpy.types, attr, None)
        if cls is None:
            continue
        try:
            cls.remove(_draw_header)
        except Exception:
            pass
    _header_attached = False
    if hasattr(bpy.types.WindowManager, "ios_kb_line"):
        del bpy.types.WindowManager.ios_kb_line
    try:
        bpy.utils.unregister_class(WM_OT_ios_editor_keyboard)
    except Exception:
        pass
