/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include "GHOST_SystemIOS.hh"
#include "GHOST_WindowIOS.hh"

#include "GHOST_ISystem.hh"

#import <ARKit/ARKit.h>
#import <RealityKit/RealityKit.h>
#import <UIKit/UIKit.h>

#include <TargetConditionals.h>
#include <pthread.h>

static UIViewController *g_ios_immersive_view_controller = nil;
static bool g_ios_immersive_active = false;

static UIViewController *ghost_ios_presenting_view_controller()
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());
  if (system != nullptr && system->current_active_window_ != nullptr) {
    UIWindow *window = system->current_active_window_->rootWindow;
    if (window != nil && window.rootViewController != nil) {
      return window.rootViewController;
    }
  }

  UIWindow *key_window = [UIApplication sharedApplication].keyWindow;
  if (key_window != nil && key_window.rootViewController != nil) {
    return key_window.rootViewController;
  }

  for (UIWindow *window in [UIApplication sharedApplication].windows) {
    if (window.rootViewController != nil) {
      return window.rootViewController;
    }
  }
  return nil;
}

static UIViewController *ghost_ios_top_presenting_view_controller()
{
  UIViewController *vc = ghost_ios_presenting_view_controller();
  while (vc != nil && vc.presentedViewController != nil) {
    vc = vc.presentedViewController;
  }
  return vc;
}

static void ghost_ios_set_blender_rendering_paused(const bool paused)
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());
  if (system == nullptr || system->current_active_window_ == nullptr) {
    return;
  }
  system->current_active_window_->metal_view_.paused = paused ? YES : NO;
}

static void ghost_ios_immersive_populate_scene(ARView *ar_view)
{
  if (ar_view == nil) {
    return;
  }

  MeshResource *cube_mesh = [MeshResource generateBoxWithSize:0.2 modifier:MeshModifierNone];
  SimpleMaterial *cube_material = [[SimpleMaterial alloc] initWithColor:[UIColor colorWithRed:0.26
                                                                                        green:0.52
                                                                                         blue:0.96
                                                                                        alpha:1.0]
                                                               isMetallic:YES];
  ModelEntity *cube = [ModelEntity modelWithMesh:cube_mesh materials:@[ cube_material ]];
  cube.position = simd_make_float3(0.0f, 0.12f, -0.75f);

  MeshResource *plane_mesh = [MeshResource generatePlaneWithWidth:2.0f depth:2.0f];
  SimpleMaterial *plane_material = [[SimpleMaterial alloc] initWithColor:[UIColor colorWithWhite:0.15
                                                                                           alpha:1.0]
                                                              isMetallic:NO];
  ModelEntity *plane = [ModelEntity modelWithMesh:plane_mesh materials:@[ plane_material ]];
  plane.position = simd_make_float3(0.0f, 0.0f, -0.75f);

  AnchorEntity *anchor = [[AnchorEntity alloc] init];
  [anchor addChild:plane];
  [anchor addChild:cube];
  [ar_view.scene addAnchor:anchor];
}

@interface GHOST_IOSImmersiveViewController : UIViewController
@property (nonatomic, strong) ARView *arView;
@end

@implementation GHOST_IOSImmersiveViewController

- (void)viewDidLoad
{
  [super viewDidLoad];

  self.view.backgroundColor = [UIColor blackColor];
  self.arView = [[ARView alloc] initWithFrame:self.view.bounds];
  self.arView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:self.arView];

#if TARGET_OS_VISION
  if (@available(visionOS 1.0, *)) {
    self.arView.environment.background = ARViewEnvironmentBackgroundStyleColor;
  }
#else
  if ([ARWorldTrackingConfiguration isSupported]) {
    ARWorldTrackingConfiguration *config = [[ARWorldTrackingConfiguration alloc] init];
    config.planeDetection = ARPlaneDetectionHorizontal;
    [self.arView.session runWithConfiguration:config];
  }
#endif

  ghost_ios_immersive_populate_scene(self.arView);

  UIButton *exit_button = [UIButton buttonWithType:UIButtonTypeSystem];
  exit_button.translatesAutoresizingMaskIntoConstraints = NO;
  [exit_button setTitle:@"Exit Immersive Mode" forState:UIControlStateNormal];
  exit_button.titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
  exit_button.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
  exit_button.layer.cornerRadius = 10.0;
  exit_button.contentEdgeInsets = UIEdgeInsetsMake(10.0, 16.0, 10.0, 16.0);
  [exit_button addTarget:self
                  action:@selector(ghost_ios_exit_immersive_mode)
        forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:exit_button];

  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [exit_button.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16.0],
    [exit_button.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16.0],
  ]];
}

- (void)viewDidDisappear:(BOOL)animated
{
  [super viewDidDisappear:animated];
  if (self.isBeingDismissed || self.presentingViewController == nil) {
    g_ios_immersive_view_controller = nil;
    g_ios_immersive_active = false;
    ghost_ios_set_blender_rendering_paused(false);
  }
}

- (void)ghost_ios_exit_immersive_mode
{
  [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static bool ghost_ios_immersive_set_enabled_impl(const bool enable)
{
  if (enable) {
    if (g_ios_immersive_active) {
      return true;
    }

    UIViewController *presenting_vc = ghost_ios_top_presenting_view_controller();
    if (presenting_vc == nil) {
      return false;
    }

    GHOST_IOSImmersiveViewController *immersive_vc = [[GHOST_IOSImmersiveViewController alloc] init];
    immersive_vc.modalPresentationStyle = UIModalPresentationFullScreen;
    g_ios_immersive_view_controller = immersive_vc;
    g_ios_immersive_active = true;
    ghost_ios_set_blender_rendering_paused(true);

    [presenting_vc presentViewController:immersive_vc animated:YES completion:nil];
    return true;
  }

  if (!g_ios_immersive_active) {
    return true;
  }

  if (g_ios_immersive_view_controller != nil) {
    [g_ios_immersive_view_controller dismissViewControllerAnimated:YES completion:nil];
    return true;
  }

  g_ios_immersive_active = false;
  ghost_ios_set_blender_rendering_paused(false);
  return true;
}

bool GHOST_IOS_set_immersive_mode_enabled(const bool enable)
{
  if (pthread_main_np()) {
    return ghost_ios_immersive_set_enabled_impl(enable);
  }

  __block bool result = false;
  dispatch_sync(dispatch_get_main_queue(), ^{
    result = ghost_ios_immersive_set_enabled_impl(enable);
  });
  return result;
}

bool GHOST_IOS_immersive_mode_is_active()
{
  return g_ios_immersive_active;
}
