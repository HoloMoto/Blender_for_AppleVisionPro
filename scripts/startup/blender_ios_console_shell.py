# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Python Console: accept ``pip install`` / ``python -v`` (shell-ish SyntaxError otherwise)."""

from __future__ import annotations

import os
import sys
import traceback
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import bpy


_SMOKE = Path.home() / "Documents" / "Blender" / "console_shell_smoke.txt"
_patched = False


def _is_apple_mobile() -> bool:
    if sys.platform == "ios":
        return True
    py = os.environ.get("BLENDER_SYSTEM_PYTHON", "")
    return "Assets" in py.replace("\\", "/")


def _write_smoke(text: str) -> None:
    try:
        _SMOKE.parent.mkdir(parents=True, exist_ok=True)
        _SMOKE.write_text(text, encoding="utf-8")
    except Exception:
        pass


def _run_rewritten(context, line: str, py: str):
    import console_python as cp

    sc = context.space_data
    console, stdout, stderr = cp.get_console(hash(context.region))
    bpy.ops.console.scrollback_append(text=sc.prompt + line, type="INPUT")
    with redirect_stdout(stdout), redirect_stderr(stderr):
        try:
            exec(compile(py, "<ios_console>", "exec"), console.locals)
        except Exception:
            stderr.write(traceback.format_exc())
    out = stdout.getvalue()
    err = stderr.getvalue()
    stdout.truncate(0)
    stdout.seek(0)
    stderr.truncate(0)
    stderr.seek(0)
    if out:
        cp.add_scrollback(out, "OUTPUT")
    if err:
        cp.add_scrollback(err, "ERROR")
    bpy.ops.console.history_append(text="", current_character=0, remove_duplicates=True)
    sc.prompt = cp.PROMPT
    for func, args in getattr(cp.execute, "hooks", []):
        func(*args)
    return {"FINISHED"}


def _patch_console_python() -> None:
    import console_python as cp
    import blender_ios_pip as pip

    orig_execute = cp.execute
    orig_banner = cp.banner

    def execute(context, is_interactive):
        sc = context.space_data
        try:
            line = sc.history[-1].body
        except Exception:
            return orig_execute(context, is_interactive)
        py = pip.rewrite_console_line(line)
        if py is None:
            return orig_execute(context, is_interactive)
        return _run_rewritten(context, line, py)

    execute.hooks = getattr(orig_execute, "hooks", [])

    def banner(context):
        result = orig_banner(context)
        try:
            cp.add_scrollback("visionOS: pip install PACKAGE   /   python -v", "INFO")
            cp.add_scrollback("Preferences → Add-ons → Install Package も同じ pip", "INFO")
            cp.add_scrollback("numpy/scipy/matplotlib は visionOS に wheel が無い", "INFO")
        except Exception:
            pass
        return result

    cp.execute = execute
    cp.banner = banner


def _patch_console_shell() -> None:
    try:
        import console_shell as sh
        import blender_ios_pip as pip
    except Exception:
        return
    orig = sh.execute

    def execute(context, is_interactive):
        sc = context.space_data
        try:
            line = sc.history[-1].body
        except Exception:
            return orig(context, is_interactive)
        py = pip.rewrite_console_line(line)
        if py is None:
            return orig(context, is_interactive)
        return _run_rewritten(context, line, py)

    sh.execute = execute


def _draw_console_pip(self, context):
    if not _is_apple_mobile():
        return
    row = self.layout.row(align=True)
    row.operator("preferences.ios_pip_install", text="pip install", icon="IMPORT")


class TEXT_OT_ios_run_or_pip(bpy.types.Operator):
    """Run the Text Editor buffer; shell-ish pip/python lines are rewritten first."""

    bl_idname = "text.ios_run_or_pip"
    bl_label = "Run Script"
    bl_description = "Run Script. pip install / python -v in the buffer are accepted"
    bl_options = {"REGISTER"}

    @classmethod
    def poll(cls, context):
        area = getattr(context, "area", None)
        if area is None or area.type != "TEXT_EDITOR":
            return False
        st = getattr(context, "space_data", None)
        return bool(st and getattr(st, "text", None))

    def execute(self, context):
        import io

        import blender_ios_pip as pip

        st = context.space_data
        text = st.text
        src = text.as_string()
        rewritten = pip.rewrite_script_source(src)
        if rewritten is None:
            return bpy.ops.text.run_script()
        ns = {"__name__": "__main__", "bpy": bpy}
        buf = io.StringIO()
        try:
            with redirect_stdout(buf), redirect_stderr(buf):
                exec(compile(rewritten, text.name or "<text>", "exec"), ns)
        except Exception as exc:
            msg = traceback.format_exc()
            print(msg, flush=True)
            self.report({"ERROR"}, (msg or str(exc))[-500:])
            return {"CANCELLED"}
        out = buf.getvalue()
        if out:
            print(out, flush=True)
            self.report({"INFO"}, out[-500:])
        return {"FINISHED"}


def _remap_run_script_keymaps() -> None:
    wm = bpy.context.window_manager
    if wm is None:
        return
    for kc in (wm.keyconfigs.addon, wm.keyconfigs.user, wm.keyconfigs.default):
        if kc is None:
            continue
        for km in kc.keymaps:
            for kmi in km.keymap_items:
                if kmi.idname == "text.run_script":
                    kmi.idname = "text.ios_run_or_pip"


def _attach_header() -> None:
    cls = getattr(bpy.types, "CONSOLE_HT_header", None)
    if cls is None:
        return
    try:
        cls.append(_draw_console_pip)
    except Exception:
        pass


def _boot():
    try:
        import blender_ios_pip as pip

        a = pip.rewrite_console_line("pip install music21")
        b = pip.rewrite_console_line("Python -v")
        c = pip.rewrite_console_line("print(1)")
        d = pip.rewrite_script_source("pip install music21\npython -v\n")
        ok = (
            bool(a)
            and "install_packages" in a
            and "music21" in a
            and bool(b)
            and "sys.version" in b
            and c is None
            and bool(d)
            and "install_packages" in d
            and "sys.version" in d
        )
        _write_smoke(
            f"register_ok={int(ok)}\n"
            f"pip_install={a}\n"
            f"python_v={b}\n"
            f"print_passthrough={c}\n"
            f"script_rewrite={d}\n"
        )
        if _is_apple_mobile():
            _patch_console_python()
            _patch_console_shell()
            _attach_header()
            _remap_run_script_keymaps()
    except Exception as exc:
        _write_smoke(f"register_ok=0\nerror={exc}\n")
    return None


def register():
    try:
        bpy.utils.register_class(TEXT_OT_ios_run_or_pip)
    except Exception:
        pass
    bpy.app.timers.register(_boot, first_interval=0.5, persistent=False)


def unregister():
    cls = getattr(bpy.types, "CONSOLE_HT_header", None)
    if cls is not None:
        try:
            cls.remove(_draw_console_pip)
        except Exception:
            pass
    try:
        bpy.utils.unregister_class(TEXT_OT_ios_run_or_pip)
    except Exception:
        pass
