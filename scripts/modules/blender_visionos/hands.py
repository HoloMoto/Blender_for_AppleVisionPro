# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Hand tracking capability for Vision Pro add-ons."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from mathutils import Vector

from . import _native


@dataclass(frozen=True)
class Hand:
    """One hand sample in Blender world space (meters, Z-up)."""

    tracked: bool
    wrist: Vector
    palm: Vector
    thumb_tip: Vector
    index_tip: Vector
    middle_tip: Vector
    ring_tip: Vector
    little_tip: Vector
    pinch: float  # 0..1, or -1 if unknown


@dataclass(frozen=True)
class HandSnapshot:
    """Latest dual-hand sample from Immersive Space."""

    ok: bool
    api_version: int
    timestamp: float
    immersive_active: bool
    left: Hand
    right: Hand


def _vec(v: _native.Vec3) -> Vector:
    return Vector((float(v.x), float(v.y), float(v.z)))


def _hand(side: _native.HandSide) -> Hand:
    return Hand(
        tracked=bool(side.tracked),
        wrist=_vec(side.wrist),
        palm=_vec(side.palm),
        thumb_tip=_vec(side.thumb_tip),
        index_tip=_vec(side.index_tip),
        middle_tip=_vec(side.middle_tip),
        ring_tip=_vec(side.ring_tip),
        little_tip=_vec(side.little_tip),
        pinch=float(side.pinch),
    )


def snapshot() -> HandSnapshot:
    """Poll the latest hand pose (call from a timer / modal for live tracking)."""
    ok, raw = _native.hand_snapshot_raw()
    return HandSnapshot(
        ok=ok,
        api_version=int(raw.api_version),
        timestamp=float(raw.timestamp),
        immersive_active=bool(raw.immersive_active),
        left=_hand(raw.left),
        right=_hand(raw.right),
    )


def is_supported() -> bool:
    return "hand_tracking" in __import__("blender_visionos").capabilities()
