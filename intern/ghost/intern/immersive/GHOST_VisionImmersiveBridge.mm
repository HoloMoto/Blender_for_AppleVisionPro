/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * C API wrappers around the Swift BlenderImmersiveBridge (Vision Pro / visionOS).
 */

#include "GHOST_VisionImmersiveBridge.h"

#include <TargetConditionals.h>
#include <cstring>

#if defined(WITH_VISIONOS_IMMERSIVE_SPACE) && TARGET_OS_VISION

#  import <Foundation/Foundation.h>

@interface BlenderImmersiveBridge : NSObject
+ (void)setModelPath:(NSString *)path;
+ (BOOL)openImmersiveSpace;
+ (BOOL)dismissImmersiveSpace;
+ (BOOL)isActive;
+ (void)updateActiveObject:(NSString *)name x:(float)x y:(float)y z:(float)z;
+ (void)updateObjectTransformsNames:(NSArray<NSString *> *)names
                               count:(int)count
                                 xyz:(NSArray<NSNumber *> *)xyz;
+ (void)updateHandMenuMode:(int)mode
                  strength:(float)strength
                    radius:(float)radius
                brushLabel:(NSString *)brushLabel
                 brushKind:(int)brushKind;
+ (void)updateBones:(NSArray<NSNumber *> *)packed count:(int)count;
+ (void)updateShaderGraphMaterial:(NSString *)materialName
                       nodePacked:(NSArray<NSNumber *> *)nodePacked
                        nodeCount:(int)nodeCount
                        nodeNames:(NSString *)nodeNames
                        typeNames:(NSString *)typeNames
                       linkPacked:(NSArray<NSNumber *> *)linkPacked
                        linkCount:(int)linkCount
                        sockTypes:(NSArray<NSNumber *> *)sockTypes
                        sockCount:(int)sockCount
                        sockNames:(NSString *)sockNames;
+ (void)updateShaderProps:(NSString *)nodeName
               typeIdname:(NSString *)typeIdname
                propCount:(int)propCount
               propPacked:(NSArray<NSNumber *> *)propPacked
                propNames:(NSString *)propNames;
+ (void)updateAnimTimelineFrame:(int)frame
                     frameStart:(int)frameStart
                       frameEnd:(int)frameEnd
                      keyFrames:(NSArray<NSNumber *> *)keyFrames
                      xformMode:(int)xformMode
                    targetMode:(int)targetMode
                     activeBone:(NSString *)activeBone;
+ (void)setUseHandAsPen:(BOOL)enable;
+ (void)setShaderSpaceEnabled:(BOOL)enable;
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

