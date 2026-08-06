# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""ctypes bindings to the Vision Pro platform C ABI (#WM_ios_visionos_api.h)."""

from __future__ import annotations

import ctypes
import sys
from ctypes import (
    POINTER,
    Structure,
    c_double,
    c_float,
    c_int,
    c_uint32,
    c_uint64,
)


API_VERSION = 1

CAP_NONE = 0
CAP_HAND_TRACKING = 1 << 0
CAP_IMMERSIVE_ACTIVE = 1 << 1
CAP_REALITYKIT_SCENE = 1 << 2


class Vec3(Structure):
    _fields_ = (("x", c_float), ("y", c_float), ("z", c_float))


class HandSide(Structure):
    _fields_ = (
        ("tracked", c_uint32),
        ("wrist", Vec3),
        ("palm", Vec3),
        ("thumb_tip", Vec3),
        ("index_tip", Vec3),
        ("middle_tip", Vec3),
        ("ring_tip", Vec3),
        ("little_tip", Vec3),
        ("pinch", c_float),
        ("_pad0", c_float),
    )


class HandSnapshot(Structure):
    _fields_ = (
        ("struct_size", c_uint32),
        ("api_version", c_uint32),
        ("timestamp", c_double),
        ("immersive_active", c_uint32),
        ("_pad1", c_uint32),
        ("left", HandSide),
        ("right", HandSide),
    )


def _load_lib():
    # Symbols are linked into the Blender main executable.
    names = []
    if sys.platform in {"darwin", "ios"}:
        names.append(None)  # process image
    names.append("Blender")
    last = None
    for name in names:
        try:
            return ctypes.CDLL(name)
        except OSError as exc:
            last = exc
    raise OSError(f"Cannot load Blender C symbols for blender_visionos: {last}")


_LIB = None
_FN_AVAILABLE = None
_FN_CAPS = None
_FN_HAND = None


def _lib():
    global _LIB, _FN_AVAILABLE, _FN_CAPS, _FN_HAND
    if _LIB is not None:
        return _LIB
    lib = _load_lib()
    try:
        lib.BLENDER_VISIONOS_available.restype = c_int
        lib.BLENDER_VISIONOS_available.argtypes = []
        lib.BLENDER_VISIONOS_capabilities.restype = c_uint64
        lib.BLENDER_VISIONOS_capabilities.argtypes = []
        lib.BLENDER_VISIONOS_hand_snapshot.restype = c_int
        lib.BLENDER_VISIONOS_hand_snapshot.argtypes = [POINTER(HandSnapshot)]
    except AttributeError:
        # Desktop / builds without the symbol — soft stub.
        _LIB = False
        return _LIB
    _FN_AVAILABLE = lib.BLENDER_VISIONOS_available
    _FN_CAPS = lib.BLENDER_VISIONOS_capabilities
    _FN_HAND = lib.BLENDER_VISIONOS_hand_snapshot
    _LIB = lib
    return _LIB


def available() -> int:
    lib = _lib()
    if not lib:
        return 0
    return int(_FN_AVAILABLE())


def capabilities() -> int:
    lib = _lib()
    if not lib:
        return 0
    return int(_FN_CAPS())


def hand_snapshot_raw() -> tuple[bool, HandSnapshot]:
    snap = HandSnapshot()
    snap.struct_size = ctypes.sizeof(HandSnapshot)
    snap.api_version = API_VERSION
    lib = _lib()
    if not lib:
        return False, snap
    ok = int(_FN_HAND(ctypes.byref(snap))) == 1
    return ok, snap
