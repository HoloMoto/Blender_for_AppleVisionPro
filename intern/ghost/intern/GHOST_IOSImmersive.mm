/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Mixed-reality scene preview for Apple platforms.
 *
 * RealityKit Entity APIs are Swift-only, so this uses ARKit + SceneKit
 * (ARSCNView) from Objective-C++ to place the current Blender scene (exported
 * as USDZ) into camera-tracked MR space. The GHOST toggle API stays stable for
 * a later Swift RealityKit / ImmersiveSpace path.
 */

#include "GHOST_SystemIOS.hh"
#include "GHOST_WindowIOS.hh"

#include "GHOST_ISystem.hh"
#include "immersive/GHOST_VisionImmersiveBridge.h"

#import <ARKit/ARKit.h>
#import <SceneKit/SceneKit.h>
#import <UIKit/UIKit.h>

#include <TargetConditionals.h>
#include <cmath>
#include <cstring>
#include <pthread.h>
#include <string>

static UIViewController *g_ios_immersive_view_controller = nil;
static bool g_ios_immersive_active = false;
static std::string g_ios_immersive_model_path;

static UIViewController *ghost_ios_presenting_view_controller()
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());
  if (system != nullptr && system->current_active_window_ != nullptr) {
    UIWindow *window = system->current_active_window_->rootWindow;
    if (window != nil && window.rootViewController != nil) {
      return window.rootViewController;
    }
  }

  UIWindowScene *scene = GHOST_IOS_GetActiveWindowScene();
  if (scene != nil) {
    for (UIWindow *window in scene.windows) {
      if (window.rootViewController != nil) {
        return window.rootViewController;
      }
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
  system->current_active_window_->setRenderingPaused(paused);
}

static SCNNode *ghost_ios_load_model_node(NSString *path)
{
  if (path.length == 0) {
    return nil;
  }

  NSURL *url = [NSURL fileURLWithPath:path];
  NSError *error = nil;
  SCNScene *loaded = [SCNScene sceneWithURL:url options:nil error:&error];
  if (loaded == nil) {
    fprintf(stderr,
            "[ios] immersive: failed to load model '%s': %s\n",
            path.UTF8String,
            error.localizedDescription.UTF8String ?: "unknown");
    fflush(stderr);
    return nil;
  }

  SCNNode *wrapper = [loaded.rootNode clone];
  wrapper.name = @"BlenderScenePreview";

  SCNVector3 min_bounds = SCNVector3Zero;
  SCNVector3 max_bounds = SCNVector3Zero;
  [wrapper getBoundingBoxMin:&min_bounds max:&max_bounds];
  {
    const float sx = max_bounds.x - min_bounds.x;
    const float sy = max_bounds.y - min_bounds.y;
    const float sz = max_bounds.z - min_bounds.z;
    const float largest = std::max(sx, std::max(sy, sz));
    /* Fit the preview into about half a meter so typical Blender scenes are readable. */
    constexpr float target_size = 0.5f;
    if (largest > 1.0e-4f) {
      const float scale = target_size / largest;
      wrapper.scale = SCNVector3Make(scale, scale, scale);
    }

    const float cx = 0.5f * (min_bounds.x + max_bounds.x);
    const float cy = min_bounds.y;
    const float cz = 0.5f * (min_bounds.z + max_bounds.z);
    wrapper.pivot = SCNMatrix4MakeTranslation(cx, cy, cz);
  }

  return wrapper;
}

@interface GHOST_IOSImmersiveViewController : UIViewController <ARSCNViewDelegate, ARSessionDelegate>
@property (nonatomic, strong) ARSCNView *arView;
@property (nonatomic, copy) NSString *modelPath;
@property (nonatomic, strong) SCNNode *modelNode;
@property (nonatomic, strong) SCNNode *placementNode;
@property (nonatomic, assign) BOOL modelPlaced;
@property (nonatomic, assign) BOOL usesWorldTracking;
@property (nonatomic, strong) UILabel *hintLabel;
@end

@implementation GHOST_IOSImmersiveViewController

- (void)viewDidLoad
{
  [super viewDidLoad];

  self.view.backgroundColor = [UIColor blackColor];
  self.modelPlaced = NO;
  self.usesWorldTracking = NO;

  self.arView = [[ARSCNView alloc] initWithFrame:self.view.bounds];
  self.arView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.arView.delegate = self;
  self.arView.session.delegate = self;
  self.arView.automaticallyUpdatesLighting = YES;
  self.arView.autoenablesDefaultLighting = YES;
  self.arView.scene = [SCNScene scene];
  [self.view addSubview:self.arView];

  self.placementNode = [SCNNode node];
  [self.arView.scene.rootNode addChildNode:self.placementNode];

  self.modelNode = ghost_ios_load_model_node(self.modelPath);
  if (self.modelNode == nil) {
    /* Fallback placeholder when export failed or path is empty. */
    SCNBox *cube_geom = [SCNBox boxWithWidth:0.2 height:0.2 length:0.2 chamferRadius:0.01];
    cube_geom.firstMaterial.diffuse.contents = [UIColor colorWithRed:0.26
                                                               green:0.52
                                                                blue:0.96
                                                               alpha:1.0];
    self.modelNode = [SCNNode nodeWithGeometry:cube_geom];
  }
  [self.placementNode addChildNode:self.modelNode];

  UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(ghost_ios_handle_tap:)];
  [self.arView addGestureRecognizer:tap];

#if !TARGET_OS_SIMULATOR
  if ([ARWorldTrackingConfiguration isSupported]) {
    ARWorldTrackingConfiguration *config = [[ARWorldTrackingConfiguration alloc] init];
    config.planeDetection = ARPlaneDetectionHorizontal | ARPlaneDetectionVertical;
    if (@available(iOS 12.0, *)) {
      config.environmentTexturing = AREnvironmentTexturingAutomatic;
    }
    [self.arView.session runWithConfiguration:config];
    self.usesWorldTracking = YES;

    if (@available(iOS 13.0, *)) {
      ARCoachingOverlayView *coaching = [[ARCoachingOverlayView alloc] init];
      coaching.session = self.arView.session;
      coaching.goal = ARCoachingGoalHorizontalPlane;
      coaching.activatesAutomatically = YES;
      coaching.translatesAutoresizingMaskIntoConstraints = NO;
      [self.arView addSubview:coaching];
      [NSLayoutConstraint activateConstraints:@[
        [coaching.centerXAnchor constraintEqualToAnchor:self.arView.centerXAnchor],
        [coaching.centerYAnchor constraintEqualToAnchor:self.arView.centerYAnchor],
        [coaching.widthAnchor constraintEqualToAnchor:self.arView.widthAnchor],
        [coaching.heightAnchor constraintEqualToAnchor:self.arView.heightAnchor],
      ]];
    }
  }
#endif

  if (!self.usesWorldTracking) {
    /* Orbit preview when AR world tracking is unavailable (simulator / some devices). */
    self.arView.allowsCameraControl = YES;
    self.placementNode.position = SCNVector3Make(0.0f, -0.1f, -1.2f);
    self.modelPlaced = YES;
  }

  self.hintLabel = [[UILabel alloc] init];
  self.hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
  self.hintLabel.textAlignment = NSTextAlignmentCenter;
  self.hintLabel.textColor = [UIColor whiteColor];
  self.hintLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
  self.hintLabel.layer.cornerRadius = 8.0;
  self.hintLabel.clipsToBounds = YES;
  self.hintLabel.numberOfLines = 2;
  self.hintLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
  self.hintLabel.text = self.usesWorldTracking ?
                            @"  Point at a surface, then tap to place your scene  " :
                            @"  Drag to orbit the scene preview  ";
  [self.view addSubview:self.hintLabel];

  UIButton *exit_button = [UIButton buttonWithType:UIButtonTypeSystem];
  exit_button.translatesAutoresizingMaskIntoConstraints = NO;
  if (@available(iOS 15.0, *)) {
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = @"Back to Blender";
    config.baseBackgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    config.baseForegroundColor = [UIColor whiteColor];
    config.contentInsets = NSDirectionalEdgeInsetsMake(10.0, 16.0, 10.0, 16.0);
    config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    exit_button.configuration = config;
  }
  else {
    [exit_button setTitle:@"Back to Blender" forState:UIControlStateNormal];
    exit_button.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    exit_button.layer.cornerRadius = 10.0;
  }
  [exit_button addTarget:self
                  action:@selector(ghost_ios_exit_immersive_mode)
        forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:exit_button];

  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [exit_button.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16.0],
    [exit_button.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16.0],
    [self.hintLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor
                                                              constant:16.0],
    [self.hintLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor
                                                            constant:-16.0],
    [self.hintLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
    [self.hintLabel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-24.0],
  ]];
}

