# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Redirect Python print/stderr to Blender Info reports on visionOS / iOS.

Desktop Blender prints to a system terminal. On Vision Pro there is no such
window, so Text Editor → Run Script looks like a no-op. This module bridges
``sys.stdout`` / ``sys.stderr`` into #WM_global_report (Info editor) and the
device diagnostic log.
"""

from __future__ import annotations

import ctypes
import sys


_INSTALLED = False
_FN = None


def _load_emit():
    global _FN
    if _FN is not None:
        return _FN
    try:
        lib = ctypes.CDLL(None)
        fn = lib.BLENDER_IOS_py_stdout_line
        fn.argtypes = [ctypes.c_char_p, ctypes.c_int]
        fn.restype = None
        _FN = fn
    except Exception:
        _FN = False
    return _FN


def _emit(line: str, is_err: bool) -> None:
    fn = _load_emit()
    if not fn:
        return
    try:
        fn(line.encode("utf-8", errors="replace"), 1 if is_err else 0)
    except Exception:
        pass


class _ReportStream:
    encoding = "utf-8"
    errors = "replace"

    def __init__(self, *, is_err: bool):
        self._is_err = is_err
        self._buf = ""
        self._orig = sys.__stderr__ if is_err else sys.__stdout__

    def write(self, s):
        if not s:
            return 0
        if not isinstance(s, str):
            s = str(s)
        self._buf += s
        written = len(s)
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            if line:
                _emit(line, self._is_err)
        return written

    def flush(self):
        if self._buf:
            _emit(self._buf, self._is_err)
            self._buf = ""

    def isatty(self):
        return False

    def fileno(self):
        # Some libs probe fileno(); fall back to original if possible.
        try:
            return self._orig.fileno()
        except Exception as exc:
            raise OSError("no fileno") from exc

    def writable(self):
        return True

    def readable(self):
        return False


def install() -> bool:
    """Install stdout/stderr redirection. Idempotent."""
    global _INSTALLED
    if _INSTALLED:
        return True
    if not _load_emit():
        return False
    sys.stdout = _ReportStream(is_err=False)
    sys.stderr = _ReportStream(is_err=True)
    _INSTALLED = True
    print("blender_ios_stdout: print() → Info reports")
    return True


def bootstrap_at_startup() -> None:
    try:
        if install():
            return
        print("blender_ios_stdout: native emit unavailable", file=sys.__stderr__)
    except Exception as exc:
        try:
            print(f"blender_ios_stdout failed: {exc}", file=sys.__stderr__)
        except Exception:
            pass
