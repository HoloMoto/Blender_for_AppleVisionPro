/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include "GHOST_WindowIOS.hh"

#include "GHOST_ContextIOS.hh"
#include "GHOST_SystemIOS.hh"

#include "GHOST_C-api.h"
#include "GHOST_Debug.hh"
#include "GHOST_EventButton.hh"
#include "GHOST_EventCursor.hh"
#include "GHOST_EventDragnDrop.hh"
#include "GHOST_EventKey.hh"
#include "GHOST_EventTouch.hh"
#include "GHOST_EventTrackpad.hh"

#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIPencilInteraction.h>

// #define IOS_INPUT_LOGGING
#if defined(IOS_INPUT_LOGGING)
#  define IOS_INPUT_LOG(...) NSLog(__VA_ARGS__)
#else
#  define IOS_INPUT_LOG(...)
#endif

/* Enable window/input diagnostics on iOS cross-platform builds. */
#if defined(WITH_APPLE_CROSSPLATFORM)
#  define IOS_WINDOW_LOGGING
#endif
#if defined(IOS_WINDOW_LOGGING)
#  define IOS_WINDOW_LOG(...) NSLog(__VA_ARGS__)
#else
#  define IOS_WINDOW_LOG(...)
#endif

typedef struct UserInputEvent {
  enum EventTypes {
    CURSOR_MOVE,
    PAN_GESTURE,
    PAN_GESTURE_TWO_FINGERS,
    PINCH_GESTURE,
    LEFT_BUTTON_DOWN,
    LEFT_BUTTON_UP,
    PENCIL_TAP,
  };
  EventTypes event_list[10];
  int num_events;
  CGPoint location;
  CGPoint translation;
  CGFloat distance;
  bool pencil_used;

  UserInputEvent(CGPoint *loc, CGPoint *tran, CGFloat *dist, bool pencil)
  {
    num_events = 0;
    location = loc ? *loc : CGPointMake(-1.0f, -1.0f);
    translation = tran ? *tran : CGPointMake(0.0f, 0.0f);
    distance = dist ? *dist : 0.0f;
    pencil_used = pencil;
  }

  void add_event(EventTypes event_type)
  {
    GHOST_ASSERT(num_events <= sizeof(event_list) / sizeof(*event_list),
                 "add_event: Failed to add event");
    event_list[num_events] = event_type;
    num_events++;
  }

  NSString *getEventTypeDesc(EventTypes event_type) const
  {
    switch (event_type) {
      case CURSOR_MOVE:
        return @"CM";
      case PAN_GESTURE:
        return @"PAN";
      case PAN_GESTURE_TWO_FINGERS:
        return @"PAN2F";
      case PINCH_GESTURE:
        return @"PINCH";
      case LEFT_BUTTON_DOWN:
        return @"LB-DOWN";
      case LEFT_BUTTON_UP:
        return @"LB-UP";
      case PENCIL_TAP:
        return @"PENCIL-TAP";
    }
    BLI_assert_unreachable();
    return @"Event undefined";
  }

} UserInputEvent;

/* GHOSTUITapGesture interface for capturing taps. */
@interface GHOSTUITapGestureRecognizer : UITapGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;

@end

@implementation GHOSTUITapGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point = [self locationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

@end

/* GHOSTUITapGesture interface for capturing taps. */
@interface GHOSTUIPanGestureRecognizer : UIPanGestureRecognizer
{
  CGPoint cached_translation;
}
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;
- (CGPoint)getScaledTranslation:(GHOST_WindowIOS *)window;

- (void)setCachedTranslation:(CGPoint)translation;
- (CGPoint)getCachedTranslation;
@end

@implementation GHOSTUIPanGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point = [self locationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

- (CGPoint)getScaledTranslation:(GHOST_WindowIOS *)window
{
  CGPoint translation = [self translationInView:window->getView()];
  return window->scalePointToWindow(translation);
}

- (CGPoint)getRelativeTranslation:(CGPoint)translation
{
  CGPoint relative_translation;
  relative_translation.x = translation.x - cached_translation.x;
  relative_translation.y = translation.y - cached_translation.y;
  return relative_translation;
}

- (void)setCachedTranslation:(CGPoint)translation
{
  cached_translation = translation;
}

- (CGPoint)getCachedTranslation
{
  return cached_translation;
}
@end

@interface GHOSTUIHoverGestureRecognizer : UIHoverGestureRecognizer
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window;
@end

@implementation GHOSTUIHoverGestureRecognizer

- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point = [self locationInView:window->getView()];
  return window->scalePointToWindow(touch_point);
}
@end

@interface GHOSTUIPinchGestureRecognizer : UIPinchGestureRecognizer
{
  CGFloat cached_distance;
}
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window touch_id:(int)touch_id;
- (CGFloat)getScaledDistance:(GHOST_WindowIOS *)window;
- (CGPoint)getPinchMidpoint:(GHOST_WindowIOS *)window;
- (void)setCachedDistance:(CGFloat)distance;
- (CGFloat)getCachedDistance;
@end

@implementation GHOSTUIPinchGestureRecognizer
- (CGPoint)getScaledTouchPoint:(GHOST_WindowIOS *)window touch_id:(int)touch_id
{
  CGPoint touch_point = [self locationOfTouch:touch_id inView:window->getView()];
  return window->scalePointToWindow(touch_point);
}

- (CGFloat)getScaledDistance:(GHOST_WindowIOS *)window
{
  CGPoint touch_point0 = [self locationOfTouch:0 inView:window->getView()];
  CGPoint touch_point1 = [self locationOfTouch:1 inView:window->getView()];
  touch_point0 = window->scalePointToWindow(touch_point0);
  touch_point1 = window->scalePointToWindow(touch_point1);
  float dx = touch_point1.x - touch_point0.x;
  float dy = touch_point1.y - touch_point0.y;
  CGFloat point_distance = sqrt(dx * dx + dy * dy);
  return point_distance;
}

- (CGPoint)getPinchMidpoint:(GHOST_WindowIOS *)window
{
  CGPoint touch_point0 = [self locationOfTouch:0 inView:window->getView()];
  CGPoint touch_point1 = [self locationOfTouch:1 inView:window->getView()];
  touch_point0 = window->scalePointToWindow(touch_point0);
  touch_point1 = window->scalePointToWindow(touch_point1);
  CGPoint midPoint = CGPointMake((touch_point0.x + touch_point1.x) / 2.0f,
                                 (touch_point0.y + touch_point1.y) / 2.0f);
  return midPoint;
}

- (void)setCachedDistance:(CGFloat)distance
{
  cached_distance = distance;
}

- (CGFloat)getCachedDistance
{
  return cached_distance;
}
@end

/* GHOSTUIWindow interface. */
@interface GHOSTUIWindow : UIWindow <UIGestureRecognizerDelegate, UIPencilInteractionDelegate>
{
  GHOST_SystemIOS *system;
  GHOST_WindowIOS *window;

  GHOSTUITapGestureRecognizer *tap_gesture_recognizer;
  GHOSTUITapGestureRecognizer *tap2f_gesture_recognizer;
  GHOSTUITapGestureRecognizer *tap3f_gesture_recognizer;
  GHOSTUITapGestureRecognizer *tap4f_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *pan_gesture_recognizer;
  GHOSTUIPanGestureRecognizer *pan2f_gesture_recognizer;
  GHOSTUIPinchGestureRecognizer *zoom_gesture_recognizer;
  GHOSTUIHoverGestureRecognizer *hover_gesture_recognizer;
  GHOSTUIHoverGestureRecognizer *pointer_hover_gesture_recognizer;
  UIPencilInteraction *pencil_interaction;
  UIScreenEdgePanGestureRecognizer *edge_swipe_left;
  UIScreenEdgePanGestureRecognizer *edge_swipe_right;
  // GHOSTUILongPressGestureRecognizer *long_press_gesture_recognizer;

  /* Data from the Apple pencil */
  UITouch *current_pencil_touch;
  bool pencil_stroke_active;
  GHOST_TabletData tablet_data;
  bool last_tap_with_pencil;
  CFTimeInterval last_pencil_emit_time;
  CGPoint last_pencil_emit_point;
  bool has_last_pencil_emit_point;

  /* Keyboard handling. */
  UITextField *text_field;
  NSString *original_text;
  bool onscreen_keyboard_active;
  const char *text_field_string;
  GHOST_KeyboardProperties current_keyboard_properties;
  bool external_keyboard_connected;

  /* Toolbar */
  bool toolbar_enabled;
  UIToolbar *toolbar;
  UIBarButtonItem *toolbar_tip_item;
  UIBarButtonItem *toolbar_live_text_item;
  UIBarButtonItem *toolbar_done_editing_item;
  UIBarButtonItem *toolbar_cancel_editing_item;
  CFTimeInterval last_first_responder_time;
  CFTimeInterval last_gesture_tap_time;
  CGPoint last_gesture_tap_point;
  CFTimeInterval last_multitouch_time;
  CFTimeInterval last_pan2f_time;
  CFTimeInterval last_gesture_conflict_time;
  bool pan_button_active;
  CGPoint last_direct_touch_point;
  bool has_last_direct_touch_point;
  bool use_direct_touch_input;
  UITouch *single_active_touch;
  bool single_button_down;
  bool single_stream_locked_until_clear;
  CFTimeInterval last_single_move_emit_time;
  CGPoint last_single_move_emit_point;
  bool has_last_single_move_emit_point;
}

- (void)setSystemAndWindowIOS:(GHOST_SystemIOS *)sysCocoa windowIOS:(GHOST_WindowIOS *)winCocoa;

/* Blender event generation. */
- (void)generateUserInputEvents:(const UserInputEvent &)event_info;

/* Gesture recognizers. */
- (void)registerGestureRecognizers;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer;
- (void)handleTap:(GHOSTUITapGestureRecognizer *)sender;
- (void)handlePan:(GHOSTUIPanGestureRecognizer *)sender;
- (void)handlePan2f:(GHOSTUIPanGestureRecognizer *)sender;
- (void)handleZoom:(GHOSTUIPinchGestureRecognizer *)sender;
- (void)handlePointerHover:(GHOSTUIHoverGestureRecognizer *)sender;

/* On screen keyboard handling */
- (UITextField *)getUITextField;
- (const GHOST_TabletData)getTabletData;
- (void)updateTabletDataFromPencilTouch:(UITouch *)touch;
- (void)emitPencilStrokeEvent:(UITouch *)touch eventType:(GHOST_TEventType)eventType;
- (GHOST_TSuccess)popupOnscreenKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties;
- (GHOST_TSuccess)hideOnscreenKeyboard;
- (const char *)getLastKeyboardString;
- (void)handleKeyPresses:(NSSet<UIPress *> *)presses isDown:(BOOL)isDown;
- (void)ensureFirstResponderDebounced:(NSString *)reason;
- (void)resetInputStateForActivation;
- (void)processDirectTouchBeganForTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event;
- (void)processDirectTouchMovedForTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event;
- (void)processDirectTouchEndedForTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event;
@end

@implementation GHOSTUIWindow
static NSString *ios_touch_type_name(UITouchType type)
{
  switch (type) {
    case UITouchTypeDirect:
      return @"Direct";
    case UITouchTypeIndirect:
      return @"Indirect";
    case UITouchTypePencil:
      return @"Pencil";
    case UITouchTypeIndirectPointer:
      return @"IndirectPointer";
    default:
      return @"Unknown";
  }
}

- (void)setSystemAndWindowIOS:(GHOST_SystemIOS *)sys windowIOS:(GHOST_WindowIOS *)win
{
  system = sys;
  window = win;
  text_field = nil;
  original_text = nil;
  onscreen_keyboard_active = false;
  text_field_string = nullptr;
  current_pencil_touch = nil;
  pencil_stroke_active = false;
  tablet_data = GHOST_TABLET_DATA_NONE;
  last_pencil_emit_time = 0.0;
  last_pencil_emit_point = CGPointZero;
  has_last_pencil_emit_point = false;
  toolbar_enabled = true;
  toolbar = nil;
  last_tap_with_pencil = false;
  external_keyboard_connected = [GCKeyboard coalescedKeyboard] != nil;
  last_first_responder_time = 0.0;
  last_gesture_tap_time = 0.0;
  last_gesture_tap_point = CGPointZero;
  last_multitouch_time = 0.0;
  last_pan2f_time = 0.0;
  last_gesture_conflict_time = 0.0;
  pan_button_active = false;
  last_direct_touch_point = CGPointZero;
  has_last_direct_touch_point = false;
  single_active_touch = nil;
  single_button_down = false;
  single_stream_locked_until_clear = false;
  last_single_move_emit_time = 0.0;
  last_single_move_emit_point = CGPointZero;
  has_last_single_move_emit_point = false;
#if defined(WITH_APPLE_CROSSPLATFORM)
  use_direct_touch_input = true;
#else
  use_direct_touch_input = false;
#endif

  /* Register for notifications of chnanges to the onscreen keyboard. */
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(keyboardWillChange:)
                                               name:UIKeyboardWillChangeFrameNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(keyboardWillChange:)
                                               name:UIKeyboardWillShowNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(keyboardWillChange:)
                                               name:UIKeyboardWillHideNotification
                                             object:nil];

  /* Check whether we've linked the GameController framework. */
  if (&GCKeyboardDidConnectNotification != NULL) {
    /* Register for notifcations an external keyboard has been added/removed. */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalKeyboardChange:)
                                                 name:GCKeyboardDidConnectNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalKeyboardChange:)
                                                 name:GCKeyboardDidDisconnectNotification
                                               object:nil];
  }

  /* Ensure hardware keyboard events are routed to this window. */
  [self ensureFirstResponderDebounced:@"setSystemAndWindowIOS"];
}

