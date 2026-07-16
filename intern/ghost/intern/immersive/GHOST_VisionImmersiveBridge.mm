/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * C API wrappers around the Swift BlenderImmersiveBridge (Vision Pro / visionOS).
 */

#include "GHOST_VisionImmersiveBridge.h"

#include <TargetConditionals.h>

#if defined(WITH_VISIONOS_IMMERSIVE_SPACE) && TARGET_OS_VISION

#  import <Foundation/Foundation.h>

@interface BlenderImmersiveBridge : NSObject
+ (void)setModelPath:(NSString *)path;
+ (BOOL)openImmersiveSpace;
+ (BOOL)dismissImmersiveSpace;
+ (BOOL)isActive;
@end

bool GHOST_Vision_immersive_space_is_supported(void)
{
  return true;
}

void GHOST_Vision_set_immersive_model_path(const char *usdz_path)
{
  @autoreleasepool {
    NSString *path = (usdz_path != nullptr) ? [NSString stringWithUTF8String:usdz_path] : nil;
    [BlenderImmersiveBridge setModelPath:path];
  }
}

bool GHOST_Vision_open_immersive_space(void)
{
  __block bool ok = false;
  @autoreleasepool {
    ok = [BlenderImmersiveBridge openImmersiveSpace] ? true : false;
  }
  return ok;
}

bool GHOST_Vision_dismiss_immersive_space(void)
{
  __block bool ok = false;
  @autoreleasepool {
    ok = [BlenderImmersiveBridge dismissImmersiveSpace] ? true : false;
  }
  return ok;
}

bool GHOST_Vision_immersive_space_is_active(void)
{
  __block bool active = false;
  @autoreleasepool {
    active = [BlenderImmersiveBridge isActive] ? true : false;
  }
  return active;
}

#else

bool GHOST_Vision_immersive_space_is_supported(void)
{
  return false;
}

void GHOST_Vision_set_immersive_model_path(const char * /*usdz_path*/) {}

bool GHOST_Vision_open_immersive_space(void)
{
  return false;
}

bool GHOST_Vision_dismiss_immersive_space(void)
{
  return false;
}

bool GHOST_Vision_immersive_space_is_active(void)
{
  return false;
}

#endif
