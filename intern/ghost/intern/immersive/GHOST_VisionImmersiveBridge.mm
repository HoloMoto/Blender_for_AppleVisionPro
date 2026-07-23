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
+ (void)updateActiveObject:(NSString *)name x:(float)x y:(float)y z:(float)z;
+ (void)updateHandMenuMode:(int)mode
                  strength:(float)strength
                    radius:(float)radius
                brushLabel:(NSString *)brushLabel
                 brushKind:(int)brushKind;
+ (BOOL)multiuserHost:(NSString *)displayName;
+ (BOOL)multiuserJoin:(NSString *)displayName;
+ (void)multiuserLeave;
+ (BOOL)multiuserIsActive;
+ (BOOL)multiuserIsHost;
+ (NSString *)multiuserStatus;
+ (void)multiuserBroadcastUSD:(NSString *)path;
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

void GHOST_Vision_update_active_object(const char *object_name,
                                       const float blender_x,
                                       const float blender_y,
                                       const float blender_z)
{
  @autoreleasepool {
    NSString *name = (object_name != nullptr) ? [NSString stringWithUTF8String:object_name] : nil;
    [BlenderImmersiveBridge updateActiveObject:name x:blender_x y:blender_y z:blender_z];
  }
}

void GHOST_Vision_update_hand_menu(const int mode,
                                   const float strength,
                                   const float radius,
                                   const char *brush_label,
                                   const int brush_kind)
{
  @autoreleasepool {
    NSString *label = (brush_label != nullptr) ? [NSString stringWithUTF8String:brush_label] :
                                                 @"Draw";
    [BlenderImmersiveBridge updateHandMenuMode:mode
                                      strength:strength
                                        radius:radius
                                    brushLabel:label
                                     brushKind:brush_kind];
  }
}

bool GHOST_Vision_multiuser_host(const char *display_name)
{
  __block bool ok = false;
  @autoreleasepool {
    NSString *name = (display_name != nullptr) ? [NSString stringWithUTF8String:display_name] :
                                                 nil;
    ok = [BlenderImmersiveBridge multiuserHost:name] ? true : false;
  }
  return ok;
}

bool GHOST_Vision_multiuser_join(const char *display_name)
{
  __block bool ok = false;
  @autoreleasepool {
    NSString *name = (display_name != nullptr) ? [NSString stringWithUTF8String:display_name] :
                                                 nil;
    ok = [BlenderImmersiveBridge multiuserJoin:name] ? true : false;
  }
  return ok;
}

void GHOST_Vision_multiuser_leave(void)
{
  @autoreleasepool {
    [BlenderImmersiveBridge multiuserLeave];
  }
}

bool GHOST_Vision_multiuser_is_active(void)
{
  __block bool active = false;
  @autoreleasepool {
    active = [BlenderImmersiveBridge multiuserIsActive] ? true : false;
  }
  return active;
}

bool GHOST_Vision_multiuser_is_host(void)
{
  __block bool host = false;
  @autoreleasepool {
    host = [BlenderImmersiveBridge multiuserIsHost] ? true : false;
  }
  return host;
}

void GHOST_Vision_multiuser_status(char *dst, const int dst_size)
{
  if (dst == nullptr || dst_size <= 0) {
    return;
  }
  dst[0] = '\0';
  @autoreleasepool {
    NSString *status = [BlenderImmersiveBridge multiuserStatus];
    if (status != nil) {
      [status getCString:dst maxLength:(NSUInteger)dst_size encoding:NSUTF8StringEncoding];
    }
  }
}

void GHOST_Vision_multiuser_broadcast_usd(const char *usdz_path)
{
  if (usdz_path == nullptr || usdz_path[0] == '\0') {
    return;
  }
  @autoreleasepool {
    NSString *path = [NSString stringWithUTF8String:usdz_path];
    [BlenderImmersiveBridge multiuserBroadcastUSD:path];
  }
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

void GHOST_Vision_update_active_object(const char * /*object_name*/,
                                       const float /*blender_x*/,
                                       const float /*blender_y*/,
                                       const float /*blender_z*/)
{
}

void GHOST_Vision_update_hand_menu(const int /*mode*/,
                                   const float /*strength*/,
                                   const float /*radius*/,
                                   const char * /*brush_label*/,
                                   const int /*brush_kind*/)
{
}

bool GHOST_Vision_multiuser_host(const char * /*display_name*/)
{
  return false;
}

bool GHOST_Vision_multiuser_join(const char * /*display_name*/)
{
  return false;
}

void GHOST_Vision_multiuser_leave(void) {}

bool GHOST_Vision_multiuser_is_active(void)
{
  return false;
}

bool GHOST_Vision_multiuser_is_host(void)
{
  return false;
}

void GHOST_Vision_multiuser_status(char *dst, const int dst_size)
{
  if (dst != nullptr && dst_size > 0) {
    dst[0] = '\0';
  }
}

void GHOST_Vision_multiuser_broadcast_usd(const char * /*usdz_path*/) {}

#endif