- (BOOL)canBecomeFirstResponder
{
  return YES;
}

- (void)ensureFirstResponderDebounced:(NSString *)reason
{
  constexpr CFTimeInterval kMinFocusInterval = 0.2;
  const CFTimeInterval now = CACurrentMediaTime();
  const BOOL needs_responder = !self.isFirstResponder;
  const BOOL force_for_key_window = [reason isEqualToString:@"makeKeyWindow"];
  if (!force_for_key_window && !needs_responder && (now - last_first_responder_time) < kMinFocusInterval)
  {
    IOS_WINDOW_LOG(@"[iOS input] skip becomeFirstResponder (%@) dt=%.3f",
                   reason,
                   now - last_first_responder_time);
    return;
  }
  last_first_responder_time = now;
  const BOOL became = [self becomeFirstResponder];
  IOS_WINDOW_LOG(@"[iOS input] becomeFirstResponder (%@) -> %@", reason, became ? @"YES" : @"NO");
}

- (void)resetInputStateForActivation
{
  last_multitouch_time = 0.0;
  last_pan2f_time = 0.0;
  last_gesture_conflict_time = 0.0;
  pan_button_active = false;
  has_last_direct_touch_point = false;
  single_active_touch = nil;
  single_button_down = false;
  single_stream_locked_until_clear = false;
  last_single_move_emit_time = 0.0;
  last_single_move_emit_point = CGPointZero;
  has_last_single_move_emit_point = false;
  current_pencil_touch = nil;
  pencil_stroke_active = false;
  has_last_pencil_emit_point = false;
  last_pencil_emit_time = 0.0;
  tablet_data = GHOST_TABLET_DATA_NONE;
  if (pan_gesture_recognizer != nil) {
    [pan_gesture_recognizer setCachedTranslation:CGPointMake(0.0f, 0.0f)];
  }
  if (pan2f_gesture_recognizer != nil) {
    [pan2f_gesture_recognizer setCachedTranslation:CGPointMake(0.0f, 0.0f)];
  }
  if (zoom_gesture_recognizer != nil) {
    [zoom_gesture_recognizer setCachedDistance:0.0f];
  }
  IOS_WINDOW_LOG(@"[iOS input] resetInputStateForActivation");
}

static GHOST_TKey ghost_key_from_ui_key(UIKey *key)
{
  if (key == nil) {
    return GHOST_kKeyUnknown;
  }

  switch (key.keyCode) {
    case UIKeyboardHIDUsageKeyboardReturnOrEnter:
      return GHOST_kKeyEnter;
    case UIKeyboardHIDUsageKeyboardEscape:
      return GHOST_kKeyEsc;
    case UIKeyboardHIDUsageKeyboardDeleteOrBackspace:
      return GHOST_kKeyBackSpace;
    case UIKeyboardHIDUsageKeyboardDeleteForward:
      return GHOST_kKeyDelete;
    case UIKeyboardHIDUsageKeyboardTab:
      return GHOST_kKeyTab;
    case UIKeyboardHIDUsageKeyboardSpacebar:
      return GHOST_kKeySpace;
    case UIKeyboardHIDUsageKeyboardLeftArrow:
      return GHOST_kKeyLeftArrow;
    case UIKeyboardHIDUsageKeyboardRightArrow:
      return GHOST_kKeyRightArrow;
    case UIKeyboardHIDUsageKeyboardUpArrow:
      return GHOST_kKeyUpArrow;
    case UIKeyboardHIDUsageKeyboardDownArrow:
      return GHOST_kKeyDownArrow;
    default:
      break;
  }

  NSString *chars = key.charactersIgnoringModifiers;
  if (chars.length == 0) {
    return GHOST_kKeyUnknown;
  }
  const unichar c = [chars characterAtIndex:0];
  if (c >= 'a' && c <= 'z') {
    return GHOST_TKey(c - 'a' + GHOST_kKeyA);
  }
  if (c >= 'A' && c <= 'Z') {
    return GHOST_TKey(c - 'A' + GHOST_kKeyA);
  }
  if (c >= '0' && c <= '9') {
    return GHOST_TKey(c - '0' + GHOST_kKey0);
  }
  return GHOST_kKeyUnknown;
}

- (void)handleKeyPresses:(NSSet<UIPress *> *)presses isDown:(BOOL)isDown
{
  for (UIPress *press in presses) {
    UIKey *key = press.key;
    if (key == nil) {
      continue;
    }
    const GHOST_TKey ghost_key = ghost_key_from_ui_key(key);
    const char *utf8_buf = nullptr;
    if (isDown && key.characters.length > 0) {
      utf8_buf = [key.characters UTF8String];
    }
    system->pushEvent(new GHOST_EventKey(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                                         isDown ? GHOST_kEventKeyDown : GHOST_kEventKeyUp,
                                         window,
                                         ghost_key,
                                         false,
                                         utf8_buf));
  }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
  [self handleKeyPresses:presses isDown:YES];
  [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
  [self handleKeyPresses:presses isDown:NO];
  [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
  [self handleKeyPresses:presses isDown:NO];
  [super pressesCancelled:presses withEvent:event];
}

- (void)registerGestureRecognizers
{
#if defined(WITH_APPLE_CROSSPLATFORM)
  if (use_direct_touch_input) {
    /* Architecture reset:
     * Cross-platform iOS uses touches* as the only input path.
     * Do not register UIKit gesture recognizers at all. */
    tap_gesture_recognizer = nil;
    tap2f_gesture_recognizer = nil;
    tap3f_gesture_recognizer = nil;
    tap4f_gesture_recognizer = nil;
    pan_gesture_recognizer = nil;
    pan2f_gesture_recognizer = nil;
    zoom_gesture_recognizer = nil;
    hover_gesture_recognizer = nil;
    pointer_hover_gesture_recognizer = [[GHOSTUIHoverGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handlePointerHover:)];
    pointer_hover_gesture_recognizer.delegate = self;
    if (@available(iOS 13.4, *)) {
      pointer_hover_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeIndirectPointer) ];
    }
    [window->getView() addGestureRecognizer:pointer_hover_gesture_recognizer];
    edge_swipe_left = nil;
    edge_swipe_right = nil;
    pencil_interaction = nil;
    return;
  }
#endif

  /** Create Gesture recognisers. */
  /* Tap gesture recognizer. */
  tap_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap:)];
  tap_gesture_recognizer.delegate = self;
  tap_gesture_recognizer.cancelsTouchesInView = false;
  tap_gesture_recognizer.requiresExclusiveTouchType = NO;
  tap_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect), @(UITouchTypeIndirectPointer) ];
  [window->getView() addGestureRecognizer:tap_gesture_recognizer];

  /* Two-finger tap gesture recognizer. */
  tap2f_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap2F:)];
  tap2f_gesture_recognizer.delegate = self;
  tap2f_gesture_recognizer.cancelsTouchesInView = false;
  tap2f_gesture_recognizer.delaysTouchesBegan = YES;
  tap2f_gesture_recognizer.requiresExclusiveTouchType = NO;
  tap2f_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  tap2f_gesture_recognizer.numberOfTouchesRequired = 2;
  [window->getView() addGestureRecognizer:tap2f_gesture_recognizer];

  /* Three/four-finger taps can conflict with iOS system editing gestures on iPad. */
  /* Three-finger tap gesture recognizer. */
  tap3f_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap3F:)];
  tap3f_gesture_recognizer.delegate = self;
  tap3f_gesture_recognizer.cancelsTouchesInView = false;
  tap3f_gesture_recognizer.delaysTouchesBegan = YES;
  tap3f_gesture_recognizer.requiresExclusiveTouchType = NO;
  tap3f_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  tap3f_gesture_recognizer.numberOfTouchesRequired = 3;
  [window->getView() addGestureRecognizer:tap3f_gesture_recognizer];

  /* Four-finger tap gesture recognizer. */
  tap4f_gesture_recognizer = [[GHOSTUITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleTap4F:)];
  tap4f_gesture_recognizer.delegate = self;
  tap4f_gesture_recognizer.cancelsTouchesInView = false;
  tap4f_gesture_recognizer.delaysTouchesBegan = YES;
  tap4f_gesture_recognizer.requiresExclusiveTouchType = NO;
  tap4f_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  tap4f_gesture_recognizer.numberOfTouchesRequired = 4;
  [window->getView() addGestureRecognizer:tap4f_gesture_recognizer];

  /* Pan gesture recognizer - static UI. */
  pan_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePan:)];
  pan_gesture_recognizer.delegate = self;
  pan_gesture_recognizer.cancelsTouchesInView = false;
  pan_gesture_recognizer.requiresExclusiveTouchType = NO;
  /* Allow scrolling only with a single finger. */
  pan_gesture_recognizer.minimumNumberOfTouches = 1;
  pan_gesture_recognizer.maximumNumberOfTouches = 1;
  /* Allow finger and pencil. */
  pan_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect), @(UITouchTypeIndirectPointer) ];
  [window->getView() addGestureRecognizer:pan_gesture_recognizer];

  /* Pan gesture recognizer - two fingers 3D UI. */
  pan2f_gesture_recognizer = [[GHOSTUIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handlePan2f:)];
  pan2f_gesture_recognizer.delegate = self;
  pan2f_gesture_recognizer.cancelsTouchesInView = false;
  pan2f_gesture_recognizer.requiresExclusiveTouchType = NO;
  /* Two finger gestures only.  */
  pan2f_gesture_recognizer.minimumNumberOfTouches = 2;
  pan2f_gesture_recognizer.maximumNumberOfTouches = 2;
  pan2f_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:pan2f_gesture_recognizer];

  /* Pinch/Zoom gesture recognizer. */
  zoom_gesture_recognizer = [[GHOSTUIPinchGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleZoom:)];
  zoom_gesture_recognizer.delegate = self;
  zoom_gesture_recognizer.cancelsTouchesInView = false;
  zoom_gesture_recognizer.requiresExclusiveTouchType = NO;
  zoom_gesture_recognizer.allowedTouchTypes = @[ @(UITouchTypeDirect) ];
  [window->getView() addGestureRecognizer:zoom_gesture_recognizer];

  /* Edge swipe. */
  edge_swipe_left = [[UIScreenEdgePanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleEdgeSwipe:)];
  edge_swipe_left.edges = UIRectEdgeLeft;
  edge_swipe_left.delegate = self;
  [window->getView() addGestureRecognizer:edge_swipe_left];

  edge_swipe_right = [[UIScreenEdgePanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleEdgeSwipe:)];
  edge_swipe_right.edges = UIRectEdgeRight;
  edge_swipe_right.delegate = self;
  [window->getView() addGestureRecognizer:edge_swipe_right];

  /* Apple Pencil hover recognizer. */
  hover_gesture_recognizer = [[GHOSTUIHoverGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleHover:)];
  hover_gesture_recognizer.delegate = self;
  [window->getView() addGestureRecognizer:hover_gesture_recognizer];
  current_pencil_touch = nil;
  pencil_stroke_active = false;

  /**  Apple Pencil double-tap. */
  pencil_interaction = [[UIPencilInteraction alloc] init];
  pencil_interaction.delegate = self;
  [window->getView() addInteraction:pencil_interaction];
}

/* Turn the user inputs into Blender events.
 * We batch up the events rather than send them directly in the gesture
 * recognisers to ensure we don't interleave events if we detect simultaneous
 * inputs. */
