# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""VisionOS bpy Sample X — World mesh fetch only

Immersive Space の空間メッシュ（ARKit scene reconstruction）を
``blender_visionos.world_mesh`` API 経由で取得し、Blender にメッシュ
オブジェクトとして置くだけの最小サンプル。

How to run
----------
1. Vision Pro で Immersive Space を開く（部屋を見渡してメッシュが溜まるまで数秒）
2. Text Editor にこのスクリプトを貼る → Run Script
3. ``VisionOSWorldMesh`` オブジェクトが更新され続ける（WIRE 表示）
4. コンソールに revision / verts / tris / truncated が出る

Requires:
  - blender_visionos.world_mesh  (capability: realitykit_scene)
  - Host Build 96+ recommended (floor+wall packing)

Stop:
  Run again, or call ``sample_x_stop()`` from the console.
"""

from __future__ import annotations

from typing import Optional

import bpy

try:
    import blender_visionos as vision
except ImportError:
    vision = None  # type: ignore

MESH_NAME = "VisionOSWorldMesh"
TIMER_HZ = 5.0

_timer = None
_last_revision = -1
_running = False


def _poll(_: bpy.types.Scene) -> Optional[float]:
    if vision is None:
        print("[SampleX] blender_visionos not available")
        sample_x_stop()
        return None

    if not vision.world_mesh.is_supported():
        # Immersive not open / capability not published yet — keep waiting.
        return 1.0 / TIMER_HZ

    meta = vision.world_mesh.meta()
    if not meta.available or meta.vertex_count < 3:
        return 1.0 / TIMER_HZ

    global _last_revision
    if int(meta.revision) == _last_revision:
        return 1.0 / TIMER_HZ
    _last_revision = int(meta.revision)

    obj = vision.world_mesh.to_mesh_object(MESH_NAME)
    if obj is None:
        return 1.0 / TIMER_HZ

    obj.display_type = 'WIRE'
    obj.hide_render = True
    print(
        f"[SampleX] world_mesh rev={meta.revision} "
        f"v={meta.vertex_count} tris={meta.index_count // 3} "
        f"truncated={meta.truncated}"
    )
    return 1.0 / TIMER_HZ


def sample_x_stop() -> None:
    """Unregister the poll timer."""
    global _timer, _running, _last_revision
    if _timer is not None:
        try:
            bpy.app.timers.unregister(_timer)
        except ValueError:
            pass
        _timer = None
    _running = False
    _last_revision = -1
    print("[SampleX] stopped")


def sample_x_start() -> None:
    """Start (or restart) world-mesh polling."""
    global _timer, _running
    sample_x_stop()
    if vision is None:
        print("[SampleX] ERROR: blender_visionos missing — not a VisionOS build?")
        return
    print("[SampleX] polling world_mesh — open Immersive Space and look around")
    _running = True
    _timer = _poll
    bpy.app.timers.register(_timer, first_interval=0.2)


if __name__ == "__main__":
    if _running:
        sample_x_stop()
    else:
        sample_x_start()