- (void)ghost_ios_place_model_at_world_transform:(simd_float4x4)transform
{
  self.placementNode.simdTransform = transform;
  self.modelPlaced = YES;
  self.hintLabel.text = @"  Tap another surface to move the scene  ";
}

- (void)ghost_ios_handle_tap:(UITapGestureRecognizer *)recognizer
{
  if (!self.usesWorldTracking || recognizer.state != UIGestureRecognizerStateEnded) {
    return;
  }

  const CGPoint location = [recognizer locationInView:self.arView];
  ARRaycastQuery *query = [self.arView raycastQueryFromPoint:location
                                               allowingTarget:ARRaycastTargetExistingPlaneGeometry
                                                    alignment:ARRaycastTargetAlignmentAny];
  if (query == nil) {
    query = [self.arView raycastQueryFromPoint:location
                                 allowingTarget:ARRaycastTargetEstimatedPlane
                                      alignment:ARRaycastTargetAlignmentHorizontal];
  }
  if (query == nil) {
    return;
  }

  NSArray<ARRaycastResult *> *results = [self.arView.session raycast:query];
  ARRaycastResult *hit = results.firstObject;
  if (hit != nil) {
    [self ghost_ios_place_model_at_world_transform:hit.worldTransform];
  }
}

- (void)renderer:(id<SCNSceneRenderer>)renderer didAddNode:(SCNNode *)node forAnchor:(ARAnchor *)anchor
{
  (void)renderer;
  if (self.modelPlaced || ![anchor isKindOfClass:[ARPlaneAnchor class]]) {
    return;
  }

  /* Auto-place on the first detected horizontal plane so the scene appears quickly. */
  ARPlaneAnchor *plane = (ARPlaneAnchor *)anchor;
  if (plane.alignment != ARPlaneAnchorAlignmentHorizontal) {
    return;
  }

  simd_float4x4 transform = plane.transform;
  transform.columns[3].y += 0.01f;
  [self ghost_ios_place_model_at_world_transform:transform];
  node.opacity = 0.0;
}