- (void)generateUserInputEvents:(const UserInputEvent &)event_info
{
  if (event_info.num_events == 0) {
    return;
  }

  IOS_WINDOW_LOG(
      @"[iOS input] generateUserInputEvents num=%d loc=(%.2f,%.2f) tr=(%.2f,%.2f) dist=%.3f pencil=%@",
      event_info.num_events,
      event_info.location.x,
      event_info.location.y,
      event_info.translation.x,
      event_info.translation.y,
      event_info.distance,
      event_info.pencil_used ? @"YES" : @"NO");

  @synchronized(self) {
    for (int i = 0; i < event_info.num_events; i++) {
      UserInputEvent::EventTypes event_type = event_info.event_list[i];
      IOS_WINDOW_LOG(@"[iOS input] dispatch event[%d]=%@", i, event_info.getEventTypeDesc(event_type));
      IOS_INPUT_LOG(@"%d-%@ %f,%f",
                    i,
                    event_info.getEventTypeDesc(event_type),
                    event_info.location.x,
                    event_info.location.y);

      switch (event_type) {
        case UserInputEvent::EventTypes::CURSOR_MOVE:
          system->pushEvent(
              new GHOST_EventCursor(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                                    GHOST_kEventCursorMove,
                                    window,
                                    event_info.location.x,
                                    event_info.location.y,
                                    tablet_data));
          break;
        case UserInputEvent::EventTypes::PAN_GESTURE:
          system->pushEvent(
              new GHOST_EventTrackpad(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                                      window,
                                      GHOST_kTrackpadEventScroll,
                                      event_info.location.x,
                                      event_info.location.y,
                                      event_info.translation.x,
                                      event_info.translation.y,
                                      false,
                                      1));
          break;
        case UserInputEvent::EventTypes::PAN_GESTURE_TWO_FINGERS:
          system->pushEvent(
              new GHOST_EventTrackpad(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                                      window,
                                      GHOST_kTrackpadEventScroll,
                                      event_info.location.x,
                                      event_info.location.y,
                                      event_info.translation.x,
                                      event_info.translation.y,
                                      true,
                                      2));
          break;
        case UserInputEvent::EventTypes::LEFT_BUTTON_DOWN:
          system->pushEvent(
              new GHOST_EventButton(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                                    GHOST_kEventButtonDown,
                                    window,
                                    GHOST_kButtonMaskLeft,
                                    tablet_data));
          break;
        case UserInputEvent::EventTypes::LEFT_BUTTON_UP:
          system->pushEvent(
              new GHOST_EventButton(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                                    GHOST_kEventButtonUp,
                                    window,
                                    GHOST_kButtonMaskLeft,
                                    tablet_data));
          break;
        case UserInputEvent::EventTypes::PINCH_GESTURE:
          system->pushEvent(
              new GHOST_EventTrackpad(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                                      window,
                                      GHOST_kTrackpadEventMagnify,
                                      event_info.location.x,
                                      event_info.location.y,
                                      event_info.distance,
                                      0,
                                      false,
                                      2));
          break;
        case UserInputEvent::EventTypes::PENCIL_TAP:
          /* Simulate clicking with the right mouse button. */
          system->pushEvent(
              new GHOST_EventButton(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                                    GHOST_kEventButtonDown,
                                    window,
                                    GHOST_kButtonMaskRight,
                                    tablet_data));
          break;
        default:
          GHOST_ASSERT(FALSE, "GHOST_SystemIOS::generateUserInputEvents unsupported event type");
      }
    }
  }
}

- (void)processDirectTouchBeganForTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event
{
  if (!use_direct_touch_input || event == nil) {
    return;
  }

  for (UITouch *touch in touches) {
    if (touch.type == UITouchTypePencil) {
      return;
    }
  }

  if (single_active_touch != nil) {
    return;
  }

  NSUInteger direct_count = 0;
  for (UITouch *touch in event.allTouches) {
    if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
      continue;
    }
    if (touch.type == UITouchTypeDirect || touch.type == UITouchTypeIndirectPointer) {
      direct_count++;
    }
  }
  IOS_WINDOW_LOG(@"[iOS input][FSM] began enter direct_count=%lu locked=%@ single_down=%@ active=%p",
                 (unsigned long)direct_count,
                 single_stream_locked_until_clear ? @"YES" : @"NO",
                 single_button_down ? @"YES" : @"NO",
                 single_active_touch);
  if (single_stream_locked_until_clear) {
    IOS_WINDOW_LOG(@"[iOS input][FSM] began ignored: locked");
    return;
  }
  if (single_button_down && direct_count >= 2) {
    CGPoint point = [single_active_touch locationInView:window->getView()];
    point = window->scalePointToWindow(point);
    UserInputEvent cancel_event(&point, nullptr, nullptr, false);
    cancel_event.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
    cancel_event.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_UP);
    [self generateUserInputEvents:cancel_event];
    single_active_touch = nil;
    single_button_down = false;
    pan_button_active = false;
    single_stream_locked_until_clear = true;
    has_last_single_move_emit_point = false;
    IOS_WINDOW_LOG(@"[iOS input] single stream cancel -> LOCK (direct_count=%lu)",
                   (unsigned long)direct_count);
    return;
  }
  if (direct_count != 1) {
    IOS_WINDOW_LOG(@"[iOS input][FSM] began ignored: direct_count=%lu (!=1)", (unsigned long)direct_count);
    return;
  }

  UITouch *began_touch = nil;
  for (UITouch *touch in touches) {
    if ((touch.type == UITouchTypeDirect || touch.type == UITouchTypeIndirectPointer) &&
        touch.phase == UITouchPhaseBegan)
    {
      began_touch = touch;
      break;
    }
  }
  if (began_touch == nil) {
    IOS_WINDOW_LOG(@"[iOS input][FSM] began ignored: no began_touch in touches");
    return;
  }

  single_active_touch = began_touch;
  CGPoint point = [began_touch locationInView:window->getView()];
  point = window->scalePointToWindow(point);
  UserInputEvent event_info(&point, nullptr, nullptr, false);
  event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
  event_info.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_DOWN);
  single_button_down = true;
  pan_button_active = true;
  last_single_move_emit_time = CACurrentMediaTime();
  last_single_move_emit_point = point;
  has_last_single_move_emit_point = true;
  [self generateUserInputEvents:event_info];
  IOS_WINDOW_LOG(@"[iOS input] stream switch -> SINGLE active=%p x=%.2f y=%.2f",
                 single_active_touch,
                 point.x,
                 point.y);
}

- (void)processDirectTouchMovedForTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event
{
  if (!use_direct_touch_input || event == nil || single_active_touch == nil) {
    IOS_WINDOW_LOG(@"[iOS input][FSM] moved ignored: ready=%@ event_nil=%@ active=%p",
                   use_direct_touch_input ? @"YES" : @"NO",
                   event == nil ? @"YES" : @"NO",
                   single_active_touch);
    return;
  }

  for (UITouch *touch in touches) {
    if (touch.type == UITouchTypePencil) {
      return;
    }
  }

  NSUInteger direct_count = 0;
  for (UITouch *touch in event.allTouches) {
    if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
      continue;
    }
    if (touch.type == UITouchTypeDirect || touch.type == UITouchTypeIndirectPointer) {
      direct_count++;
    }
  }
  IOS_WINDOW_LOG(@"[iOS input][FSM] moved enter direct_count=%lu locked=%@ single_down=%@ active=%p",
                 (unsigned long)direct_count,
                 single_stream_locked_until_clear ? @"YES" : @"NO",
                 single_button_down ? @"YES" : @"NO",
                 single_active_touch);
  if (single_button_down && direct_count >= 2) {
    CGPoint point = [single_active_touch locationInView:window->getView()];
    point = window->scalePointToWindow(point);
    UserInputEvent cancel_event(&point, nullptr, nullptr, false);
    cancel_event.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
    cancel_event.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_UP);
    [self generateUserInputEvents:cancel_event];
    single_active_touch = nil;
    single_button_down = false;
    pan_button_active = false;
    single_stream_locked_until_clear = true;
    has_last_single_move_emit_point = false;
    IOS_WINDOW_LOG(@"[iOS input] single stream cancel -> LOCK (direct_count=%lu)",
                   (unsigned long)direct_count);
    return;
  }

  UITouch *moved_touch = nil;
  for (UITouch *touch in touches) {
    if (touch == single_active_touch &&
        (touch.type == UITouchTypeDirect || touch.type == UITouchTypeIndirectPointer) &&
        touch.phase == UITouchPhaseMoved)
    {
      moved_touch = touch;
      break;
    }
  }
  if (moved_touch == nil) {
    IOS_WINDOW_LOG(@"[iOS input][FSM] moved ignored: no moved_touch for active=%p", single_active_touch);
    return;
  }

  /* Keep existing direct-touch behavior unchanged; enable continuous move only for external mouse. */
  if (@available(iOS 13.4, *)) {
    if (moved_touch.type != UITouchTypeIndirectPointer) {
      return;
    }
  }
  else {
    return;
  }

  CGPoint point = [moved_touch locationInView:window->getView()];
  point = window->scalePointToWindow(point);
  const CFTimeInterval now = CACurrentMediaTime();
  constexpr CGFloat kMinMoveDist = 1.0f;
  constexpr CFTimeInterval kMinMoveInterval = 1.0 / 60.0;
  bool should_emit = !has_last_single_move_emit_point;
  if (!should_emit) {
    const CGFloat dx = point.x - last_single_move_emit_point.x;
    const CGFloat dy = point.y - last_single_move_emit_point.y;
    const CGFloat dist_sq = (dx * dx) + (dy * dy);
    const bool moved_enough = dist_sq >= (kMinMoveDist * kMinMoveDist);
    const bool time_elapsed = (now - last_single_move_emit_time) >= kMinMoveInterval;
    should_emit = moved_enough || time_elapsed;
  }
  if (!should_emit) {
    IOS_WINDOW_LOG(@"[iOS input][FSM] moved debounce-skip x=%.2f y=%.2f dt=%.4f",
                   point.x,
                   point.y,
                   (double)(now - last_single_move_emit_time));
    return;
  }
  UserInputEvent move_event(&point, nullptr, nullptr, false);
  move_event.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
  [self generateUserInputEvents:move_event];
  last_single_move_emit_time = now;
  last_single_move_emit_point = point;
  has_last_single_move_emit_point = true;
  IOS_WINDOW_LOG(@"[iOS input][FSM] moved emit x=%.2f y=%.2f", point.x, point.y);
}

- (void)processDirectTouchEndedForTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event
{
  if (!use_direct_touch_input || event == nil) {
    IOS_WINDOW_LOG(@"[iOS input][FSM] ended ignored: ready=%@ event_nil=%@",
                   use_direct_touch_input ? @"YES" : @"NO",
                   event == nil ? @"YES" : @"NO");
    return;
  }

  for (UITouch *touch in touches) {
    if (touch.type == UITouchTypePencil) {
      return;
    }
  }

  UITouch *ended_direct_touch = nil;
  for (UITouch *touch in touches) {
    if ((touch.type == UITouchTypeDirect || touch.type == UITouchTypeIndirectPointer) &&
        touch == single_active_touch &&
        (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled))
    {
      ended_direct_touch = touch;
      break;
    }
  }
  IOS_WINDOW_LOG(@"[iOS input][FSM] ended enter active=%p ended_touch=%p single_down=%@",
                 single_active_touch,
                 ended_direct_touch,
                 single_button_down ? @"YES" : @"NO");

  if (ended_direct_touch != nil && single_button_down) {
    UserInputEvent end_event(nullptr, nullptr, nullptr, false);
    end_event.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_UP);
    [self generateUserInputEvents:end_event];
    single_button_down = false;
    pan_button_active = false;
  }
  else {
    IOS_WINDOW_LOG(@"[iOS input][FSM] ended no-op: ended_touch=%p single_down=%@",
                   ended_direct_touch,
                   single_button_down ? @"YES" : @"NO");
  }
  single_active_touch = nil;

  single_button_down = false;
  pan_button_active = false;
  has_last_single_move_emit_point = false;

  NSUInteger remaining_direct_touches = 0;
  for (UITouch *active_touch in event.allTouches) {
    if (active_touch.phase == UITouchPhaseEnded || active_touch.phase == UITouchPhaseCancelled) {
      continue;
    }
    if (active_touch.type == UITouchTypeDirect || active_touch.type == UITouchTypeIndirectPointer) {
      remaining_direct_touches++;
    }
  }
  if (remaining_direct_touches == 0 && single_stream_locked_until_clear) {
    single_stream_locked_until_clear = false;
    IOS_WINDOW_LOG(@"[iOS input] single stream UNLOCK");
  }
  IOS_WINDOW_LOG(@"[iOS input][FSM] ended exit remaining_direct_touches=%lu locked=%@",
                 (unsigned long)remaining_direct_touches,
                 single_stream_locked_until_clear ? @"YES" : @"NO");
}

