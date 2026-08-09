# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""VisionOS bpy Sample Y — Hand pickup + world-mesh collision

空間メッシュを床/壁の当たり判定にし、Hand Tracking のピンチで
立方体を掴んで持ち上げ、離すと落とせるデモ。

How to run
----------
1. Vision Pro で Immersive Space を開く（窓の実寸メッシュが出るまで数秒待つ）
2. Text Editor にこのスクリプトを貼る → Run Script
3. Immersive パネルで「物体移動も空間へ反映（軽量）」が ON になる（スクリプトが自動設定）
4. 右手を立方体へ近づけてピンチ → 持ち上げ → 離すと落下

Requires:
  - blender_visionos.hands
  - blender_visionos.world_mesh  (capability: realitykit_scene)
  - Rigid Body physics (built-in)

Stop:
  Run again, or call ``sample_y_stop()`` from the console.
"""

from __future__ import annotations

import math
from typing import Optional

import bpy
from mathutils import Vector

try:
    import blender_visionos as vision
except ImportError:
    vision = None  # type: ignore

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------

PICKUP_NAME = "VisionPickupCube"
WORLD_MESH_NAME = "VisionOSWorldMesh"
PROXY_NAME = "VisionOSWorldCollider"  # lightweight passive collider
TIMER_HZ = 30.0
PINCH_GRAB = 0.72
PINCH_RELEASE = 0.45
GRAB_RADIUS = 0.22  # meters from cube origin to index tip
WORLD_MESH_MAX_TRIS = 3500  # more → heavier physics; less → coarser floor
GRAVITY = Vector((0.0, 0.0, -9.81))

_timer = None
_grabbed: Optional[bpy.types.Object] = None
_grab_offset = Vector((0, 0, 0))
_last_mesh_revision = -1
_running = False


# ---------------------------------------------------------------------------
# Setup helpers
# ---------------------------------------------------------------------------

def _ensure_rigidbody_world(scene: bpy.types.Scene) -> None:
    if scene.rigidbody_world is None:
        bpy.ops.rigidbody.world_add()
    scene.use_gravity = True
    scene.gravity = GRAVITY
    rbw = scene.rigidbody_world
    if hasattr(rbw, "time_scale"):
        rbw.time_scale = 1.0
    # Prefer more stable substeps on device
    if hasattr(rbw, "substeps_per_frame"):
        rbw.substeps_per_frame = 10
    if hasattr(rbw, "solver_iterations"):
        rbw.solver_iterations = 10


def _enable_immersive_transform_sync() -> None:
    """Turn on lightweight location sync so falling cubes move in Immersive."""
    wm = bpy.context.window_manager
    if hasattr(wm, "immersive_options"):
        try:
            wm.immersive_options.sync_transforms_to_space = True
        except Exception:
            pass
    if hasattr(bpy.ops.wm, "ios_immersive_set_sync_transforms"):
        try:
            bpy.ops.wm.ios_immersive_set_sync_transforms(enable=True)
        except Exception:
            pass


def _ensure_pickup_cube(scene: bpy.types.Scene) -> bpy.types.Object:
    obj = bpy.data.objects.get(PICKUP_NAME)
    if obj is None:
        mesh = bpy.data.meshes.new(PICKUP_NAME)
        # 12cm cube
        s = 0.06
        verts = [
            (-s, -s, -s), (s, -s, -s), (s, s, -s), (-s, s, -s),
            (-s, -s, s), (s, -s, s), (s, s, s), (-s, s, s),
        ]
        faces = [
            (0, 1, 2, 3), (4, 5, 6, 7), (0, 1, 5, 4),
            (2, 3, 7, 6), (0, 3, 7, 4), (1, 2, 6, 5),
        ]
        mesh.from_pydata(verts, [], faces)
        mesh.update()
        obj = bpy.data.objects.new(PICKUP_NAME, mesh)
        scene.collection.objects.link(obj)
        # Start ~70cm in front, 1.2m up (comfortable hold height)
        obj.location = (0.0, -0.7, 1.2)

    if obj.rigid_body is None:
        bpy.context.view_layer.objects.active = obj
        bpy.ops.rigidbody.object_add(type='ACTIVE')
    rb = obj.rigid_body
    rb.type = 'ACTIVE'
    rb.mass = 0.35
    rb.friction = 0.65
    rb.restitution = 0.15
    rb.linear_damping = 0.15
    rb.angular_damping = 0.35
    rb.collision_shape = 'BOX'
    rb.kinematic = False
    rb.use_margin = True
    rb.collision_margin = 0.002
    return obj


def _build_proxy_collider(scene: bpy.types.Scene) -> Optional[bpy.types.Object]:
    """Import world mesh and (optionally) thin it for physics."""
    if vision is None or not vision.world_mesh.is_supported():
        print("[SampleY] world_mesh not supported (need Immersive + realitykit_scene)")
        return None

    meta = vision.world_mesh.meta()
    if not meta.available or meta.vertex_count < 3:
        print("[SampleY] world mesh not ready yet — look around the room, then re-run")
        return None

    # Full visual mesh (optional, hide from render)
    visual = vision.world_mesh.to_mesh_object(WORLD_MESH_NAME)
    if visual is not None:
        visual.hide_render = True
        visual.display_type = 'WIRE'
        if visual.rigid_body is not None:
            bpy.context.view_layer.objects.active = visual
            bpy.ops.rigidbody.object_remove()

    verts, indices = vision.world_mesh.arrays()
    if not verts or not indices:
        return None

    faces = [tuple(indices[i : i + 3]) for i in range(0, len(indices) - 2, 3)]
    # Decimate by stride if too dense
    if len(faces) > WORLD_MESH_MAX_TRIS:
        stride = max(1, len(faces) // WORLD_MESH_MAX_TRIS)
        faces = faces[::stride]
        print(f"[SampleY] collider tris thinned to {len(faces)} (stride={stride})")

    mesh = bpy.data.meshes.get(PROXY_NAME)
    if mesh is None:
        mesh = bpy.data.meshes.new(PROXY_NAME)
    else:
        mesh.clear_geometry()
    mesh.from_pydata(verts, [], faces)
    mesh.update()

    obj = bpy.data.objects.get(PROXY_NAME)
    if obj is None:
        obj = bpy.data.objects.new(PROXY_NAME, mesh)
        scene.collection.objects.link(obj)
    else:
        obj.data = mesh

    obj.hide_render = True
    obj.display_type = 'WIRE'
    obj.show_in_front = True

    bpy.context.view_layer.objects.active = obj
    if obj.rigid_body is None:
        bpy.ops.rigidbody.object_add(type='PASSIVE')
    rb = obj.rigid_body
    rb.type = 'PASSIVE'
    rb.collision_shape = 'MESH'
    rb.friction = 0.9
    rb.restitution = 0.05
    rb.use_margin = True
    rb.collision_margin = 0.01
    # Passiveive meshes are static floors/walls
    rb.kinematic = False

    global _last_mesh_revision
    _last_mesh_revision = int(meta.revision)
    print(
        f"[SampleY] world collider OK  verts={len(verts)} tris={len(faces)} "
        f"rev={meta.revision} truncated={meta.truncated}"
    )
    return obj


def _maybe_refresh_world_mesh(scene: bpy.types.Scene) -> None:
    """Rebuild RB collider when the world_mesh *API* publishes a newer revision.

    Walls/floor coverage comes from the host publisher. This sample only mirrors
    ``world_mesh.arrays()`` — bpy cannot invent anchors the API dropped.
    """
    if vision is None:
        return
    meta = vision.world_mesh.meta()
    if not meta.available:
        return
    global _last_mesh_revision
    if int(meta.revision) == _last_mesh_revision:
        return
    # Avoid refresh while holding an object
    if _grabbed is not None:
        return
    print(
        f"[SampleY] world_mesh API rev={meta.revision} "
        f"v={meta.vertex_count} i={meta.index_count} truncated={meta.truncated}"
    )
    if meta.truncated:
        print(
            "[SampleY] API truncated=True — host dropped some anchors "
            "(e.g. wall without floor). Fix belongs in blender_visionos "
            "world_mesh publish packing, not in this sample."
        )
    _build_proxy_collider(scene)


# ---------------------------------------------------------------------------
# Hand grab / drop
# ---------------------------------------------------------------------------

def _right_pinch(snap) -> tuple[bool, float, Vector]:
    h = snap.right
    if not h.tracked:
        return False, 0.0, Vector((0, 0, 0))
    pinch = float(h.pinch)
    # Fallback: thumb–index distance if pinch unknown
    if pinch < 0.0:
        d = (h.thumb_tip - h.index_tip).length
        pinch = 1.0 - min(1.0, d / 0.06)
    tip = Vector(h.index_tip)
    return True, pinch, tip


def _set_held(obj: bpy.types.Object, held: bool) -> None:
    if obj.rigid_body is None:
        return
    obj.rigid_body.kinematic = held
    if held:
        # Kill residual velocity by toggling dynamic briefly via kinematic
        pass


def _tick():
    global _grabbed, _grab_offset, _running
    if not _running:
        return None

    scene = bpy.context.scene
    cube = bpy.data.objects.get(PICKUP_NAME)
    if cube is None:
        return TIMER_HZ

    if vision is None or not vision.available():
        return TIMER_HZ

    # Keep Immersive transform sync on
    _enable_immersive_transform_sync()
    _maybe_refresh_world_mesh(scene)

    snap = vision.hands.snapshot()
    if not snap.ok or not snap.immersive_active:
        return TIMER_HZ

    tracked, pinch, tip = _right_pinch(snap)
    if not tracked:
        # Lost tracking while holding → drop
        if _grabbed is not None:
            _set_held(_grabbed, False)
            _grabbed = None
            print("[SampleY] drop (tracking lost)")
        return TIMER_HZ

    if _grabbed is None:
        if pinch >= PINCH_GRAB:
            dist = (Vector(cube.matrix_world.translation) - tip).length
            if dist <= GRAB_RADIUS:
                _grabbed = cube
                _grab_offset = Vector(cube.matrix_world.translation) - tip
                _set_held(cube, True)
                print(f"[SampleY] GRAB  pinch={pinch:.2f} dist={dist:.3f}")
    else:
        if pinch <= PINCH_RELEASE:
            _set_held(_grabbed, False)
            print(f"[SampleY] DROP  pinch={pinch:.2f}")
            _grabbed = None
        else:
            # Follow hand (kinematic)
            target = tip + _grab_offset
            _grabbed.location = target
            # Optional: gentle orientation stay upright
            # _grabbed.rotation_euler = (0, 0, 0)

    return TIMER_HZ


# ---------------------------------------------------------------------------
# Public entry / exit
# ---------------------------------------------------------------------------

def sample_y_stop() -> None:
    """Stop the sample timer (safe to call from console)."""
    global _timer, _grabbed, _running
    _running = False
    if _timer is not None:
        try:
            bpy.app.timers.unregister(_timer)
        except Exception:
            pass
        _timer = None
    if _grabbed is not None:
        _set_held(_grabbed, False)
        _grabbed = None
    print("[SampleY] stopped")


def sample_y_start() -> None:
    """Create scene props and start the hand/physics loop."""
    global _timer, _running, _grabbed

    sample_y_stop()

    if vision is None or not vision.available():
        print("[SampleY] ERROR: blender_visionos not available (not a Vision Pro build?)")
        return

    caps = vision.capabilities()
    print(f"[SampleY] capabilities={sorted(caps)}")
    if "hand_tracking" not in caps:
        print("[SampleY] WARN: hand_tracking missing — open Immersive Space")
    if "realitykit_scene" not in caps:
        print("[SampleY] WARN: realitykit_scene missing — world mesh unavailable yet")

    scene = bpy.context.scene
    _ensure_rigidbody_world(scene)
    _enable_immersive_transform_sync()
    cube = _ensure_pickup_cube(scene)
    collider = _build_proxy_collider(scene)

    print("[SampleY] -------------------------------------------")
    print("[SampleY] Sample Y ready")
    print(f"[SampleY]   pickup : {cube.name} @ {tuple(round(c, 3) for c in cube.location)}")
    print(f"[SampleY]   collider: {collider.name if collider else '(waiting for world mesh)'}")
    print("[SampleY]   tip: re-run after walking a bit if collider is missing")
    print("[SampleY]   controls: RIGHT hand pinch near cube = grab, release = drop")
    print("[SampleY] -------------------------------------------")

    _grabbed = None
    _running = True
    _timer = _tick
    bpy.app.timers.register(_timer, first_interval=0.2)


# Auto-run when executed from Text Editor (Alt+P)
if __name__ == "__main__":
    sample_y_start()