- (void)viewWillDisappear:(BOOL)animated
{
  [super viewWillDisappear:animated];
  [self.arView.session pause];
}

- (void)viewDidDisappear:(BOOL)animated
{
  [super viewDidDisappear:animated];
  if (self.isBeingDismissed || self.presentingViewController == nil) {
    g_ios_immersive_view_controller = nil;
    g_ios_immersive_active = false;
    g_ios_immersive_model_path.clear();
    ghost_ios_set_blender_rendering_paused(false);
  }
}

- (void)ghost_ios_exit_immersive_mode
{
  [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static bool ghost_ios_immersive_set_enabled_impl(const bool enable, const char *usdz_path)
{
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

    /* Prefer Vision Pro Immersive Space (RealityKit) when the Swift bridge is available. */
    GHOST_Vision_set_immersive_model_path(
        g_ios_immersive_model_path.empty() ? nullptr : g_ios_immersive_model_path.c_str());
    if (GHOST_Vision_open_immersive_space()) {
      g_ios_immersive_active = true;
      ghost_ios_set_blender_rendering_paused(true);
      return true;
    }

    /* iPad / fallback: camera-tracked ARSCNView preview. */
    UIViewController *presenting_vc = ghost_ios_top_presenting_view_controller();
    if (presenting_vc == nil) {
      return false;
    }

    GHOST_IOSImmersiveViewController *immersive_vc = [[GHOST_IOSImmersiveViewController alloc] init];
    immersive_vc.modelPath = g_ios_immersive_model_path.empty() ?
                                 nil :
                                 [NSString stringWithUTF8String:g_ios_immersive_model_path.c_str()];
    immersive_vc.modalPresentationStyle = UIModalPresentationFullScreen;
    g_ios_immersive_view_controller = immersive_vc;
    g_ios_immersive_active = true;
    ghost_ios_set_blender_rendering_paused(true);

    [presenting_vc presentViewController:immersive_vc animated:YES completion:nil];
    return true;
  }

  if (GHOST_Vision_immersive_space_is_active() || g_ios_immersive_active) {
    if (GHOST_Vision_dismiss_immersive_space()) {
      g_ios_immersive_active = false;
      g_ios_immersive_model_path.clear();
      ghost_ios_set_blender_rendering_paused(false);
      return true;
    }
  }

  if (!g_ios_immersive_active) {
    return true;
  }

  if (g_ios_immersive_view_controller != nil) {
    [g_ios_immersive_view_controller dismissViewControllerAnimated:YES completion:nil];
    return true;
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