/* Allow simultaneous gestures for two finger pans and zooms but nothing else. */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
        (UIGestureRecognizer *)otherGestureRecognizer
{
  const bool pan2f_zoom_pair =
      (gestureRecognizer == pan2f_gesture_recognizer &&
       otherGestureRecognizer == zoom_gesture_recognizer) ||
      (gestureRecognizer == zoom_gesture_recognizer &&
       otherGestureRecognizer == pan2f_gesture_recognizer);
  return pan2f_zoom_pair ? YES : NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
  if (touch.type == UITouchTypePencil) {
    return NO;
  }
  if (pencil_stroke_active && touch.type == UITouchTypeDirect) {
    return NO;
  }
  if (touch.type == UITouchTypeIndirectPointer) {
    return (gestureRecognizer == tap_gesture_recognizer ||
            gestureRecognizer == pan_gesture_recognizer ||
            gestureRecognizer == pointer_hover_gesture_recognizer);
  }
  return YES;
}

/* Override touch methods to capture the UITouch object. */
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  IOS_WINDOW_LOG(@"[iOS input] touchesBegan state key=%@ first=%@ appState=%ld",
                 self.isKeyWindow ? @"YES" : @"NO",
                 self.isFirstResponder ? @"YES" : @"NO",
                 (long)[UIApplication sharedApplication].applicationState);
  /* If keyboard input temporarily restores interaction, mirror that recovery on touch begin. */
  if (!self.isKeyWindow) {
    [self makeKeyAndVisible];
  }
  if (![self isFirstResponder]) {
    [self ensureFirstResponderDebounced:@"touchesBegan(recover)"];
  }
  [super touchesBegan:touches withEvent:event];
  const NSUInteger all_touch_count = event.allTouches.count;
  if (all_touch_count > 1) {
    last_multitouch_time = CACurrentMediaTime();
  }
  for (UITouch *touch in touches) {
    const CGPoint p = [touch locationInView:window->getView()];
    if (touch.type == UITouchTypeDirect || touch.type == UITouchTypeIndirectPointer) {
      last_direct_touch_point = p;
      has_last_direct_touch_point = true;
    }
    const BOOL on_metal_view = (touch.view == window->getView());
    IOS_WINDOW_LOG(
        @"[iOS input] touchesBegan count=%lu type=%@ phase=%ld onMetal=%@ x=%.2f y=%.2f",
        (unsigned long)touches.count,
        ios_touch_type_name(touch.type),
        (long)touch.phase,
        on_metal_view ? @"YES" : @"NO",
        p.x,
        p.y);
  }

#if defined(WITH_APPLE_CROSSPLATFORM)
  [self processDirectTouchBeganForTouches:touches event:event];
  if (use_direct_touch_input) {
    return;
  }
#endif

  for (UITouch *touch in touches) {
    if (touch.type == UITouchTypePencil) {
      current_pencil_touch = touch;
      [self updateTabletDataFromPencilTouch:touch];
      [self emitPencilStrokeEvent:touch eventType:GHOST_kEventButtonDown];
      pencil_stroke_active = true;
      break;
    }
  }
}

/* Get updated tablet data. */
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesMoved:touches withEvent:event];
  const NSUInteger all_touch_count = event.allTouches.count;
  if (all_touch_count > 1) {
    last_multitouch_time = CACurrentMediaTime();
  }
  for (UITouch *touch in touches) {
    const CGPoint p = [touch locationInView:window->getView()];
    if (touch.type == UITouchTypeDirect || touch.type == UITouchTypeIndirectPointer) {
      last_direct_touch_point = p;
      has_last_direct_touch_point = true;
    }
    const BOOL on_metal_view = (touch.view == window->getView());
    IOS_WINDOW_LOG(
        @"[iOS input] touchesMoved count=%lu type=%@ phase=%ld onMetal=%@ x=%.2f y=%.2f",
        (unsigned long)touches.count,
        ios_touch_type_name(touch.type),
        (long)touch.phase,
        on_metal_view ? @"YES" : @"NO",
        p.x,
        p.y);
  }

#if defined(WITH_APPLE_CROSSPLATFORM)
  [self processDirectTouchMovedForTouches:touches event:event];
  if (use_direct_touch_input) {
    return;
  }
#endif

  /* Iterate through all pencil touches and emit high-frequency move events. */
  for (UITouch *touch in touches) {
    if (touch.type != UITouchTypePencil) {
      continue;
    }

    current_pencil_touch = touch;
    if (!pencil_stroke_active) {
      [self updateTabletDataFromPencilTouch:touch];
      [self emitPencilStrokeEvent:touch eventType:GHOST_kEventButtonDown];
      pencil_stroke_active = true;
    }

    NSArray<UITouch *> *coalesced = [event coalescedTouchesForTouch:touch];
    const CFTimeInterval now = CACurrentMediaTime();
    constexpr CFTimeInterval kMinEmitInterval = 1.0 / 120.0;
    constexpr CGFloat kMinEmitDistance = 0.75f;

    auto should_emit_sample = ^bool(UITouch *sample_touch) {
      const CGPoint point = [sample_touch locationInView:window->getView()];
      const CFTimeInterval dt = now - last_pencil_emit_time;
      if (dt >= kMinEmitInterval) {
        return true;
      }
      if (!has_last_pencil_emit_point) {
        return true;
      }
      const CGFloat dx = point.x - last_pencil_emit_point.x;
      const CGFloat dy = point.y - last_pencil_emit_point.y;
      return ((dx * dx) + (dy * dy)) >= (kMinEmitDistance * kMinEmitDistance);
    };

    if (coalesced.count > 0) {
      const NSUInteger max_samples = 3;
      const NSUInteger start = (coalesced.count > max_samples) ? (coalesced.count - max_samples) : 0;
      for (NSUInteger i = start; i < coalesced.count; i++) {
        UITouch *sample = coalesced[i];
        if (!should_emit_sample(sample)) {
          continue;
        }
        [self updateTabletDataFromPencilTouch:sample];
        [self emitPencilStrokeEvent:sample eventType:GHOST_kEventCursorMove];
        last_pencil_emit_time = now;
        last_pencil_emit_point = [sample locationInView:window->getView()];
        has_last_pencil_emit_point = true;
      }
    }
    else {
      if (!should_emit_sample(touch)) {
        break;
      }
      [self updateTabletDataFromPencilTouch:touch];
      [self emitPencilStrokeEvent:touch eventType:GHOST_kEventCursorMove];
      last_pencil_emit_time = now;
      last_pencil_emit_point = [touch locationInView:window->getView()];
      has_last_pencil_emit_point = true;
    }

    IOS_INPUT_LOG(
        @"TABLET: X:%f,Y:%f,P:%f", tablet_data.Xtilt, tablet_data.Ytilt, tablet_data.Pressure);
    break;
  }
}

/* Reset tablet data. */
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesEnded:touches withEvent:event];
  const CFTimeInterval now = CACurrentMediaTime();
  for (UITouch *touch in touches) {
    const CGPoint p = [touch locationInView:window->getView()];
    if (touch.type == UITouchTypeDirect || touch.type == UITouchTypeIndirectPointer) {
      last_direct_touch_point = p;
      has_last_direct_touch_point = true;
    }
    const BOOL on_metal_view = (touch.view == window->getView());
    IOS_WINDOW_LOG(
        @"[iOS input] touchesEnded count=%lu type=%@ phase=%ld onMetal=%@ x=%.2f y=%.2f",
        (unsigned long)touches.count,
        ios_touch_type_name(touch.type),
        (long)touch.phase,
        on_metal_view ? @"YES" : @"NO",
        p.x,
        p.y);

    (void)now;
    (void)on_metal_view;
  }

#if defined(WITH_APPLE_CROSSPLATFORM)
  [self processDirectTouchEndedForTouches:touches event:event];
  if (use_direct_touch_input) {
    return;
  }
#endif

  for (UITouch *touch in touches) {
    if (touch.type == UITouchTypePencil) {
      [self updateTabletDataFromPencilTouch:touch];
      [self emitPencilStrokeEvent:touch eventType:GHOST_kEventButtonUp];
      break;
    }
  }
  current_pencil_touch = nil;
  pencil_stroke_active = false;
  has_last_pencil_emit_point = false;
  last_pencil_emit_time = 0.0;
  tablet_data = GHOST_TABLET_DATA_NONE;
}

/* Reset tablet data. */
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesCancelled:touches withEvent:event];
  for (UITouch *touch in touches) {
    const CGPoint p = [touch locationInView:window->getView()];
    if (touch.type == UITouchTypeDirect || touch.type == UITouchTypeIndirectPointer) {
      last_direct_touch_point = p;
      has_last_direct_touch_point = true;
    }
    const BOOL on_metal_view = (touch.view == window->getView());
    IOS_WINDOW_LOG(
        @"[iOS input] touchesCancelled count=%lu type=%@ phase=%ld onMetal=%@ x=%.2f y=%.2f",
        (unsigned long)touches.count,
        ios_touch_type_name(touch.type),
        (long)touch.phase,
        on_metal_view ? @"YES" : @"NO",
        p.x,
        p.y);
  }
  for (UITouch *touch in touches) {
    if (touch.type == UITouchTypePencil) {
      [self updateTabletDataFromPencilTouch:touch];
      [self emitPencilStrokeEvent:touch eventType:GHOST_kEventButtonUp];
      break;
    }
  }
  current_pencil_touch = nil;
  pencil_stroke_active = false;
  has_last_pencil_emit_point = false;
  last_pencil_emit_time = 0.0;
  tablet_data = GHOST_TABLET_DATA_NONE;

#if defined(WITH_APPLE_CROSSPLATFORM)
  [self processDirectTouchEndedForTouches:touches event:event];
  if (use_direct_touch_input) {
    return;
  }
#endif
}

- (void)updateTabletDataFromPencilTouch:(UITouch *)touch
{
  if (touch == nil) {
    tablet_data = GHOST_TABLET_DATA_NONE;
    return;
  }

  tablet_data.Active = GHOST_kTabletModeStylus;
  const CGFloat max_force = (touch.maximumPossibleForce > 0.0f) ? touch.maximumPossibleForce : 1.0f;
  tablet_data.Pressure = touch.force / max_force;

  const CGFloat azimuth_angle = [touch azimuthAngleInView:window->getView()];
  const CGFloat altitude_angle = [touch altitudeAngle];
  const CGFloat max_tilt = cos(0);
  tablet_data.Xtilt = sin(azimuth_angle) * cos(altitude_angle) / max_tilt;
  tablet_data.Ytilt = -cos(azimuth_angle) * cos(altitude_angle) / max_tilt;
}

- (void)emitPencilStrokeEvent:(UITouch *)touch eventType:(GHOST_TEventType)eventType
{
  if (touch == nil) {
    return;
  }

  CGPoint touch_point = [touch locationInView:window->getView()];
  touch_point = window->scalePointToWindow(touch_point);

  if (eventType == GHOST_kEventButtonDown) {
    IOS_WINDOW_LOG(@"[iOS input] emitPencil ButtonDown x=%.2f y=%.2f pressure=%.3f",
                   touch_point.x,
                   touch_point.y,
                   tablet_data.Pressure);
    system->pushEvent(
        new GHOST_EventButton(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                              eventType,
                              window,
                              GHOST_kButtonMaskLeft,
                              tablet_data));
    system->pushEvent(
        new GHOST_EventCursor(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                              GHOST_kEventCursorMove,
                              window,
                              touch_point.x,
                              touch_point.y,
                              tablet_data));
    return;
  }

  IOS_WINDOW_LOG(@"[iOS input] emitPencil CursorMove x=%.2f y=%.2f pressure=%.3f",
                 touch_point.x,
                 touch_point.y,
                 tablet_data.Pressure);
  system->pushEvent(
      new GHOST_EventCursor(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                            GHOST_kEventCursorMove,
                            window,
                            touch_point.x,
                            touch_point.y,
                            tablet_data));

  if (eventType == GHOST_kEventButtonUp) {
    IOS_WINDOW_LOG(@"[iOS input] emitPencil ButtonUp x=%.2f y=%.2f pressure=%.3f",
                   touch_point.x,
                   touch_point.y,
                   tablet_data.Pressure);
    system->pushEvent(
        new GHOST_EventButton(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                              eventType,
                              window,
                              GHOST_kButtonMaskLeft,
                              tablet_data));
  }
}

