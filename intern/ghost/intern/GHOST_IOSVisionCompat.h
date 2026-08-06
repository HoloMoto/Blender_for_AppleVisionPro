/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#pragma once

#import <TargetConditionals.h>
#import <UIKit/UIKit.h>

static inline CGRect ghost_ios_default_bounds(void)
{
#if TARGET_OS_VISION
  /* UIScreen is unavailable on visionOS; SwiftUI WindowGroup owns the scene size.
   * Prefer the live WindowScene / host UIWindow bounds so startup matches the
   * actual volume. Hardcoded 1280×720 left black margins when the scene was larger. */
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
      continue;
    }
    UIWindowScene *window_scene = (UIWindowScene *)scene;
    if (window_scene.activationState != UISceneActivationStateForegroundActive &&
        window_scene.activationState != UISceneActivationStateForegroundInactive)
    {
      continue;
    }
    const CGRect scene_bounds = window_scene.coordinateSpace.bounds;
    if (scene_bounds.size.width > 1.0 && scene_bounds.size.height > 1.0) {
      return scene_bounds;
    }
    for (UIWindow *window in window_scene.windows) {
      if (window.bounds.size.width > 1.0 && window.bounds.size.height > 1.0) {
        return window.bounds;
      }
    }
  }
  return CGRectMake(0, 0, 1280, 720);
#else
  return [UIScreen mainScreen].bounds;
#endif
}

static inline CGFloat ghost_ios_display_scale(UIView *view)
{
#if TARGET_OS_VISION
  if (view != nil) {
    const CGFloat trait_scale = view.traitCollection.displayScale;
    if (trait_scale > 0.0) {
      return trait_scale;
    }
    if (view.contentScaleFactor > 0.0) {
      return view.contentScaleFactor;
    }
  }
  return 2.0;
#else
  (void)view;
  return [UIScreen mainScreen].scale;
#endif
}

static inline NSInteger ghost_ios_maximum_frames_per_second(UIView *view)
{
#if TARGET_OS_VISION
  (void)view;
  return 90;
#else
  (void)view;
  return [UIScreen mainScreen].maximumFramesPerSecond;
#endif
}

static inline UIWindow *ghost_ios_fallback_key_window(void)
{
#if TARGET_OS_VISION
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
      continue;
    }
    UIWindowScene *window_scene = (UIWindowScene *)scene;
    for (UIWindow *window in window_scene.windows) {
      if (window.isKeyWindow) {
        return window;
      }
    }
    if (window_scene.windows.count > 0) {
      return window_scene.windows[0];
    }
  }
  return nil;
#else
  return [UIApplication sharedApplication].keyWindow;
#endif
}
