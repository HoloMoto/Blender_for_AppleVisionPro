/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * ObjC / C entry points into the Swift Immersive Space bridge (Vision Pro only).
 */

#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/** True only on visionOS builds with Immersive Space support compiled in. */
bool GHOST_Vision_immersive_space_is_supported(void);

/** Set the USDZ path that the Immersive Space RealityView should load. */
void GHOST_Vision_set_immersive_model_path(const char *usdz_path);

/** Request opening the Immersive Space. Returns false if unavailable. */
bool GHOST_Vision_open_immersive_space(void);

/** Request dismissing the Immersive Space. */
bool GHOST_Vision_dismiss_immersive_space(void);

/** True while the Vision Pro Immersive Space is open (or open was requested). */
bool GHOST_Vision_immersive_space_is_active(void);

/** Push the current active Blender object's location to RealityKit. */
void GHOST_Vision_update_active_object(const char *object_name,
                                       float blender_x,
                                       float blender_y,
                                       float blender_z);

/**
 * Lightweight multi-object transform sync (no USD).
 * \param names_blob: \a count concatenated C-strings (each NUL-terminated).
 * \param names_blob_len: total byte length of \a names_blob (including NULs).
 * \param xyz: \a count * 3 floats, Blender world space.
 */
void GHOST_Vision_update_object_transforms(int count,
                                           const char *names_blob,
                                           int names_blob_len,
                                           const float *xyz);

/** Push Immersive hand-menu state for the Swift UI. */
void GHOST_Vision_update_hand_menu(int mode,
                                   float strength,
                                   float radius,
                                   const char *brush_label,
                                   int brush_kind);

/** Pose bone overlay: packed [hx,hy,hz,tx,ty,tz,selected] * count. */
void GHOST_Vision_update_bones(int count, const float *packed);

/**
 * Shader node graph overlay (spatial Shading editor).
 * node_packed: [x, y, kind, selected, in_count, out_count] * node_count
 * link_packed: [from_node, from_out_idx, to_node, to_in_idx] * link_count
 */
void GHOST_Vision_update_shader_graph(const char *material_name,
                                      int node_count,
                                      const float *node_packed,
                                      const char *node_names,
                                      const char *type_names,
                                      int link_count,
                                      const int *link_packed,
                                      int sock_count,
                                      const int *sock_types,
                                      const char *sock_names);

void GHOST_Vision_update_shader_props(const char *node_name,
                                      const char *type_idname,
                                      int prop_count,
                                      const float *prop_packed,
                                      const char *prop_names);

/** Anim timeline / keyframes / pose xform mode for hand menu. */
void GHOST_Vision_update_anim_timeline(int frame,
                                       int frame_start,
                                       int frame_end,
                                       int key_count,
                                       const int *key_frames,
                                       int xform_mode,
                                       int target_mode,
                                       const char *active_bone);

/** Use right-hand pinch instead of Muse stylus. */
void GHOST_Vision_set_use_hand_as_pen(bool enable);
void GHOST_Vision_set_object_extract_active(bool enable);

/** Toggle spatial shader-node overlay visibility. */
void GHOST_Vision_set_shader_space_enabled(bool enable);

/** Multi Vision Pro Immersive share (Multipeer). No-op when inactive. */
bool GHOST_Vision_multiuser_host(const char *display_name);
bool GHOST_Vision_multiuser_join(const char *display_name);
void GHOST_Vision_multiuser_leave(void);
bool GHOST_Vision_multiuser_is_active(void);
bool GHOST_Vision_multiuser_is_host(void);
/** Copies UTF-8 status into \a dst (always NUL-terminated). */
void GHOST_Vision_multiuser_status(char *dst, int dst_size);
void GHOST_Vision_multiuser_broadcast_usd(const char *usdz_path);

#ifdef __cplusplus
}
#endif