- (void)handleTap:(GHOSTUITapGestureRecognizer *)sender
{
#if defined(WITH_APPLE_CROSSPLATFORM)
  if (use_direct_touch_input) {
    return;
  }
#endif
  IOS_WINDOW_LOG(@"[iOS input] handleTap state=%ld touches=%lu",
                 (long)sender.state,
                 (unsigned long)sender.numberOfTouches);
  CGPoint touch_point = [sender getScaledTouchPoint:window];
  if (has_last_direct_touch_point) {
    touch_point = window->scalePointToWindow(last_direct_touch_point);
  }
  /* Pencil is handled via touches* path, so gesture taps are always non-pencil input. */
  last_tap_with_pencil = false;
  UserInputEvent event_info(&touch_point, nullptr, nullptr, last_tap_with_pencil);

  /* Send events to indicate a 'click' on event end. */
  if (sender.state == UIGestureRecognizerStateEnded) {
    pan_button_active = false;
    last_gesture_tap_time = CACurrentMediaTime();
    last_gesture_tap_point = touch_point;
    event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
    event_info.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_DOWN);
    event_info.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_UP);
  }

  [self generateUserInputEvents:event_info];
}

- (void)handleTap2F:(GHOSTUITapGestureRecognizer *)sender
{
  if (sender.state != UIGestureRecognizerStateEnded) {
    return;
  }

  CGPoint touch_point = [sender locationInView:window->getView()];
  CGFloat scale = [window->getView() contentScaleFactor];
  touch_point.x *= scale;
  touch_point.y *= scale;

  system->pushEvent(new GHOST_Event(
      GHOST_GetMilliSeconds((GHOST_SystemHandle)system), GHOST_kEventTwoFingerTap, window));
}

- (void)handleTap3F:(GHOSTUITapGestureRecognizer *)sender
{
  if (sender.state != UIGestureRecognizerStateEnded) {
    return;
  }

  CGPoint touch_point = [sender locationInView:window->getView()];
  CGFloat scale = [window->getView() contentScaleFactor];
  touch_point.x *= scale;
  touch_point.y *= scale;

  system->pushEvent(new GHOST_Event(
      GHOST_GetMilliSeconds((GHOST_SystemHandle)system), GHOST_kEventThreeFingerTap, window));
}

- (void)handleTap4F:(GHOSTUITapGestureRecognizer *)sender
{
  if (sender.state != UIGestureRecognizerStateEnded) {
    return;
  }

  CGPoint touch_point = [sender locationInView:window->getView()];
  CGFloat scale = [window->getView() contentScaleFactor];
  touch_point.x *= scale;
  touch_point.y *= scale;

  system->pushEvent(new GHOST_Event(
      GHOST_GetMilliSeconds((GHOST_SystemHandle)system), GHOST_kEventFourFingerTap, window));
}

- (void)handlePan:(GHOSTUIPanGestureRecognizer *)sender
{
#if defined(WITH_APPLE_CROSSPLATFORM)
  if (use_direct_touch_input) {
    return;
  }
#endif
  IOS_WINDOW_LOG(@"[iOS input] handlePan state=%ld touches=%lu",
                 (long)sender.state,
                 (unsigned long)sender.numberOfTouches);
  if ([sender numberOfTouches] == 0) {
    if (pan_button_active && (sender.state == UIGestureRecognizerStateEnded ||
                              sender.state == UIGestureRecognizerStateCancelled ||
                              sender.state == UIGestureRecognizerStateFailed))
    {
      UserInputEvent end_event(nullptr, nullptr, nullptr, false);
      end_event.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_UP);
      [self generateUserInputEvents:end_event];
      pan_button_active = false;
    }
    return;
  }
  if ([sender numberOfTouches] != 1) {
    if (pan_button_active && (sender.state == UIGestureRecognizerStateEnded ||
                              sender.state == UIGestureRecognizerStateCancelled ||
                              sender.state == UIGestureRecognizerStateFailed))
    {
      UserInputEvent end_event(nullptr, nullptr, nullptr, false);
      end_event.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_UP);
      [self generateUserInputEvents:end_event];
      pan_button_active = false;
    }
    return;
  }

  CGPoint touch_point = [sender getScaledTouchPoint:window];
  if (has_last_direct_touch_point) {
    touch_point = window->scalePointToWindow(last_direct_touch_point);
  }
  CGPoint translation = [sender getScaledTranslation:window];
  const bool pencil_pan = false;

  UserInputEvent event_info(&touch_point, nullptr, nullptr, pencil_pan);

  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    /* Register initial click for click and drag support. */
    if (sender.state == UIGestureRecognizerStateBegan) {
      /* Set inital translation */
      [sender setCachedTranslation:translation];
      event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
      event_info.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_DOWN);
      pan_button_active = true;
    }

    /* Update cached translation for the next change event.
     * Intentionally do not emit PAN_GESTURE for single-finger drags:
     * UI dragging must stay on the mouse-like path only (CM/LB down/up). */
    [sender setCachedTranslation:translation];

    /* Update cursor position on change */
    if (sender.state == UIGestureRecognizerStateChanged) {
      event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
    }
  }

  /* Mouse release for pan. */
  if (sender.state == UIGestureRecognizerStateEnded ||
      sender.state == UIGestureRecognizerStateCancelled ||
      sender.state == UIGestureRecognizerStateFailed)
  {
    if (pan_button_active) {
      event_info.add_event(UserInputEvent::EventTypes::LEFT_BUTTON_UP);
      pan_button_active = false;
    }
  }
  [self generateUserInputEvents:event_info];
}

- (void)handlePan2f:(GHOSTUIPanGestureRecognizer *)sender
{
  IOS_WINDOW_LOG(@"[iOS input] handlePan2f state=%ld touches=%lu",
                 (long)sender.state,
                 (unsigned long)sender.numberOfTouches);
  /* Ignore transient one-finger updates while a two-finger gesture is ending. */
  if ([sender numberOfTouches] != 2) {
    if (sender.state == UIGestureRecognizerStateEnded ||
        sender.state == UIGestureRecognizerStateCancelled ||
        sender.state == UIGestureRecognizerStateFailed)
    {
      last_gesture_conflict_time = CACurrentMediaTime();
      [sender setCachedTranslation:CGPointMake(0.0f, 0.0f)];
    }
    return;
  }

  /* Translation can be non-zero on begin event */
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    CGPoint translation = [sender getScaledTranslation:window];

    /* Calculate translation relative to previous cached value. */
    CGPoint relative_translation = [sender getRelativeTranslation:translation];

    /* Cache new translation. */
    [sender setCachedTranslation:translation];

    /* Generate pan event if translation is non zero. */
    if (!CGPointEqualToPoint(relative_translation, CGPointMake(0.0f, 0.0f))) {
      CGPoint touch_point = [sender getScaledTouchPoint:window];
      const bool pencil_pan = false;
      UserInputEvent event_info(&touch_point, &relative_translation, nullptr, pencil_pan);
      event_info.add_event(UserInputEvent::EventTypes::PAN_GESTURE_TWO_FINGERS);
      [self generateUserInputEvents:event_info];
      last_pan2f_time = CACurrentMediaTime();
      last_gesture_conflict_time = last_pan2f_time;
    }
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    last_gesture_conflict_time = CACurrentMediaTime();
    /* Set translation back to zero. */
    [sender setCachedTranslation:CGPointMake(0.0f, 0.0f)];
  }
}

- (void)handleEdgeSwipe:(UIScreenEdgePanGestureRecognizer *)gesture
{
  if (gesture.state != UIGestureRecognizerStateEnded) {
    return;
  }

  UIView *view = window->getView();
  CGPoint location = [gesture locationInView:view];
  CGSize viewSize = view.bounds.size;

  GHOST_TTouchEventSubTypes ghostEventType;

  if (gesture.edges == UIRectEdgeLeft) {
    ghostEventType = GHOST_kTouchEventEdgeSwipeInLeft;
  }
  else if (gesture.edges == UIRectEdgeRight) {
    ghostEventType = GHOST_kTouchEventEdgeSwipeInRight;
  }
  else {
    /* For now only handle left/right. */
    return;
  }

  system->pushEvent(new GHOST_EventTouch(
      system->getMilliSeconds(), window, ghostEventType, location.x, location.y));
}

- (void)handleHover:(GHOSTUIHoverGestureRecognizer *)sender
{
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    /* Tablet needs to be set to stylus mode because we need
     * wmTabletData.is_motion_absolute set to true. */
    tablet_data.Active = GHOST_kTabletModeStylus;
    CGPoint hover_point = [sender getScaledTouchPoint:window];
    /* Add cursor move event. */
    UserInputEvent event_info(&hover_point, nullptr, nullptr, true);
    event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
    [self generateUserInputEvents:event_info];
  }
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
    tablet_data = GHOST_TABLET_DATA_NONE;
  }
}

- (void)handleZoom:(GHOSTUIPinchGestureRecognizer *)sender
{
  IOS_WINDOW_LOG(@"[iOS input] handleZoom state=%ld touches=%lu",
                 (long)sender.state,
                 (unsigned long)sender.numberOfTouches);
  last_gesture_conflict_time = CACurrentMediaTime();
  /* Temporarily disable pinch on iOS to eliminate PAN2F/PINCH contention. */
#if 1
  return;
#endif
  /* Ignore any calls where don't have exactly two touches to work with. */
  if ([sender numberOfTouches] != 2) {
    return;
  }

  /* Pinch/Zoom gestures */
  if (sender.state == UIGestureRecognizerStateBegan) {
    /* Set an initial distance value. */
    CGFloat point_distance = [sender getScaledDistance:window];
    [sender setCachedDistance:point_distance];
  }
  else if (sender.state == UIGestureRecognizerStateChanged) {

    /* Calculate change in distance since last event */
    CGFloat point_distance = [sender getScaledDistance:window];
    CGFloat relative_dist = point_distance - [sender getCachedDistance];

    /* Updated cached distance. */
    [sender setCachedDistance:point_distance];

    /* Send pinch/zoom event. */
    if (fabs(relative_dist) > 0.0) {
      /* Calculate midpoint between the two touch points. */
      CGPoint midPoint = [sender getPinchMidpoint:window];

      UserInputEvent event_info(&midPoint, nullptr, &relative_dist, false);
      event_info.add_event(UserInputEvent::EventTypes::PINCH_GESTURE);
      [self generateUserInputEvents:event_info];
    }
  }
  /* Nothing to do here. */
  else if (sender.state == UIGestureRecognizerStateEnded ||
           sender.state == UIGestureRecognizerStateCancelled ||
           sender.state == UIGestureRecognizerStateFailed)
  {
  }
}

- (void)handlePointerHover:(GHOSTUIHoverGestureRecognizer *)sender
{
#if defined(WITH_APPLE_CROSSPLATFORM)
  if (!use_direct_touch_input) {
    return;
  }
#endif
  if (sender.state == UIGestureRecognizerStateBegan ||
      sender.state == UIGestureRecognizerStateChanged)
  {
    CGPoint hover_point = [sender getScaledTouchPoint:window];
    UserInputEvent event_info(&hover_point, nullptr, nullptr, false);
    event_info.add_event(UserInputEvent::EventTypes::CURSOR_MOVE);
    [self generateUserInputEvents:event_info];
  }
}

- (void)pencilInteractionDidTap:(UIPencilInteraction *)interaction
{
  UserInputEvent event_info(nullptr, nullptr, nullptr, true);
  event_info.add_event(UserInputEvent::EventTypes::PENCIL_TAP);
  [self generateUserInputEvents:event_info];
}

- (void)beginFrame
{
}

- (void)endFrame
{
}

- (void)initToolbar
{
  /* This gets the current view size */
  UIView *ui_view = window->getView();
  CGSize frame_size = [ui_view sizeThatFits:CGSizeMake(0.0f, 0.0f)];
  /* Create a toolbar the width of the screen. */
  toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, frame_size.width, 44)];
  toolbar.barStyle = UIBarStyleDefault;
  toolbar.translucent = true;
  /* IOS_FIXME - Despite following Apple guidelines this toolbar still
   * appears to apparently violate the view constraints. It displays fine
   * but generates a lot of warning output to the console. */
  toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  toolbar.translatesAutoresizingMaskIntoConstraints = NO;
  [toolbar sizeToFit];

  toolbar_tip_item = [[UIBarButtonItem alloc] initWithTitle:@""
                                                      style:UIBarButtonItemStylePlain
                                                     target:nil
                                                     action:nil];

  toolbar_live_text_item = [[UIBarButtonItem alloc] initWithTitle:@""
                                                            style:UIBarButtonItemStylePlain
                                                           target:nil
                                                           action:nil];

  toolbar_done_editing_item = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                           target:nil
                           action:@selector(handleDoneButton)];

  toolbar_cancel_editing_item = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                           target:nil
                           action:@selector(handleCancelButton)];

  /* Prevents editing of tip and live text fields. */
  toolbar_tip_item.enabled = NO;
  toolbar_live_text_item.enabled = NO;
  toolbar_live_text_item.tintColor = UIColor.blackColor;

  /* Set the live text to a fixed width. */
  /* IOS_FIXME - should this be set dynamically? Need to move out of init if so. */
  toolbar_live_text_item.width = 150.0f;

  toolbar.items = @[
    toolbar_tip_item,
    toolbar_live_text_item,
    toolbar_done_editing_item,
    toolbar_cancel_editing_item
  ];
}

