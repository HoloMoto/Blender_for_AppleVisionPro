# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""World mesh (ARKit scene reconstruction) capability for Vision Pro add-ons.

Requires the ``realitykit_scene`` capability (Immersive Space open + a scene
mesh has been published by the host at least once)::

    import blender_visionos as vision

    if "realitykit_scene" in vision.capabilities():
        meta = vision.world_mesh.meta()
        if meta.available:
            verts, indices = vision.world_mesh.arrays()
            print(len(verts), "verts", len(indices) // 3, "triangles")
"""

from __future__ import annotations

from dataclasses import dataclass

from . import _native


@dataclass(frozen=True)
class WorldMeshMeta:
    """Snapshot of world mesh availability / size (no vertex data)."""

    ok: bool
    api_version: int
    timestamp: float
    immersive_active: bool
    available: bool
    revision: int
    vertex_count: int
    index_count: int
    truncated: bool


def meta() -> WorldMeshMeta:
    """Poll world mesh metadata without copying vertex/index buffers."""
    ok, raw = _native.world_mesh_meta_raw()
    return WorldMeshMeta(
        ok=ok,
        api_version=int(raw.api_version),
        timestamp=float(raw.timestamp),
        immersive_active=bool(raw.immersive_active),
        available=bool(raw.available),
        revision=int(raw.revision),
        vertex_count=int(raw.vertex_count),
        index_count=int(raw.index_count),
        truncated=bool(raw.truncated),
    )


def arrays(
    max_verts: int = _native.WORLD_MESH_MAX_VERTS,
    max_indices: int = _native.WORLD_MESH_MAX_INDICES,
) -> tuple[list[tuple[float, float, float]], list[int]]:
    """Copy the latest world mesh.

    :return: ``(verts, indices)`` where ``verts`` is a list of ``(x, y, z)``
        tuples (Blender world space, meters) and ``indices`` is a flat
        triangle-index list (``len(indices) % 3 == 0``).
    """
    ok, flat_xyz, indices = _native.world_mesh_copy_raw(max_verts, max_indices)
    if not ok:
        return [], []
    verts = [tuple(flat_xyz[i : i + 3]) for i in range(0, len(flat_xyz), 3)]
    return verts, list(indices)


def is_supported() -> bool:
    """Convenience: ``"realitykit_scene" in vision.capabilities()``."""
    return "realitykit_scene" in __import__("blender_visionos").capabilities()


def to_mesh_object(name: str = "VisionOSWorldMesh"):
    """Build (or update) a Blender mesh object from the latest world mesh.

    Creates the object in the current scene's collection if it does not
    already exist. Returns the object, or ``None`` if no mesh is available.
    """
    import bpy

    verts, indices = arrays()
    if not verts or not indices:
        return None

    faces = [tuple(indices[i : i + 3]) for i in range(0, len(indices) - 2, 3)]

    mesh = bpy.data.meshes.get(name)
    if mesh is None:
        mesh = bpy.data.meshes.new(name)
    else:
        mesh.clear_geometry()
    mesh.from_pydata(verts, [], faces)
    mesh.update()

    obj = bpy.data.objects.get(name)
    if obj is None:
        obj = bpy.data.objects.new(name, mesh)
        bpy.context.scene.collection.objects.link(obj)
    else:
        obj.data = mesh

    return obj
