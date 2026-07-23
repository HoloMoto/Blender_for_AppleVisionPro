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
#include <algorithm>
#include <pthread.h>
#include <string>

extern "C" void GHOST_IOS_immersive_muse_tick_set_enabled(bool enable);

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
      /* Re-entry (already open): still ensure Muse tick / 2D window stay alive. */
      ghost_ios_set_blender_rendering_paused(false);
      GHOST_IOS_immersive_muse_tick_set_enabled(true);
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
    ghost_ios_set_blender_rendering_paused(false);
    GHOST_IOS_immersive_muse_tick_set_enabled(true);
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
  GHOST_IOS_immersive_muse_tick_set_enabled(false);
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

extern "C" void GHOST_IOS_immersive_reload_model(const char *usdz_path)
{
  if (usdz_path == nullptr || usdz_path[0] == '\0' ||
      !GHOST_Vision_immersive_space_is_active())
  {
    return;
  }
  GHOST_Vision_set_immersive_model_path(usdz_path);
}

extern "C" void GHOST_IOS_immersive_update_active_object(const char *object_name,
                                                          const float blender_x,
                                                          const float blender_y,
                                                          const float blender_z)
{
  if (!GHOST_Vision_immersive_space_is_active()) {
    return;
  }
  GHOST_Vision_update_active_object(object_name, blender_x, blender_y, blender_z);
}

extern "C" void GHOST_IOS_immersive_update_hand_menu(const int mode,
                                                       const float strength,
                                                       const float radius,
                                                       const char *brush_label,
                                                       const int brush_kind)
{
  if (!GHOST_Vision_immersive_space_is_active()) {
    return;
  }
  GHOST_Vision_update_hand_menu(mode, strength, radius, brush_label, brush_kind);
}

static GHOST_TabletData ghost_ios_tablet_from_pressure(const float pressure)
{
  GHOST_TabletData tablet = GHOST_TABLET_DATA_NONE;
  tablet.Active = GHOST_kTabletModeStylus;
  tablet.Pressure = std::clamp(pressure, 0.0f, 1.0f);
  tablet.Xtilt = 0.0f;
  tablet.Ytilt = 0.0f;
  return tablet;
}

extern "C" void GHOST_IOS_push_tablet_cursor(const int x, const int y, const float pressure)
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());
  if (system == nullptr || system->current_active_window_ == nullptr) {
    return;
  }
  system->pushHardwareCursorMove(
      system->current_active_window_, x, y, ghost_ios_tablet_from_pressure(pressure));
}

extern "C" void GHOST_IOS_push_tablet_button(const bool is_down, const float pressure)
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());
  if (system == nullptr || system->current_active_window_ == nullptr) {
    return;
  }
  system->pushHardwareButtonEvent(system->current_active_window_,
                                  is_down ? GHOST_kEventButtonDown : GHOST_kEventButtonUp,
                                  GHOST_kButtonMaskLeft,
                                  ghost_ios_tablet_from_pressure(pressure));
}

extern "C" bool GHOST_IOS_multiuser_host(const char *display_name)
{
  return GHOST_Vision_multiuser_host(display_name);
}

extern "C" bool GHOST_IOS_multiuser_join(const char *display_name)
{
  return GHOST_Vision_multiuser_join(display_name);
}

extern "C" void GHOST_IOS_multiuser_leave(void)
{
  GHOST_Vision_multiuser_leave();
}

extern "C" bool GHOST_IOS_multiuser_is_active(void)
{
  return GHOST_Vision_multiuser_is_active();
}

extern "C" bool GHOST_IOS_multiuser_is_host(void)
{
  return GHOST_Vision_multiuser_is_host();
}

extern "C" void GHOST_IOS_multiuser_status(char *dst, const int dst_size)
{
  GHOST_Vision_multiuser_status(dst, dst_size);
}

extern "C" void GHOST_IOS_multiuser_broadcast_usd(const char *usdz_path)
{
  /* Safe when inactive / guest: Swift no-ops. */
  GHOST_Vision_multiuser_broadcast_usd(usdz_path);
}