- (void)generateKeyboardReturnEvent
{
  /*
   Only push the event back if the keyboard is active otherwise we may generate new
   spurious events.
   */
  if (onscreen_keyboard_active) {
    /*
     This event should cause ui_textedit_end() to be called which will
     hide the keyboard.
     */
    system->pushEvent(new GHOST_EventKey(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                                         GHOST_kEventKeyDown,
                                         window,
                                         GHOST_kKeyEnter,
                                         false,
                                         nullptr));
  }
  else {
    IOS_INPUT_LOG(@"Ignoring handleKeyboardReturn %@", text_field.text);
  }
}

- (void)handleKeyboardReturn:(UITextField *)text_field
{
  @synchronized(self) {
    IOS_INPUT_LOG(@"handleKeyboardReturn %@", text_field.text);
    [self generateKeyboardReturnEvent];
  }
}

- (void)handleKeyboardEditChange:(UITextField *)text_field
{
  @synchronized(self) {

    /* Update the text in the tool bar as the edits arrive. */
    if (toolbar_live_text_item) {
      toolbar_live_text_item.title = text_field.text;
      /* Force toolbar to update */
      [toolbar setNeedsLayout];
      [toolbar layoutIfNeeded];
    }
    IOS_INPUT_LOG(@"Keyboard Edit change detected %@", text_field.text);

    /* IOS_FIXME - Enabling this will propogate text changes back into the Blender text field
     as they happen. Since pushing back individual key presses appears to be difficult this
     might be the best we can do. However this currently causes a segmentation fault if you delete
     text as the Blender-side string ends up being NULL in some cases. */
    bool push_edits_back_to_blender = false;

    if (push_edits_back_to_blender) {
      system->pushEvent(new GHOST_EventKey(GHOST_GetMilliSeconds((GHOST_SystemHandle)system),
                                           GHOST_kEventKeyDown,
                                           window,
                                           GHOST_kKeyTextEdit,
                                           false,
                                           nullptr));
    }
  }
}

- (void)handleKeyboardEditBegin:(UITextField *)text_field
{
  @synchronized(self) {
    IOS_INPUT_LOG(@"Keyboard Edit begin detected %@", text_field.text);
  }
}

- (void)handleKeyboardEditEnd:(UITextField *)text_field
{
  @synchronized(self) {
    /*
     This can get called when the keyboard is minimised
     so send a return keypress to emulate effective end
     of editing. Otherwise Blender's focus will remain
     on the text field.
     */
    IOS_INPUT_LOG(@"Keyboard Edit end detected %@", text_field.text);
    [self generateKeyboardReturnEvent];
  }
}

- (void)handleDoneButton
{
  IOS_INPUT_LOG(@"Keyboard Done button press detected %@", text_field.text);
  [self generateKeyboardReturnEvent];
}

- (void)handleCancelButton
{
  IOS_INPUT_LOG(@"Keyboard Cancel button press detected %@", text_field.text);
  /* Restore the original text and return */
  text_field.text = original_text;
  [self generateKeyboardReturnEvent];
}

/*
 * Add a text field so we can handle input from a popup keyboard and
 * attach it to our root window.
 */
- (void)initUITextField
{
  /* Initialise it if we have not already done so. */
  if (!text_field) {
    text_field = [[UITextField alloc] init];

    text_field.contentScaleFactor = window->getWindowScaleFactor();

    if (toolbar_enabled) {
      [self initToolbar];
      text_field.inputAccessoryView = toolbar;
    }

    [window->rootWindow addSubview:text_field];

    /* Add a handler for when 'return' is pressed on keyboard. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardReturn:)
         forControlEvents:UIControlEventEditingDidEndOnExit];

    /* Add a handler for when the text field changes. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardEditChange:)
         forControlEvents:UIControlEventEditingChanged];

    /* Add a handler for when user edits a text field. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardEditBegin:)
         forControlEvents:UIControlEventEditingDidBegin];

    /* Add a handler for when user finishes editing a text field. */
    [text_field addTarget:self
                   action:@selector(handleKeyboardEditEnd:)
         forControlEvents:UIControlEventEditingDidEnd];
  }
}

- (void)convertWindowCoordToDisplayCoordWithWindow:(int)windowX
                                           windowY:(int)windowY
                                          displayX:(double *)displayX
                                          displayY:(double *)displayY
                                             flipY:(BOOL)flipY
{
  float pixelScale = window->getWindowScaleFactor();
  CGSize logicalWindowSize = window->getLogicalWindowSize();

  *displayX = (double)windowX / pixelScale;
  *displayY = (double)windowY / pixelScale;

  if (flipY) {
    *displayY = logicalWindowSize.height - *displayY;
  }
}

- (UITextField *)getUITextField
{
  return text_field;
}

- (void)setupKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties
{
  /* Initialise it if we have not already done so */
  if (!text_field) {
    [self initUITextField];
  }

  /* Save this set of keyboard properties */
  current_keyboard_properties = keyboard_properties;

  /* Convert the text box coords to display coords */
  CGRect displayRect;
  [self convertWindowCoordToDisplayCoordWithWindow:keyboard_properties.text_box_origin[0]
                                           windowY:keyboard_properties.text_box_origin[1]
                                          displayX:&displayRect.origin.x
                                          displayY:&displayRect.origin.y
                                             flipY:true];

  [self convertWindowCoordToDisplayCoordWithWindow:keyboard_properties.text_box_size[0]
                                           windowY:keyboard_properties.text_box_size[1]
                                          displayX:&displayRect.size.width
                                          displayY:&displayRect.size.height
                                             flipY:false];

  /* Where to display the text on-screen. */
  text_field.frame = displayRect;

  /* Initialise text with existing string. */
  text_field.text = keyboard_properties.text_string ?
                        [NSString stringWithUTF8String:keyboard_properties.text_string] :
                        @"";
  /* Take a copy of the string so we can restore it if neccessary */
  original_text = keyboard_properties.text_string ?
                      [NSString stringWithUTF8String:keyboard_properties.text_string] :
                      @"";

  /* Set keyboard type and text alignment.
   * NOTE - the keyboard type is only honoured if using an Apple
   * pencil or if the keyboard is floating.
   * Otherwise it will just be the default full screen type. */
  switch (keyboard_properties.keyboard_type) {
    case GHOST_KeyboardProperties::ascii_keyboard_type: {
      text_field.keyboardType = UIKeyboardTypeASCIICapable;
      text_field.textAlignment = NSTextAlignmentLeft;
      break;
    }
    case GHOST_KeyboardProperties::decimal_numpad_keyboard_type: {
      text_field.keyboardType = UIKeyboardTypeDecimalPad;
      text_field.textAlignment = NSTextAlignmentCenter;
      break;
    }
    case GHOST_KeyboardProperties::numpad_keyboard_type: {
      text_field.keyboardType = UIKeyboardTypeNumberPad;
      text_field.textAlignment = NSTextAlignmentCenter;
      break;
    }
    default: {
      /* What's the sensible baviour here? Default? Assert? */
      text_field.keyboardType = UIKeyboardTypeDefault;
      text_field.textAlignment = NSTextAlignmentLeft;
    }
  }
  /* Reset keyboard type to default if not using Apple Pencil
   * or it's not floating. (Need to add floating detection.) */
  if (!last_tap_with_pencil) {
    // text_field.keyboardType = UIKeyboardTypeDefault;
  }

  /* Set light/dark mode or adopt system default. */
  text_field.keyboardAppearance = UIKeyboardAppearanceDefault;

  /* This seems sensible given Blender's typical behaviour. */
  text_field.autocorrectionType = UITextAutocorrectionTypeNo;
  text_field.spellCheckingType = UITextSpellCheckingTypeNo;

  /* Set font size. */
  float fontSize = keyboard_properties.font_size / window->getWindowScaleFactor();
  text_field.font = [UIFont systemFontOfSize:fontSize];

  /* Set font color. */
  text_field.textColor = [UIColor colorWithRed:keyboard_properties.font_color[0]
                                         green:keyboard_properties.font_color[1]
                                          blue:keyboard_properties.font_color[2]
                                         alpha:keyboard_properties.font_color[3]];

  /* Initial highlighting and text-cursor position. */
  switch (keyboard_properties.inital_text_state) {
    case GHOST_KeyboardProperties::select_all_text: {
      [text_field selectAll:nil];
      break;
    }
    case GHOST_KeyboardProperties::select_text_range: {
      UITextPosition *startPosition = [text_field
          positionFromPosition:text_field.beginningOfDocument
                        offset:keyboard_properties.text_select_range[0]];
      UITextPosition *endPosition = [text_field
          positionFromPosition:text_field.beginningOfDocument
                        offset:keyboard_properties.text_select_range[1]];
      text_field.selectedTextRange = [text_field textRangeFromPosition:startPosition
                                                            toPosition:endPosition];
      break;
    }
    case GHOST_KeyboardProperties::move_cursor_to_start: {
      UITextPosition *beginning = text_field.beginningOfDocument;
      text_field.selectedTextRange = [text_field textRangeFromPosition:beginning
                                                            toPosition:beginning];
      break;
    }
    case GHOST_KeyboardProperties::move_cursor_to_end: {
      UITextPosition *end = text_field.endOfDocument;
      text_field.selectedTextRange = [text_field textRangeFromPosition:end toPosition:end];
      break;
    }
    default: {
      GHOST_ASSERT(FALSE, "GHOST_SystemIOS::setupTextField unsupported text select option");
    }
  }

  /* Setup the tool bar if it's enabled. */
  if (toolbar_enabled) {
    toolbar_live_text_item.title = text_field.text;
    toolbar_tip_item.title = keyboard_properties.tip_text ?
                                 [NSString stringWithCString:keyboard_properties.tip_text
                                                    encoding:NSUTF8StringEncoding] :
                                 @"";
  }
}

- (void)externalKeyboardChange:(NSNotification *)notification
{
  external_keyboard_connected = [GCKeyboard coalescedKeyboard] != nil;
  IOS_INPUT_LOG(@"External Keyboard %s",
                external_keyboard_connected ? "Connected" : "Disconnected");
}

/* IOS_FIXME - Not currently used, could be removed. */
- (void)keyboardWillChange:(NSNotification *)notification
{

  CGRect keyboardRect = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
  /* Sometimes we see a zero value for the end-frame value, possibly because... timing? */
  if (keyboardRect.size.width == 0 || keyboardRect.size.height == 0) {
    keyboardRect = [notification.userInfo[UIKeyboardFrameBeginUserInfoKey] CGRectValue];
  }
}

- (const GHOST_TabletData)getTabletData
{
  return tablet_data;
}

- (GHOST_TSuccess)popupOnscreenKeyboard:(const GHOST_KeyboardProperties &)keyboard_properties
{
  @synchronized(self) {
    IOS_INPUT_LOG(@"Keyboard popup request received %@", text_field.text);
    [self setupKeyboard:keyboard_properties];

    if (!onscreen_keyboard_active) {
      text_field.userInteractionEnabled = YES;
      if (![text_field becomeFirstResponder]) {
        GHOST_ASSERT(FALSE, "GHOST_SystemIOS::popupOnScreenKeyboard Failed to display keyboard");
      }
      onscreen_keyboard_active = true;
    }
  }
  return GHOST_kSuccess;
}

- (GHOST_TSuccess)hideOnscreenKeyboard
{
  /* Lock access around keyboard handling events. */
  @synchronized(self) {
    IOS_INPUT_LOG(@"Keyboard hide request received %@", text_field.text);

    if (onscreen_keyboard_active) {
      /*
       This must come first so that any of the keyboard event handlers that get
       triggered in response to shutting down the keyboard don't do anything
       (like generating events back to Blender)
       */
      onscreen_keyboard_active = false;

      /* Shut down the keyboard. */
      [text_field resignFirstResponder];
      /*
       IOS_FIXME - Note: This may cause the console to display the warning message:
       "-[UIApplication _touchesEvent] will no longer work as expected. Please stop using it."
       But since this is being generated by Apple OS code there's nothing obvious to fix it right
       now.
       */

      IOS_INPUT_LOG(@"Resigned keyboard responder");
      /*
       This is required to disable any subsequent interactions with the text field that could
       potentially bypass Blender's input handling (since the UITextField is now live
       on the view)
       */
      text_field.userInteractionEnabled = NO;

      /* Save the input to a c-string */
      text_field_string = [[text_field text] UTF8String];

      /* Delete the text field copy of the string */
      text_field.text = nil;
    }
  }
  IOS_INPUT_LOG(@"Text field value was %s", text_field_string);
  return GHOST_kSuccess;
}

