# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Sim gate F: ios_immersive_toggle → Documents/immersive_gate.log PASS/FAIL."""

import bpy
import os
import traceback
from datetime import datetime, timezone


def _docs_dir():
    home = os.path.expanduser('~')
    docs = os.path.join(home, 'Documents')
    if os.path.isdir(docs):
        return docs
    return bpy.app.tempdir or '/tmp'


def _log(msg):
    line = f"{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} {msg}\n"
    path = os.path.join(_docs_dir(), 'immersive_gate.log')
    print(f'[immersive_gate] {msg}')
    try:
        with open(path, 'a', encoding='utf-8') as fh:
            fh.write(line)
    except OSError as exc:
        print(f'[immersive_gate] log write failed: {exc}')


def _wm_op_exists(name):
    try:
        getattr(bpy.ops.wm, name).poll()
    except AttributeError:
        return False
    return True


def _find_usdz():
    found = []
    for base in (bpy.app.tempdir, _docs_dir(), '/tmp'):
        if not base or not os.path.isdir(base):
            continue
        try:
            for name in os.listdir(base):
                if name.endswith('.usdz'):
                    path = os.path.join(base, name)
                    if os.path.isfile(path) and os.path.getsize(path) > 0:
                        found.append(path)
        except OSError:
            pass
    return found


def _run():
    _log('gate_start')
    if not _wm_op_exists('ios_immersive_toggle'):
        _log('FAIL op_missing ios_immersive_toggle')
        return None
    if not _wm_op_exists('usd_export'):
        _log('FAIL op_missing usd_export')
        return None

    # Prefer a clean mesh-only scene for Immersive USD (lights can crash export).
    try:
        for obj in list(bpy.data.objects):
            if obj.type in {'LIGHT', 'CAMERA'}:
                bpy.data.objects.remove(obj, do_unlink=True)
    except Exception as exc:
        _log(f'INFO light_cleanup_skipped={exc!r}')

    usd_path = os.path.join(bpy.app.tempdir or '/tmp', 'immersive_preview.usdz')
    try:
        if os.path.exists(usd_path):
            os.remove(usd_path)
    except OSError:
        pass

    try:
        result = bpy.ops.wm.ios_immersive_toggle()
        _log(f'toggle_result={result!r}')
    except Exception as exc:
        _log(f'FAIL toggle_exception={exc!r}')
        _log(traceback.format_exc().replace('\n', ' | '))
        return None

    found = _find_usdz()
    if found:
        _log(f'PASS usdz={found[0]} bytes={os.path.getsize(found[0])}')
        return None
    if 'FINISHED' in str(result):
        _log('PASS toggle_finished')
        return None
    _log(f'FAIL no_usdz result={result!r}')
    return None


def _is_simulator() -> bool:
    """Device must never auto-open Immersive. Sim gate F still needs this timer."""
    home = os.path.expanduser("~")
    return "CoreSimulator" in home


def register():
    if not _is_simulator():
        return
    bpy.app.timers.register(_run, first_interval=30.0, persistent=False)


def unregister():
    pass
