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
#define BLENDER_VISIONOS_API_VERSION 1

enum {
  BLENDER_VISIONOS_CAP_NONE = 0,
  BLENDER_VISIONOS_CAP_HAND_TRACKING = 1u << 0,
  BLENDER_VISIONOS_CAP_IMMERSIVE_ACTIVE = 1u << 1,
  /* Reserved for RealityKit spawn / scene query / world mesh, etc. */
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

#ifdef __cplusplus
}
#endif