- (const char *)getLastKeyboardString
{
  /* Lock access around keyboard handling events */
  @synchronized(self) {

    /* Update text string if one exists */
    if (text_field.text && ![text_field.text isEqualToString:@""]) {
      /* Save the input to a c-string */
      text_field_string = [[text_field text] UTF8String];
    }
  }
  return text_field_string;
}

@end

@interface GHOST_IOSViewController : UIViewController

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView;
- (void)updateDrawableSizeSafely;

@end

@implementation GHOST_IOSViewController
{
  MTKView *_view;
  GHOST_IOSMetalRenderer *_renderer;
}

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
{
  _view = mtkView;
  _view.multipleTouchEnabled = YES;
  self = [super init];
  self.view = (UIView *)mtkView;

  return self;
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  _view = (MTKView *)self.view;
  _view.enableSetNeedsDisplay = NO;
  _view.device = MTLCreateSystemDefaultDevice();
  _view.clearColor = MTLClearColorMake(0, 0, 0, 1.0);
  _view.paused = NO;
  _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
  _view.autoResizeDrawable = NO;
  _view.contentMode = UIViewContentModeScaleToFill;
  _view.contentScaleFactor = [[UIScreen mainScreen] scale];
  [self updateDrawableSizeSafely];
  /* Set the refresh rate to the screen's maximum. There may be some value in capping
   * this value to preserve battery life (60fps seems to work well). */
  _view.preferredFramesPerSecond = [UIScreen mainScreen].maximumFramesPerSecond;
  _renderer = [[GHOST_IOSMetalRenderer alloc] initWithMetalKitView:_view];
  if (!_renderer) {
    NSLog(@"Renderer initialization failed");
    return;
  }

  [_renderer mtkView:_view drawableSizeWillChange:_view.drawableSize];

  _view.delegate = _renderer;
}

- (void)viewDidLayoutSubviews
{
  [super viewDidLayoutSubviews];
  [self updateDrawableSizeSafely];
}

- (void)updateDrawableSizeSafely
{
  CGFloat scale = _view.contentScaleFactor;
  if (!isfinite(scale) || scale <= 0.0f) {
    scale = [[UIScreen mainScreen] scale];
  }
  if (!isfinite(scale) || scale <= 0.0f) {
    scale = 1.0f;
  }

  CGSize bounds = _view.bounds.size;
  if (!isfinite(bounds.width) || bounds.width <= 0.0f || !isfinite(bounds.height) ||
      bounds.height <= 0.0f)
  {
    bounds = [UIScreen mainScreen].bounds.size;
  }
  if (!isfinite(bounds.width) || bounds.width <= 0.0f || !isfinite(bounds.height) ||
      bounds.height <= 0.0f)
  {
    bounds = CGSizeMake(1280.0f, 720.0f);
  }

  _view.drawableSize = CGSizeMake(bounds.width * scale, bounds.height * scale);
}

- (void)handleGesture:(UIGestureRecognizer *)gestureRecognizer
{
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
  /* Make the Home Indicator (the bottom-center white navigation bar) auto-hide when possible. */
  return YES;
}

@end

GHOST_WindowIOS::GHOST_WindowIOS(GHOST_SystemIOS *system_ios,
                                 const char *title,
                                 int32_t left,
                                 int32_t bottom,
                                 uint32_t width,
                                 uint32_t height,
                                 GHOST_TWindowState state,
                                 GHOST_TDrawingContextType type,
                                 const GHOST_ContextParams &context_params,
                                 bool /*is_dialog*/,
                                 GHOST_WindowIOS *parent_window)
    : GHOST_Window(width, height, state, context_params, false), metal_view_(nil)
{
  full_screen_ = false;
  system_ios_ = system_ios;
  /* Parent window will be the window that focus is returned to upon close. */
  parent_window_ = parent_window;
  window_title_ = nullptr;

  /* Create MTKView. */
  metal_view_ = [[MTKView alloc] initWithFrame:CGRectMake(left, bottom, width, height)];
  [metal_view_ retain];
  GHOST_ASSERT(metal_view_, "metalview not valid");

  /* Create view controller. */
  UIApplication *app = [UIApplication sharedApplication];
  GHOST_ASSERT(app, "App not valid");
  id<UIApplicationDelegate> app_delegate = [app delegate];
  GHOST_ASSERT(app_delegate, "App not valid");

  GHOSTUIWindow *ghost_rootWindow = nullptr;

  if (full_screen_) {
    /* Init window at native res. */
    ghost_rootWindow = [[GHOSTUIWindow alloc] init];
    [ghost_rootWindow retain];
    /* Ensure fullscreen. */
    CGRect rect = [UIScreen mainScreen].bounds;
    rootWindow.frame = rect;
  }
  else {
    /* Init window at specified size. */
    ghost_rootWindow = [[GHOSTUIWindow alloc]
        initWithFrame:CGRectMake(left, bottom, width, height)];
    [ghost_rootWindow retain];
    [ghost_rootWindow setClipsToBounds:YES];
  }

  rootWindow = (UIWindow *)ghost_rootWindow;

  /* iOS 13+ routes events through UIWindowScene. Bind explicitly for stability. */
  if (@available(iOS 13.0, *)) {
    if (rootWindow.windowScene == nil) {
      for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
          continue;
        }
        UIWindowScene *window_scene = (UIWindowScene *)scene;
        if (window_scene.activationState == UISceneActivationStateForegroundActive ||
            window_scene.activationState == UISceneActivationStateForegroundInactive)
        {
          rootWindow.windowScene = window_scene;
          IOS_WINDOW_LOG(@"[iOS input] bound windowScene=%@", window_scene);
          break;
        }
      }
      if (rootWindow.windowScene == nil) {
        IOS_WINDOW_LOG(@"[iOS input] warning: no UIWindowScene bound");
      }
    }
  }

  [ghost_rootWindow setSystemAndWindowIOS:system_ios_ windowIOS:this];
  rootWindow.windowLevel = UIWindowLevelNormal;

  GHOST_ASSERT(rootWindow, "UIWindow not valid");
  uiview_controller_ = [[[GHOST_IOSViewController alloc] initWithMetalKitView:metal_view_] retain];
  [uiview_controller_ viewDidLoad];
  GHOST_ASSERT(uiview_controller_, "UIViewController not valid");

  /* Set presentation style depending on whether main window, dialog or temporary window. */
  if (full_screen_) {
    /* Initial window has no parent and is always fullscreen. */
    uiview_controller_.modalPresentationStyle = UIModalPresentationFullScreen;
  }
  else {
    /* Initial window has no parent and is always fullscreen. */
    uiview_controller_.modalPresentationStyle = UIModalPresentationPageSheet;
  }
  rootWindow.rootViewController = uiview_controller_;

  /* Create UIView */
  GHOST_ASSERT(width > 0 && height > 0, "invalid wh");
  uiview_ = uiview_controller_.view;
  GHOST_ASSERT(uiview_, "uiview not valid");

  /* Initialize Metal device. */
  metal_view_.device = MTLCreateSystemDefaultDevice();

  /* Enable HDR/EDR Support. */
  CAMetalLayer *metalLayer = (CAMetalLayer *)metal_view_.layer;
  metalLayer.wantsExtendedDynamicRangeContent = YES;
  metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
  CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
  metalLayer.colorspace = colorspace;
  CGColorSpaceRelease(colorspace);

  setDrawingContextType(type);
  updateDrawingContext();
  activateDrawingContext();

  setTitle(title);

  /* Gesture recognizers. */
  [ghost_rootWindow registerGestureRecognizers];

  deferred_swap_buffers_count = 0;

  /* Deactive the parent (if it exists) and activate this one. */
  if (parent_window_) {
    parent_window_->requestToDeactivateWindow();
  }

  /* Make it the key window if there is no other window.
   * (Otherwise there will never be a call to drawInMTKView) */
  if (!system_ios_->current_active_window_) {
    request_to_make_active_ = true;
    makeKeyWindow();
  }
  /* Activate this window at the end of the next draw loop. */
  else {
    requestToActivateWindow();
  }
}

GHOST_WindowIOS::~GHOST_WindowIOS()
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  releaseNativeHandles();

  /* Restore application control and display to parent window. */
  if (parent_window_) {
    parent_window_->requestToActivateWindow();
    parent_window_ = nil;
  }
  /* We have no choice but to resign, however this seems like it might cause issues. */
  if (system_ios_->current_active_window_ == this) {
    IOS_WINDOW_LOG(@"~GHOST_WindowIOS(): Warning, deactivating the active window %p?", this);
    requestToDeactivateWindow();
    resignKeyWindow();
  }

  if (metal_view_) {
    metal_view_.delegate = nil;
    [metal_view_ release];
    metal_view_ = nil;
  }
  if (uiview_) {
    [uiview_ release];
    uiview_ = nil;
  }

  /* Release window. */
  if (rootWindow) {
    [rootWindow release];
    rootWindow = nil;
  }
  if (uiview_controller_) {
    [uiview_controller_ release];
    uiview_controller_ = nil;
  }

  if (window_title_) {
    free(window_title_);
    window_title_ = nullptr;
  }

  [pool drain];
}

#pragma mark accessors

bool GHOST_WindowIOS::getValid() const
{
  MTKView *view = metal_view_;
  return GHOST_Window::getValid() && uiview_ != NULL && view != NULL;
}

void *GHOST_WindowIOS::getOSWindow() const
{
  return (void *)uiview_;
}

GHOST_TSuccess GHOST_WindowIOS::swapBuffers()
{
  deferred_swap_buffers_count++;
  return GHOST_kSuccess;
}

void GHOST_WindowIOS::flushDeferredSwapBuffers()
{
  if (deferred_swap_buffers_count) {

    /* These two messages should be made asserts when we've fixed all the issues. */
    if (!getValid()) {
      IOS_WINDOW_LOG(@"Ignoring swap (invalid) con(%p) (win=%p)", getContext(), this);
      return;
    }

    if (!is_active_window_) {
      IOS_WINDOW_LOG(@"Ignoring swap (not active window) con(%p) (win=%p)", getContext(), this);
      return;
    }

    IOS_WINDOW_LOG(@"Swapping (ui_View)%p (mtkView)%p con(%p) (win=%p) (sc=%d)",
                   uiview_,
                   metal_view_,
                   getContext(),
                   this,
                   deferred_swap_buffers_count);

    GHOST_ContextIOS *context = reinterpret_cast<GHOST_ContextIOS *>(getContext());
    context->swapBuffers();
    deferred_swap_buffers_count = 0;
  }
}

void GHOST_WindowIOS::beginFrame()
{
  const bool reactivation_tick = system_ios_ && system_ios_->consumeInputReactivationTick();
  if (rootWindow) {
    rootWindow.hidden = NO;
    rootWindow.userInteractionEnabled = YES;
    if (reactivation_tick) {
      [(GHOSTUIWindow *)rootWindow resetInputStateForActivation];
      [(GHOSTUIWindow *)rootWindow ensureFirstResponderDebounced:(reactivation_tick ?
                                                                      @"beginFrame(reactivation)" :
                                                                      @"beginFrame(key-refresh)")];
    }
  }
  if (uiview_) {
    uiview_.userInteractionEnabled = YES;
    uiview_.multipleTouchEnabled = YES;
  }
  if (metal_view_) {
    metal_view_.paused = NO;
    metal_view_.userInteractionEnabled = YES;
    metal_view_.multipleTouchEnabled = YES;
  }
  GHOSTUIWindow *ui_window = (GHOSTUIWindow *)rootWindow;
  [ui_window beginFrame];
}

void GHOST_WindowIOS::endFrame()
{
  GHOSTUIWindow *ui_window = (GHOSTUIWindow *)rootWindow;
  [ui_window endFrame];
}

void GHOST_WindowIOS::setTitle(const char *title)
{
  if (window_title_) {
    free(window_title_);
    window_title_ = nullptr;
  }
  window_title_ = (char *)malloc(strlen(title) + 1);
  if (!window_title_) {
    GHOST_ASSERT(getValid(), "GHOST_WindowIOS::setTitle(): Failed to alloc mem for window title");
  }
  strcpy(window_title_, title);
  NSString *window_title = [NSString stringWithCString:title encoding:NSUTF8StringEncoding];
  uiview_controller_.title = window_title;
}

std::string GHOST_WindowIOS::getTitle() const
{
  return window_title_;
}

void GHOST_WindowIOS::needsDisplayUpdate()
{
  [uiview_ setNeedsDisplay];
}

