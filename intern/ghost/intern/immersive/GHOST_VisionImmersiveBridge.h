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

/** Push Immersive hand-menu state for the Swift UI. */
void GHOST_Vision_update_hand_menu(int mode,
                                   float strength,
                                   float radius,
                                   const char *brush_label,
                                   int brush_kind);

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
