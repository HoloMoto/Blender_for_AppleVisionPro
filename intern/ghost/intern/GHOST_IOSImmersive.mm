/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Vision Pro Immersive Space entry (immersive-space branch).
 *
 * This path is RealityKit Immersive Space only — no iPad ARSCNView fallback.
 * USDZ from Blender is handed to the Swift Immersive Space via GHOST_Vision_*.
 */

#include "GHOST_SystemIOS.hh"
#include "GHOST_WindowIOS.hh"

#include "GHOST_ISystem.hh"
#include "immersive/GHOST_VisionImmersiveBridge.h"

#import <UIKit/UIKit.h>

#include <TargetConditionals.h>
#include <pthread.h>
#include <string>

static bool g_ios_immersive_active = false;
static std::string g_ios_immersive_model_path;

static void ghost_ios_set_blender_rendering_paused(const bool paused)
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());
  if (system == nullptr || system->current_active_window_ == nullptr) {
    return;
  }
  system->current_active_window_->setRenderingPaused(paused);
}

static bool ghost_ios_immersive_set_enabled_impl(const bool enable, const char *usdz_path)
{
  if (!GHOST_Vision_immersive_space_is_supported()) {
    return false;
  }

  if (enable) {
    if (g_ios_immersive_active || GHOST_Vision_immersive_space_is_active()) {
      return true;
    }

    if (usdz_path != nullptr && usdz_path[0] != '\0') {
      g_ios_immersive_model_path = usdz_path;
    }
    else {
      g_ios_immersive_model_path.clear();
    }

    GHOST_Vision_set_immersive_model_path(
        g_ios_immersive_model_path.empty() ? nullptr : g_ios_immersive_model_path.c_str());

    if (!GHOST_Vision_open_immersive_space()) {
      g_ios_immersive_model_path.clear();
      return false;
    }

    g_ios_immersive_active = true;
    /* Keep the 2D window alive for editing; Immersive Space is a separate scene. */
    return true;
  }

  if (!g_ios_immersive_active && !GHOST_Vision_immersive_space_is_active()) {
    return true;
  }

  if (!GHOST_Vision_dismiss_immersive_space()) {
    return false;
  }

  g_ios_immersive_active = false;
  g_ios_immersive_model_path.clear();
  ghost_ios_set_blender_rendering_paused(false);
  return true;
}

extern "C" bool GHOST_IOS_set_immersive_mode_enabled(const bool enable, const char *usdz_path)
{
  if (pthread_main_np()) {
    return ghost_ios_immersive_set_enabled_impl(enable, usdz_path);
  }

  __block bool result = false;
  dispatch_sync(dispatch_get_main_queue(), ^{
    result = ghost_ios_immersive_set_enabled_impl(enable, usdz_path);
  });
  return result;
}

extern "C" bool GHOST_IOS_immersive_mode_is_active()
{
  return g_ios_immersive_active || GHOST_Vision_immersive_space_is_active();
}

extern "C" bool GHOST_IOS_immersive_space_is_supported()
{
  return GHOST_Vision_immersive_space_is_supported();
}