void GHOST_WindowIOS::getWindowBounds(GHOST_Rect &bounds) const
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::getWindowBounds(): window invalid");

  CGRect screenRect = rootWindow.frame;
  CGFloat scale = [UIScreen mainScreen].scale;
  CGFloat screenWidth = screenRect.size.width * scale;
  CGFloat screenHeight = screenRect.size.height * scale;

  bounds.b_ = screenHeight;
  bounds.l_ = rootWindow.frame.origin.x;
  bounds.r_ = screenWidth;
  bounds.t_ = rootWindow.frame.origin.y;
}

void GHOST_WindowIOS::getClientBounds(GHOST_Rect &bounds) const
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::getWindowBounds(): window invalid");

  CGRect screenRect = rootWindow.frame;
  CGFloat scale = [UIScreen mainScreen].scale;
  CGFloat screenWidth = screenRect.size.width * scale;
  CGFloat screenHeight = screenRect.size.height * scale;

  bounds.b_ = screenHeight;
  bounds.l_ = 0;
  bounds.r_ = screenWidth;
  bounds.t_ = 0;
}

GHOST_TSuccess GHOST_WindowIOS::setClientWidth(uint32_t /*width*/)
{
  /* Ignore on iOS fow now. */
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setClientHeight(uint32_t /*height*/)
{
  /* Ignore on iOS fow now. */
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setClientSize(uint32_t /*width*/, uint32_t /*height*/)
{
  /* Ignore on iOS fow now. */
  return GHOST_kSuccess;
}

GHOST_TWindowState GHOST_WindowIOS::getState() const
{
  /* TODO: Implement. */
  return GHOST_kWindowStateNormal;
}

void GHOST_WindowIOS::screenToClient(int32_t inX, int32_t inY, int32_t &outX, int32_t &outY) const
{
  /* Pass through for fullscreen windows.
   * TODO: Support coordinate mapping for sized windows. */
  outX = inX;
  outY = inY;
}

void GHOST_WindowIOS::clientToScreen(int32_t inX, int32_t inY, int32_t &outX, int32_t &outY) const
{
  /* Pass through for fullscreen windows.
   * TODO: Support coordinate mapping for sized windows. */
  outX = inX;
  outY = inY;
}

void GHOST_WindowIOS::screenToClientIntern(int32_t inX,
                                           int32_t inY,
                                           int32_t &outX,
                                           int32_t &outY) const
{
  /* Pass through for fullscreen windows.
   * TODO: Support coordinate mapping for sized windows. */
  outX = inX;
  outY = inY;
}

void GHOST_WindowIOS::clientToScreenIntern(int32_t inX,
                                           int32_t inY,
                                           int32_t &outX,
                                           int32_t &outY) const
{
  /* Pass through for fullscreen windows.
   * TODO: Support coordinate mapping for sized windows. */
  outX = inX;
  outY = inY;
}

/* called for event, when window leaves monitor to another */
void GHOST_WindowIOS::setNativePixelSize(void) {}

/**
 * \note Fullscreen switch is not actual fullscreen with display capture.
 * As this capture removes all OS X window manager features.
 *
 * Instead, the menu bar and the dock are hidden, and the window is made border-less and
 * enlarged. Thus, process switch, exposé, spaces, ... still work in fullscreen mode
 */
GHOST_TSuccess GHOST_WindowIOS::setState(GHOST_TWindowState /*state*/)
{
  // Ignore on iOS?
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setModifiedState(bool isUnsavedChanges)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  [pool drain];
  return GHOST_Window::setModifiedState(isUnsavedChanges);
}

GHOST_TSuccess GHOST_WindowIOS::setOrder(GHOST_TWindowOrder /*order*/)
{
  /* TODO: Support or deprecate for iOS */
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::setOrder(): window invalid");

  [pool drain];
  return GHOST_kSuccess;
}

#pragma mark Drawing context

GHOST_Context *GHOST_WindowIOS::newDrawingContext(GHOST_TDrawingContextType type)
{

  if (type == GHOST_kDrawingContextTypeMetal) {

    GHOST_Context *context = new GHOST_ContextIOS(want_context_params_, uiview_, metal_view_);

    if (context->initializeDrawingContext())
      return context;
    else
      delete context;
  }

  return NULL;
}

#pragma mark invalidate

GHOST_TSuccess GHOST_WindowIOS::invalidate()
{
  GHOST_ASSERT(getValid(), "GHOST_WindowIOS::invalidate(): window invalid");
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  [pool drain];
  return GHOST_kSuccess;
}

#pragma mark Progress bar

GHOST_TSuccess GHOST_WindowIOS::setProgressBar(float /*progress*/)
{
  return GHOST_kSuccess;
}

static void postNotification() {}

GHOST_TSuccess GHOST_WindowIOS::endProgressBar()
{
  return GHOST_kSuccess;
}

#pragma mark Cursor handling

void GHOST_WindowIOS::loadCursor(bool /*visible*/, GHOST_TStandardCursor /*shape*/) const {}

bool GHOST_WindowIOS::isDialog() const
{
  return is_dialog_;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCursorVisibility(bool /*visible*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCursorGrab(GHOST_TGrabCursorMode /*mode*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCursorShape(GHOST_TStandardCursor /*shape*/)
{
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_WindowIOS::hasCursorShape(GHOST_TStandardCursor /*shape*/)
{
  return GHOST_kSuccess;
}

/** Reverse the bits in a uint16_t */
static uint16_t uns16ReverseBits(uint16_t shrt)
{
  shrt = ((shrt >> 1) & 0x5555) | ((shrt << 1) & 0xAAAA);
  shrt = ((shrt >> 2) & 0x3333) | ((shrt << 2) & 0xCCCC);
  shrt = ((shrt >> 4) & 0x0F0F) | ((shrt << 4) & 0xF0F0);
  shrt = ((shrt >> 8) & 0x00FF) | ((shrt << 8) & 0xFF00);
  return shrt;
}

GHOST_TSuccess GHOST_WindowIOS::setWindowCustomCursorShape(const uint8_t * /*bitmap*/,
                                                           const uint8_t * /*mask*/,
                                                           const int /*size*/[2],
                                                           const int /*hot_spot*/[2],
                                                           bool /*canInvertColor*/)
{
  /* Passthrough for iOS. */
  return GHOST_kSuccess;
}

uint16_t GHOST_WindowIOS::getDPIHint()
{
  return 288;
}

GHOST_TSuccess GHOST_WindowIOS::popupOnscreenKeyboard(
    const GHOST_KeyboardProperties &keyboard_properties)
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow popupOnscreenKeyboard:keyboard_properties];
}

GHOST_TSuccess GHOST_WindowIOS::hideOnscreenKeyboard()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow hideOnscreenKeyboard];
}

const char *GHOST_WindowIOS::getLastKeyboardString()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow getLastKeyboardString];
}

UITextField *GHOST_WindowIOS::getUITextField()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow getUITextField];
}

const GHOST_TabletData GHOST_WindowIOS::getTabletData()
{
  GHOSTUIWindow *ghost_rootWindow = (GHOSTUIWindow *)rootWindow;
  return [ghost_rootWindow getTabletData];
}

/* This is the size of the window pre-scaled */
CGSize GHOST_WindowIOS::getLogicalWindowSize()
{
  return metal_view_.frame.size;
}

/* This is the size of the window post-scaled */
CGSize GHOST_WindowIOS::getNativeWindowSize()
{
  return metal_view_.drawableSize;
}

float GHOST_WindowIOS::getWindowScaleFactor()
{
  return [[UIScreen mainScreen] scale];
}

/* Indicate that we want this window to be the next active one. */
void GHOST_WindowIOS::requestToActivateWindow()
{
  /* Check we're not already active. */
  if (system_ios_->current_active_window_ != this) {
    /* Replace any outstanding requests. */
    if (system_ios_->next_active_window_) {
      system_ios_->next_active_window_->requestToDeactivateWindow();
    }
    request_to_make_active_ = true;
    system_ios_->next_active_window_ = this;
  }
}

void GHOST_WindowIOS::requestToDeactivateWindow()
{
  if (system_ios_->next_active_window_ == this) {
    IOS_WINDOW_LOG(@"requestToDeactivateWindow(): Has something gone wrong? %p", this);
    system_ios_->next_active_window_ = nullptr;
  }
  request_to_make_active_ = false;
}

bool GHOST_WindowIOS::makeKeyWindow()
{
  if (!getValid()) {
    IOS_WINDOW_LOG(@"Failed to activate (invalid) con(%p) (win=%p)", getContext(), this);
    return false;
  }
  if (rootWindow && rootWindow.isKeyWindow && is_active_window_) {
    rootWindow.hidden = NO;
    rootWindow.userInteractionEnabled = YES;
    metal_view_.paused = NO;
    metal_view_.userInteractionEnabled = YES;
    metal_view_.multipleTouchEnabled = YES;
    return true;
  }

  GHOST_ContextIOS *context = reinterpret_cast<GHOST_ContextIOS *>(getContext());
  GHOST_ASSERT(rootWindow != nil, "GHOST_WindowIOS::makeKeyWindow() root window required");
  GHOST_ASSERT(context != nullptr, "GHOST_WindowIOS::makeKeyWindow() context required");
#if !defined(WITH_APPLE_CROSSPLATFORM)
  GHOST_ASSERT(request_to_make_active_,
               "GHOST_WindowIOS::makeKeyWindow() must request activation first");
#else
  /* iOS app lifecycle callbacks can reactivate window without prior request flag. */
  if (!request_to_make_active_) {
    request_to_make_active_ = true;
  }
#endif

  /* Make window primary visible window. */
  [rootWindow makeKeyAndVisible];
  rootWindow.hidden = NO;
  rootWindow.userInteractionEnabled = YES;
  [(GHOSTUIWindow *)rootWindow ensureFirstResponderDebounced:@"makeKeyWindow"];
  /* Enable the drawInMTKView() calls for this window. */
  metal_view_.paused = NO;
  metal_view_.userInteractionEnabled = YES;
  metal_view_.multipleTouchEnabled = YES;

  IOS_WINDOW_LOG(@"Key Window: (ui_View)%p (mtkView)%p con(%p) (win=%p)",
                 uiview_,
                 metal_view_,
                 getContext(),
                 this);

  system_ios_->current_active_window_ = this;
  is_active_window_ = true;
  request_to_make_active_ = false;
  return true;
}

void GHOST_WindowIOS::resignKeyWindow()
{
  GHOST_ASSERT(system_ios_->current_active_window_ == this,
               "GHOST_WindowIOS::resignKeyWindow(): Can only resign current active window");
  GHOST_ASSERT(is_active_window_,
               "GHOST_WindowIOS::resignKeyWindow(): Can't resign non active window");
  GHOST_ASSERT(!request_to_make_active_,
               "GHOST_WindowIOS::resignKeyWindow(): activation request outstanding");

  /* Disable the drawInMTKView() calls for this window. */
  metal_view_.paused = YES;
  /* Avoid blocking wait on main thread during scene transitions. */
  if (uiview_controller_.beingPresented) {
    IOS_WINDOW_LOG(@"resignKeyWindow(): controller still presenting, skip blocking wait");
  }
  IOS_WINDOW_LOG(@"Resigning Key Window: (ui_View)%p (mtkView)%p con(%p) (win=%p)",
                 uiview_,
                 metal_view_,
                 getContext(),
                 this);
  is_active_window_ = false;
  system_ios_->current_active_window_ = nullptr;
}

CGPoint GHOST_WindowIOS::scalePointToWindow(CGPoint &point)
{
  CGPoint scaled_point = point;

  CGSize logical_size = CGSizeZero;
  if (metal_view_ != nil) {
    logical_size = metal_view_.bounds.size;
  }
  if (logical_size.width <= 0.0f || logical_size.height <= 0.0f) {
    logical_size = getLogicalWindowSize();
  }
  const CGSize native_size = getNativeWindowSize();

  /* Use actual drawable/frame ratio to avoid UIKit-point vs pixel mismatches. */
  if (logical_size.width > 0.0f && logical_size.height > 0.0f && native_size.width > 0.0f &&
      native_size.height > 0.0f)
  {
    scaled_point.x = point.x * (native_size.width / logical_size.width);
    scaled_point.y = point.y * (native_size.height / logical_size.height);
  }
  else {
    const float scale = getWindowScaleFactor();
    scaled_point.x = point.x * scale;
    scaled_point.y = point.y * scale;
  }

  return scaled_point;
}

#ifdef WITH_INPUT_IME
void GHOST_WindowIOS::beginIME(
    int32_t /*x*/, int32_t /*y*/, int32_t /*w*/, int32_t /*h*/, bool /*completed*/)
{
  /* Passthrough for iOS. */
}

void GHOST_WindowIOS::endIME()
{
  /* Passthrough for iOS. */
}
#endif /* WITH_INPUT_IME */
