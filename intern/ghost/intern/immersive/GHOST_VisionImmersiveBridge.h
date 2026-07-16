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

#ifdef __cplusplus
}
#endif
