/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#pragma once

/**
 * Blender on Vision Pro — public C ABI for add-on authors (via Python).
 *
 * This is a *platform* surface, not a single app feature. New capabilities
 * are added behind #BLENDER_VISIONOS_API_VERSION and capability bits;
 * consumers must check #BLENDER_VISIONOS_hand_snapshot.struct_size /
 * #BLENDER_VISIONOS_capabilities before reading newer fields.
 *
 * Coordinate space: Blender world meters, relative to the Immersive world
 * root (same mapping as Muse / HandPen). Z-up.
 */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Bump when adding fields or changing semantics of existing ones. */
#define BLENDER_VISIONOS_API_VERSION 2

enum {
  BLENDER_VISIONOS_CAP_NONE = 0,
  BLENDER_VISIONOS_CAP_HAND_TRACKING = 1u << 0,
  BLENDER_VISIONOS_CAP_IMMERSIVE_ACTIVE = 1u << 1,
  /* RealityKit spawn / scene query / world mesh (scene reconstruction). */
  BLENDER_VISIONOS_CAP_REALITYKIT_SCENE = 1u << 2,
};

typedef struct BLENDER_VISIONOS_Vec3 {
  float x, y, z;
} BLENDER_VISIONOS_Vec3;

typedef struct BLENDER_VISIONOS_HandSide {
  uint32_t tracked; /* 1 if this hand has a recent valid sample. */
  BLENDER_VISIONOS_Vec3 wrist;
  BLENDER_VISIONOS_Vec3 palm;
  BLENDER_VISIONOS_Vec3 thumb_tip;
  BLENDER_VISIONOS_Vec3 index_tip;
  BLENDER_VISIONOS_Vec3 middle_tip;
  BLENDER_VISIONOS_Vec3 ring_tip;
  BLENDER_VISIONOS_Vec3 little_tip;
  float pinch; /* 0..1 approximate (thumb↔index), -1 if unknown. */
  float _pad0;
} BLENDER_VISIONOS_HandSide;

typedef struct BLENDER_VISIONOS_HandSnapshot {
  uint32_t struct_size; /* Always set to sizeof(this) by the publisher. */
  uint32_t api_version; /* BLENDER_VISIONOS_API_VERSION at publish time. */
  double timestamp;     /* Seconds (CFAbsoluteTime / host clock). */
  uint32_t immersive_active;
  uint32_t _pad1;
  BLENDER_VISIONOS_HandSide left;
  BLENDER_VISIONOS_HandSide right;
} BLENDER_VISIONOS_HandSnapshot;

/** Non-zero when running under the Vision Pro / Apple mobile Immersive build. */
int BLENDER_VISIONOS_available(void);

/** Bitfield of #BLENDER_VISIONOS_CAP_* currently offered. */
uint64_t BLENDER_VISIONOS_capabilities(void);

/**
 * Copy the latest hand snapshot into \a out.
 * \return 1 on success (out filled), 0 if unavailable / not tracking yet.
 * Older clients: check out->struct_size before reading newer trailing fields.
 */
int BLENDER_VISIONOS_hand_snapshot(BLENDER_VISIONOS_HandSnapshot *out);

/**
 * Publisher entry (Swift Immersive runtime). Not for add-ons.
 * Pass nullptr-safe; overwrites the shared snapshot atomically.
 */
void BLENDER_VISIONOS_hand_publish(const BLENDER_VISIONOS_HandSnapshot *in);

/** Mark Immersive Space active/inactive for capability bits. */
void BLENDER_VISIONOS_set_immersive_active(int active);

/**
 * Route one line of Python ``print`` / stderr to Info reports (+ device log).
 * Used on Apple Immersive builds where there is no system console window.
 * \param is_err Non-zero for stderr-style (WARNING), else INFO.
 */
void BLENDER_IOS_py_stdout_line(const char *line, int is_err);

/**
 * World mesh (ARKit scene reconstruction).
 *
 * Accumulated from all mesh anchors while the Immersive Space is open, capped
 * to #BLENDER_VISIONOS_WORLD_MESH_MAX_VERTS / #BLENDER_VISIONOS_WORLD_MESH_MAX_INDICES.
 * Coordinates: Blender world space, meters, Z-up (same as hands).
 */
#define BLENDER_VISIONOS_WORLD_MESH_MAX_VERTS 16384u
#define BLENDER_VISIONOS_WORLD_MESH_MAX_INDICES 49152u

typedef struct BLENDER_VISIONOS_WorldMeshMeta {
  uint32_t struct_size;
  uint32_t api_version;
  double timestamp;
  uint32_t immersive_active;
  uint32_t available;
  uint32_t revision;
  uint32_t vertex_count;
  uint32_t index_count;
  uint32_t truncated;
  uint32_t _pad0;
} BLENDER_VISIONOS_WorldMeshMeta;

/**
 * Copy world mesh metadata into \a out.
 * \return 1 if a world mesh is currently available, 0 otherwise (out is still filled).
 */
int BLENDER_VISIONOS_world_mesh_meta(BLENDER_VISIONOS_WorldMeshMeta *out);

/**
 * Copy the latest world mesh vertex / index buffers.
 * \param out_xyz: buffer for \a max_verts * 3 floats (Blender world space), may be nullptr.
 * \param out_indices: buffer for \a max_indices uint32 triangle indices, may be nullptr.
 * \return 1 on success (counts filled even if buffers are nullptr / too small), 0 if unavailable.
 */
int BLENDER_VISIONOS_world_mesh_copy(float *out_xyz,
                                     uint32_t max_verts,
                                     uint32_t *out_vertex_count,
                                     uint32_t *out_indices,
                                     uint32_t max_indices,
                                     uint32_t *out_index_count);

/**
 * Publisher entry (Swift Immersive runtime). Not for add-ons.
 * Overwrites the shared world mesh atomically. Pass \a vertex_count == 0 to clear.
 */
void BLENDER_VISIONOS_world_mesh_publish(uint32_t revision,
                                         const float *xyz,
                                         uint32_t vertex_count,
                                         const uint32_t *indices,
                                         uint32_t index_count,
                                         int truncated);

#ifdef __cplusplus
}
#endif