void GHOST_Vision_update_object_transforms(const int count,
                                           const char *names_blob,
                                           const int names_blob_len,
                                           const float *xyz)
{
  @autoreleasepool {
    const int n = MAX(0, count);
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:n];
    if (names_blob != nullptr && names_blob_len > 0 && n > 0) {
      int offset = 0;
      for (int i = 0; i < n && offset < names_blob_len; i++) {
        const char *start = names_blob + offset;
        const size_t max_len = size_t(names_blob_len - offset);
        const size_t len = strnlen(start, max_len);
        NSString *name = [[NSString alloc] initWithBytes:start
                                                    length:len
                                                  encoding:NSUTF8StringEncoding];
        [names addObject:name ?: @""];
        offset += int(len) + 1;
      }
    }
    NSMutableArray<NSNumber *> *xyzArr = [NSMutableArray arrayWithCapacity:n * 3];
    if (xyz != nullptr && n > 0) {
      for (int i = 0; i < n * 3; i++) {
        [xyzArr addObject:@(xyz[i])];
      }
    }
    [BlenderImmersiveBridge updateObjectTransformsNames:names count:n xyz:xyzArr];
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

void GHOST_Vision_update_bones(const int count, const float *packed)
{
  @autoreleasepool {
    NSMutableArray<NSNumber *> *arr = [NSMutableArray arrayWithCapacity:MAX(0, count) * 7];
    if (packed != nullptr && count > 0) {
      for (int i = 0; i < count * 7; i++) {
        [arr addObject:@(packed[i])];
      }
    }
    [BlenderImmersiveBridge updateBones:arr count:count];
  }
}

void GHOST_Vision_update_shader_graph(const char *material_name,
                                      const int node_count,
                                      const float *node_packed,
                                      const char *node_names,
                                      const char *type_names,
                                      const int link_count,
                                      const int *link_packed,
                                      const int sock_count,
                                      const int *sock_types,
                                      const char *sock_names)
{
  @autoreleasepool {
    NSString *mat = (material_name != nullptr) ? [NSString stringWithUTF8String:material_name] :
                                                 @"";
    NSString *names = (node_names != nullptr) ? [NSString stringWithUTF8String:node_names] : @"";
    NSString *types = (type_names != nullptr) ? [NSString stringWithUTF8String:type_names] : @"";
    NSString *socks = (sock_names != nullptr) ? [NSString stringWithUTF8String:sock_names] : @"";
    NSMutableArray<NSNumber *> *nodes = [NSMutableArray arrayWithCapacity:MAX(0, node_count) * 6];
    if (node_packed != nullptr && node_count > 0) {
      for (int i = 0; i < node_count * 6; i++) {
        [nodes addObject:@(node_packed[i])];
      }
    }
    NSMutableArray<NSNumber *> *links =
        [NSMutableArray arrayWithCapacity:MAX(0, link_count) * 4];
    if (link_packed != nullptr && link_count > 0) {
      for (int i = 0; i < link_count * 4; i++) {
        [links addObject:@(link_packed[i])];
      }
    }
    NSMutableArray<NSNumber *> *stypes = [NSMutableArray arrayWithCapacity:MAX(0, sock_count)];
    if (sock_types != nullptr && sock_count > 0) {
      for (int i = 0; i < sock_count; i++) {
        [stypes addObject:@(sock_types[i])];
      }
    }
    [BlenderImmersiveBridge updateShaderGraphMaterial:mat
                                           nodePacked:nodes
                                            nodeCount:node_count
                                            nodeNames:names
                                            typeNames:types
                                           linkPacked:links
                                            linkCount:link_count
                                            sockTypes:stypes
                                            sockCount:sock_count
                                            sockNames:socks];
  }
}

void GHOST_Vision_update_shader_props(const char *node_name,
                                      const char *type_idname,
                                      const int prop_count,
                                      const float *prop_packed,
                                      const char *prop_names)
{
  @autoreleasepool {
    NSString *name = (node_name != nullptr) ? [NSString stringWithUTF8String:node_name] : @"";
    NSString *tid = (type_idname != nullptr) ? [NSString stringWithUTF8String:type_idname] : @"";
    NSString *pnames = (prop_names != nullptr) ? [NSString stringWithUTF8String:prop_names] : @"";
    NSMutableArray<NSNumber *> *props =
        [NSMutableArray arrayWithCapacity:MAX(0, prop_count) * 8];
    if (prop_packed != nullptr && prop_count > 0) {
      for (int i = 0; i < prop_count * 8; i++) {
        [props addObject:@(prop_packed[i])];
      }
    }
    [BlenderImmersiveBridge updateShaderProps:name
                                   typeIdname:tid
                                    propCount:prop_count
                                   propPacked:props
                                    propNames:pnames];
  }
}

void GHOST_Vision_update_anim_timeline(const int frame,
                                       const int frame_start,
                                       const int frame_end,
                                       const int key_count,
                                       const int *key_frames,
                                       const int xform_mode,
                                       const int target_mode,
                                       const char *active_bone)
{
  @autoreleasepool {
    NSMutableArray<NSNumber *> *keys = [NSMutableArray arrayWithCapacity:MAX(0, key_count)];
    if (key_frames != nullptr && key_count > 0) {
      for (int i = 0; i < key_count; i++) {
        [keys addObject:@(key_frames[i])];
      }
    }
    NSString *bone = (active_bone != nullptr) ? [NSString stringWithUTF8String:active_bone] : @"";
    [BlenderImmersiveBridge updateAnimTimelineFrame:frame
                                         frameStart:frame_start
                                           frameEnd:frame_end
                                          keyFrames:keys
                                          xformMode:xform_mode
                                         targetMode:target_mode
                                         activeBone:bone];
  }
}

void GHOST_Vision_set_use_hand_as_pen(const bool enable)
{
  @autoreleasepool {
    [BlenderImmersiveBridge setUseHandAsPen:enable ? YES : NO];
  }
}

void GHOST_Vision_set_object_extract_active(const bool enable)
{
  @autoreleasepool {
    [BlenderImmersiveBridge setObjectExtractActive:enable ? YES : NO];
  }
}

void GHOST_Vision_set_shader_space_enabled(const bool enable)
{
  @autoreleasepool {
    [BlenderImmersiveBridge setShaderSpaceEnabled:enable ? YES : NO];
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

void GHOST_Vision_update_object_transforms(const int /*count*/,
                                           const char * /*names_blob*/,
                                           const int /*names_blob_len*/,
                                           const float * /*xyz*/)
{
}

void GHOST_Vision_update_hand_menu(const int /*mode*/,
                                   const float /*strength*/,
                                   const float /*radius*/,
                                   const char * /*brush_label*/,
                                   const int /*brush_kind*/)
{
}

void GHOST_Vision_update_bones(const int /*count*/, const float * /*packed*/) {}

void GHOST_Vision_update_shader_graph(const char * /*material_name*/,
                                      const int /*node_count*/,
                                      const float * /*node_packed*/,
                                      const char * /*node_names*/,
                                      const char * /*type_names*/,
                                      const int /*link_count*/,
                                      const int * /*link_packed*/,
                                      const int /*sock_count*/,
                                      const int * /*sock_types*/,
                                      const char * /*sock_names*/)
{
}

void GHOST_Vision_update_shader_props(const char * /*node_name*/,
                                      const char * /*type_idname*/,
                                      const int /*prop_count*/,
                                      const float * /*prop_packed*/,
                                      const char * /*prop_names*/)
{
}

void GHOST_Vision_update_anim_timeline(const int /*frame*/,
                                       const int /*frame_start*/,
                                       const int /*frame_end*/,
                                       const int /*key_count*/,
                                       const int * /*key_frames*/,
                                       const int /*xform_mode*/,
                                       const int /*target_mode*/,
                                       const char * /*active_bone*/)
{
}

void GHOST_Vision_set_use_hand_as_pen(const bool /*enable*/) {}
void GHOST_Vision_set_object_extract_active(const bool /*enable*/) {}

void GHOST_Vision_set_shader_space_enabled(const bool /*enable*/) {}

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
