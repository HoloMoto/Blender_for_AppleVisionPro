# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Blender on Vision Pro — platform API for add-on authors.

This package is the *extensibility surface* for Vision-Pro-specific Blender
add-ons. Treat it like ``bpy`` for Immersive / RealityKit capabilities:

* Check :data:`available` and :func:`capabilities` before use.
* Call capability modules (currently :mod:`blender_visionos.hands`).
* New platform features land as new capability bits / submodules without
  breaking existing add-ons (``api_version`` + ``struct_size`` on native side).

Minimal probe::

    import blender_visionos as vision

    if not vision.available():
        print("Not a Vision Pro build")
    else:
        print("caps", vision.capabilities())
        snap = vision.hands.snapshot()
        if snap.right.tracked:
            print("right index", snap.right.index_tip)

Immersive Space must be open for live hand samples.
Full reference: ``docs/VISIONOS_API.md``.
"""

from __future__ import annotations

from . import _native
from . import hands as hands
from . import world_mesh as world_mesh

__all__ = (
    "available",
    "api_version",
    "capabilities",
    "hands",
    "world_mesh",
)

api_version = _native.API_VERSION


def available() -> bool:
    """True on Apple Vision / cross-platform Immersive builds."""
    return bool(_native.available())


def capabilities() -> frozenset[str]:
    """Named capabilities currently offered by the host.

    Known names:
      ``hand_tracking``, ``immersive_active``,
      ``realitykit_scene`` (RealityKit scene spawn / query; also gates
      :mod:`blender_visionos.world_mesh` — world mesh is published under the
      same bit until a dedicated capability is warranted).
    """
    bits = int(_native.capabilities())
    names = []
    if bits & _native.CAP_HAND_TRACKING:
        names.append("hand_tracking")
    if bits & _native.CAP_IMMERSIVE_ACTIVE:
        names.append("immersive_active")
    if bits & _native.CAP_REALITYKIT_SCENE:
        names.append("realitykit_scene")
    return frozenset(names)
