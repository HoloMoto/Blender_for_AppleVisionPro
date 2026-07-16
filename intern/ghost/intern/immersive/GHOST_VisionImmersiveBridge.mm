/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * C API wrappers around the Swift BlenderImmersiveBridge.
 * When WITH_VISIONOS_IMMERSIVE_SPACE is off, stubs keep the iPad path working.
 */

#include "GHOST_VisionImmersiveBridge.h"

#include <cstring>

#if defined(WITH_VISIONOS_IMMERSIVE_SPACE)

#  import <Foundation/Foundation.h>

/* Generated Swift header name follows module product; use runtime selector bridge
 * so we do not depend on a specific -Swift.h name during early scaffolding. */
@interface BlenderImmersiveBridge : NSObject
+ (void)setModelPath:(NSString *)path;
+ (BOOL)openImmersiveSpace;
+ (BOOL)dismissImmersiveSpace;
+ (BOOL)isActive;
@end

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
