# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Hand-pose detection for the Vision Pro window 3D viewport.

Peace sign (index + middle extended, ring + little curled, thumb not pinching) on either
hand is detected and exposed through :func:`pose_detected`.

Finger tips come from RealityKit hand joint anchors published through
:mod:`blender_visionos._native` (no extra ARKit session), so the pose is only seen while
an Immersive Space tracks the hands. Planar viewport pan is disabled while Immersive is
open, so the pose never switches drags to pan
(:func:`blender_ios_touch_nav.set_drag_pan_override` stays off).
"""

from __future__ import annotations

import math

POLL_INTERVAL = 0.05

# Tip-to-palm distance divided by wrist-to-palm distance.
EXTEND_ON = 1.25
EXTEND_OFF = 1.10
CURL_ON = 0.95
CURL_OFF = 1.10
PINCH_MAX = 0.5
ENGAGE_FRAMES = 3
RELEASE_FRAMES = 4

_state = {"enabled": True, "override": False, "pose": False, "registered": False}


def _dist(a, b) -> float:
    return math.sqrt((a.x - b.x) ** 2 + (a.y - b.y) ** 2 + (a.z - b.z) ** 2)


def _same(a, b) -> bool:
    return a.x == b.x and a.y == b.y and a.z == b.z


class _Finger:
    __slots__ = ("extended", "curled")

    def __init__(self):
        self.extended = False
        self.curled = False

    def update(self, ratio: float) -> None:
        if self.extended:
            self.extended = ratio > EXTEND_OFF
        else:
            self.extended = ratio > EXTEND_ON
        if self.curled:
            self.curled = ratio < CURL_OFF
        else:
            self.curled = ratio < CURL_ON


class PeaceDetector:
    """Per-hand peace-sign detector with per-finger hysteresis and frame debouncing."""

    def __init__(self):
        self.reset()

    def reset(self) -> None:
        self.index = _Finger()
        self.middle = _Finger()
        self.ring = _Finger()
        self.little = _Finger()
        self.active = False
        self._on = 0
        self._off = 0

    def _pose(self, side) -> bool:
        if not getattr(side, "tracked", 0):
            return False
        palm, wrist = side.palm, side.wrist
        span = _dist(palm, wrist)
        if span < 1e-3:
            return False
        tips = (side.index_tip, side.middle_tip, side.ring_tip, side.little_tip)
        # Untracked joints are published at the palm position.
        if any(_same(tip, palm) for tip in tips):
            return False
        for finger, tip in zip((self.index, self.middle, self.ring, self.little), tips):
            finger.update(_dist(tip, palm) / span)
        pinch = getattr(side, "pinch", -1.0)
        not_pinching = pinch < PINCH_MAX
        return (
            self.index.extended
            and self.middle.extended
            and self.ring.curled
            and self.little.curled
            and not_pinching
        )

    def update(self, side) -> bool:
        if self._pose(side):
            self._on += 1
            self._off = 0
            if self._on >= ENGAGE_FRAMES:
                self.active = True
        else:
            self._off += 1
            self._on = 0
            if self._off >= RELEASE_FRAMES:
                self.active = False
        return self.active


_detectors = {"left": PeaceDetector(), "right": PeaceDetector()}


def _set_override(value: bool) -> None:
    value = bool(value)
    if _state["override"] == value:
        return
    _state["override"] = value
    try:
        import blender_ios_touch_nav

        blender_ios_touch_nav.set_drag_pan_override(value)
    except Exception:
        pass


def update_from_snapshot(snap) -> bool:
    """Feed one hand snapshot; returns whether the peace pose is held."""
    _set_override(False)
    if not _state["enabled"] or not getattr(snap, "immersive_active", 0):
        for det in _detectors.values():
            det.reset()
        _state["pose"] = False
        return False
    pose = False
    for name in ("left", "right"):
        pose |= _detectors[name].update(getattr(snap, name))
    _state["pose"] = pose
    return pose


def is_active() -> bool:
    """Whether the pose currently overrides viewport drags (never while Immersive is open)."""
    return _state["override"]


def pose_detected() -> bool:
    return _state["pose"]


def set_enabled(value: bool) -> None:
    _state["enabled"] = bool(value)
    if not value:
        _set_override(False)


def _poll():
    try:
        from blender_visionos import _native

        ok, snap = _native.hand_snapshot_raw()
        if ok:
            update_from_snapshot(snap)
        elif _state["override"]:
            _set_override(False)
    except Exception:
        return 1.0
    return POLL_INTERVAL


def register() -> None:
    import bpy

    if _state["registered"]:
        return
    _state["registered"] = True
    bpy.app.timers.register(_poll, first_interval=2.0, persistent=True)


def unregister() -> None:
    import bpy

    if bpy.app.timers.is_registered(_poll):
        bpy.app.timers.unregister(_poll)
    _state["registered"] = False
    _set_override(False)
