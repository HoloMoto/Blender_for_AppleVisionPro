/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include "GHOST_SystemIOS.hh"

#include "GHOST_ContextIOS.hh"
#include "GHOST_WindowIOS.hh"

#include "GHOST_Debug.hh"
#include "GHOST_EventButton.hh"
#include "GHOST_EventCursor.hh"
#include "GHOST_EventDragnDrop.hh"
#include "GHOST_EventKey.hh"
#include "GHOST_EventString.hh"
#include "GHOST_WindowManager.hh"

#ifdef WITH_INPUT_NDOF
#  include "GHOST_NDOFManagerCocoa.hh"
#endif

#import <MetalKit/MTKView.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <sys/sysctl.h>
#include <sys/time.h>
#include <cstdio>
#include <string>

// #define IOS_SYSTEM_LOGGING
#if defined(IOS_SYSTEM_LOGGING)
#  define IOS_SYSTEM_LOG(...) NSLog(__VA_ARGS__)
#else
#  define IOS_SYSTEM_LOG(...)
#endif

extern "C" {
struct bContext;
static bContext *C = nullptr;
}

void wm_context_ensure_from_main(bContext *C);

int argc = 0;
const char **argv = nullptr;

/* Implemented in wm.cc. */
void WM_main_loop_body(bContext *C);
int main_ios_callback(int argc, const char **argv);

@interface IOSAppDelegate : UIResponder <UIApplicationDelegate>

@property(strong, nonatomic) UIWindow *window;

@end

@interface IOSSceneDelegate : UIResponder <UIWindowSceneDelegate>
@end

static UIWindowScene *g_ios_active_window_scene = nil;

static NSMutableDictionary<NSString *, NSURL *> *g_ios_security_scoped_urls = nil;

static void ios_register_security_scoped_url(NSURL *url)
{
  if (url == nil || !url.isFileURL) {
    return;
  }
  if (g_ios_security_scoped_urls == nil) {
    g_ios_security_scoped_urls = [[NSMutableDictionary alloc] init];
  }
  NSString *path = url.path;
  if (path.length > 0) {
    g_ios_security_scoped_urls[path] = url;
  }
}

static NSURL *ios_security_scoped_url_for_path(const char *filepath)
{
  if (filepath == nullptr || g_ios_security_scoped_urls == nil) {
    return nil;
  }
  NSString *path = [NSString stringWithUTF8String:filepath];
  return g_ios_security_scoped_urls[path];
}

struct IOSFilePickerState {
  GHOST_SystemIOS::IOSFilePickerCallback callback = nullptr;
  void *user_data = nullptr;
};

static IOSFilePickerState g_ios_file_picker_state;

static void ios_file_picker_finish(const char *path, bool cancelled)
{
  GHOST_SystemIOS::IOSFilePickerCallback callback = g_ios_file_picker_state.callback;
  void *user_data = g_ios_file_picker_state.user_data;
  g_ios_file_picker_state.callback = nullptr;
  g_ios_file_picker_state.user_data = nullptr;
  if (callback != nullptr) {
    callback(path, cancelled, user_data);
  }
}

@interface GHOST_IOSDocumentPickerDelegate : NSObject <UIDocumentPickerDelegate>
@end

@implementation GHOST_IOSDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
  (void)controller;
  NSURL *url = urls.firstObject;
  if (url == nil) {
    ios_file_picker_finish(nullptr, true);
    return;
  }
  ios_register_security_scoped_url(url);
  [url startAccessingSecurityScopedResource];
  NSString *resolved_path = url.path;
  if (@available(iOS 16.0, *)) {
    if (url.filePathURL != nil && url.filePathURL.path.length > 0) {
      resolved_path = url.filePathURL.path;
    }
  }
  ios_file_picker_finish(resolved_path.UTF8String, false);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
  (void)controller;
  ios_file_picker_finish(nullptr, true);
}

@end

static GHOST_IOSDocumentPickerDelegate *g_ios_picker_delegate = nil;

static UIViewController *ios_presenting_view_controller()
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

static UIViewController *ios_top_presenting_view_controller()
{
  UIViewController *vc = ios_presenting_view_controller();
  while (vc != nil && vc.presentedViewController != nil) {
    vc = vc.presentedViewController;
  }
  return vc;
}

static void ios_handle_incoming_document_url(NSURL *url)
{
  if (url == nil || url.path.length == 0) {
    return;
  }

  if (url.isFileURL) {
    ios_register_security_scoped_url(url);
    [url startAccessingSecurityScopedResource];
  }

  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());
  if (system == nullptr) {
    return;
  }

  system->handleOpenDocumentRequest((__bridge void *)url.path);
}

UIWindowScene *GHOST_IOS_GetActiveWindowScene()
{
  return g_ios_active_window_scene;
}

static BOOL g_ios_startup_started = NO;

static UIWindowScene *ghost_ios_pick_active_window_scene()
{
  if (@available(iOS 13.0, *)) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
      if (![scene isKindOfClass:[UIWindowScene class]]) {
        continue;
      }
      UIWindowScene *window_scene = (UIWindowScene *)scene;
      if (window_scene.activationState == UISceneActivationStateForegroundActive ||
          window_scene.activationState == UISceneActivationStateForegroundInactive)
      {
        return window_scene;
      }
    }
  }
  return nil;
}

static void ghost_ios_reactivate_window()
{
  static CFTimeInterval s_last_reactivation_time = 0.0;
  const CFTimeInterval now = CACurrentMediaTime();
  if ((now - s_last_reactivation_time) < 0.15) {
    return;
  }
  s_last_reactivation_time = now;

  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());
  if (system == nullptr) {
    return;
  }
  system->requestInputReactivation();

  if (system->current_active_window_ != nullptr) {
    GHOST_WindowIOS *win = system->current_active_window_;
    if (!win->isActiveKeyWindow()) {
      win->requestToActivateWindow();
      win->makeKeyWindow();
    }
    win->needsDisplayUpdate();
    return;
  }

  if (system->next_active_window_ != nullptr) {
    system->next_active_window_->requestToActivateWindow();
    system->next_active_window_->needsDisplayUpdate();
    return;
  }

  /* Fallback: reacquire focus for live GHOST UIWindow instances through UIKit. */
  NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
  for (UIWindow *ui_window in windows) {
    if (ui_window == nil) {
      continue;
    }
    const NSString *class_name = NSStringFromClass([ui_window class]);
    if (![class_name isEqualToString:@"GHOSTUIWindow"]) {
      continue;
    }
    if (@available(iOS 13.0, *)) {
      if (ui_window.windowScene == nil) {
        UIWindowScene *window_scene = ghost_ios_pick_active_window_scene();
        if (window_scene != nil) {
          ui_window.windowScene = window_scene;
        }
      }
    }
    ui_window.hidden = NO;
    ui_window.userInteractionEnabled = YES;
    [ui_window makeKeyAndVisible];
    if ([ui_window respondsToSelector:@selector(becomeFirstResponder)]) {
      [ui_window becomeFirstResponder];
    }
    UIViewController *root_vc = ui_window.rootViewController;
    if (root_vc && root_vc.view) {
      root_vc.view.userInteractionEnabled = YES;
      root_vc.view.multipleTouchEnabled = YES;
      for (UIView *subview in root_vc.view.subviews) {
        subview.userInteractionEnabled = YES;
        subview.multipleTouchEnabled = YES;
      }
    }
  }
}

static void ghost_ios_schedule_reactivation_burst()
{
  static const NSTimeInterval retry_delays[] = {0.0, 0.20, 0.60, 1.00};
  for (const NSTimeInterval delay : retry_delays) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{
                     ghost_ios_reactivate_window();
                   });
  }
}

@implementation IOSSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions
{
  (void)session;

  if ([scene isKindOfClass:[UIWindowScene class]]) {
    g_ios_active_window_scene = (UIWindowScene *)scene;
  }

  for (UIOpenURLContext *url_context in connectionOptions.URLContexts) {
    ios_handle_incoming_document_url(url_context.URL);
  }

  if (g_ios_startup_started) {
    fprintf(stderr, "[ios] scene willConnect ignored: startup already started\n");
    fflush(stderr);
    return;
  }
  g_ios_startup_started = YES;

  fprintf(stderr, "[ios] scene willConnect, starting main_ios_callback\n");
  fflush(stderr);
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      main_ios_callback(argc, argv);
      ghost_ios_schedule_reactivation_burst();
    }
    @catch (NSException *exception) {
      fprintf(stderr,
              "[ios] main_ios_callback exception: %s - %s\n",
              exception.name.UTF8String,
              exception.reason.UTF8String);
      fflush(stderr);
      g_ios_startup_started = NO;
    }
  });
}

- (void)sceneDidDisconnect:(UIScene *)scene
{
  (void)scene;
  if (g_ios_active_window_scene == scene) {
    g_ios_active_window_scene = nil;
  }
}

- (void)sceneDidBecomeActive:(UIScene *)scene
{
  (void)scene;
  ghost_ios_schedule_reactivation_burst();
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts
{
  (void)scene;
  for (UIOpenURLContext *url_context in URLContexts) {
    ios_handle_incoming_document_url(url_context.URL);
  }
}

@end

@implementation IOSAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  (void)application;
  (void)launchOptions;
  fprintf(stderr, "[ios] didFinishLaunchingWithOptions\n");
  fflush(stderr);

  [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                    object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification *note) {
                                                  (void)note;
                                                  ghost_ios_schedule_reactivation_burst();
                                                }];
  [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification *note) {
                                                  (void)note;
                                                  ghost_ios_schedule_reactivation_burst();
                                                }];
#if defined(__IPHONE_13_0)
  if (@available(iOS 13.0, *)) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneWillEnterForegroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
                                                    (void)note;
                                                    ghost_ios_schedule_reactivation_burst();
                                                  }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
                                                    (void)note;
                                                    ghost_ios_schedule_reactivation_burst();
                                                  }];
  }
#endif
  return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
  (void)application;
  ghost_ios_schedule_reactivation_burst();
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
  (void)application;
  ghost_ios_schedule_reactivation_burst();
}

- (UISceneConfiguration *)application:(UIApplication *)application
           configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                          options:(UISceneConnectionOptions *)options
{
  (void)application;
  (void)options;

  UISceneConfiguration *configuration = [connectingSceneSession.configuration copy];
  if (configuration == nil) {
    configuration = [[UISceneConfiguration alloc] initWithName:@"Default Configuration"
                                                    sessionRole:connectingSceneSession.role];
  }
  configuration.delegateClass = [IOSSceneDelegate class];
  return configuration;
}

- (void)application:(UIApplication *)application
    didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions
{
  (void)application;
  (void)sceneSessions;
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
  (void)application;
  (void)options;
  ios_handle_incoming_document_url(url);
  return YES;
}

@end

@implementation GHOST_IOSMetalRenderer
{
  id<MTLDevice> _device;
  id<MTLCommandQueue> _commandQueue;
}

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
{
  self = [super init];
  if (self) {
    _device = mtkView.device;

    /* Create the command queue. */
    _commandQueue = [_device newCommandQueue];
  }

  return self;
}

- (void)drawInMTKView:(nonnull MTKView *)MTKView
{
  static bool logged_first_draw = false;
  static uint64_t draw_count = 0;
  draw_count++;
  if (!logged_first_draw) {
    fprintf(stderr, "[ios] first drawInMTKView (C=%p)\n", (void *)C);
    fflush(stderr);
    logged_first_draw = true;
  }
  else if ((draw_count % 300) == 0) {
    fprintf(stderr, "[ios] draw heartbeat count=%llu (C=%p)\n", (unsigned long long)draw_count, (void *)C);
    fflush(stderr);
  }

  if (C) {
    wm_context_ensure_from_main(C);
  }

  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());

  /* We should always have a window... */
  if (system->current_active_window_) {

    /* If the current window has some outstanding swaps we need to
     * service them before handing control back to Blender otherwise
     * they may go missing. */
    if (system->current_active_window_->deferred_swap_buffers_count) {
      IOS_SYSTEM_LOG(@"Issuing oustanding swaps");
      system->current_active_window_->flushDeferredSwapBuffers();
      /* Make sure we get another call to draw. */
      system->current_active_window_->needsDisplayUpdate();
      return;
    }

    system->current_active_window_->beginFrame();
  }

  /* Run the main loop to handle all events. */
  if (C) {
    WM_main_loop_body(C);
  }

  if (system->current_active_window_) {
    system->current_active_window_->flushDeferredSwapBuffers();
    system->current_active_window_->endFrame();
  }

  /* Was there a request to switch windows? */
  if (system->next_active_window_ != nullptr) {
    if (system->current_active_window_) {
      system->current_active_window_->resignKeyWindow();
    }
    system->next_active_window_->makeKeyWindow();
    system->next_active_window_ = nullptr;
  }
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
  GHOST_SystemIOS *system = static_cast<GHOST_SystemIOS *>(GHOST_ISystem::getSystem());
  if (!system->current_active_window_) {
    return;
  }

  system->pushEvent(new GHOST_Event(
      system->getMilliSeconds(), GHOST_kEventWindowSize, system->current_active_window_));
}

@end

int GHOST_iosmain(int _argc, const char **_argv)
{
  fprintf(stderr, "[ios] GHOST_iosmain enter argc=%d\n", _argc);
  fflush(stderr);
  argc = _argc;
  argv = _argv;
  @autoreleasepool {
    return UIApplicationMain(
        _argc, (char *_Nullable *)_argv, nil, NSStringFromClass([IOSAppDelegate class]));
  }
}

void GHOST_iosfinalize(bContext *CTX)
{
  fprintf(stderr, "[ios] GHOST_iosfinalize set context %p\n", (void *)CTX);
  fflush(stderr);
  C = CTX;
  wm_context_ensure_from_main(C);
}

#pragma mark KeyMap, mouse converters

static GHOST_TButton convertButton(int button)
{
  switch (button) {
    case 0:
      return GHOST_kButtonMaskLeft;
    case 1:
      return GHOST_kButtonMaskRight;
    case 2:
      return GHOST_kButtonMaskMiddle;
    case 3:
      return GHOST_kButtonMaskButton4;
    case 4:
      return GHOST_kButtonMaskButton5;
    case 5:
      return GHOST_kButtonMaskButton6;
    case 6:
      return GHOST_kButtonMaskButton7;
    default:
      return GHOST_kButtonMaskLeft;
  }
}

/**
 * Converts Mac raw-key codes (same for Cocoa & Carbon)
 * into GHOST key codes
 * \param rawCode: The raw physical key code
 * \param recvChar: the character ignoring modifiers (except for shift)
 * \return Ghost key code
 */
GHOST_TKey convertKey(int rawCode, unichar recvChar, uint16_t /*keyAction*/)
{
  switch (rawCode) {
      /* Numbers keys: mapped to handle some int'l keyboard (e.g. French). */
      /*
    case kVK_ISO_Section:
      return GHOST_kKeyUnknown;
    case kVK_ANSI_1:
      return GHOST_kKey1;
    case kVK_ANSI_2:
      return GHOST_kKey2;
    case kVK_ANSI_3:
      return GHOST_kKey3;
    case kVK_ANSI_4:
      return GHOST_kKey4;
    case kVK_ANSI_5:
      return GHOST_kKey5;
    case kVK_ANSI_6:
      return GHOST_kKey6;
    case kVK_ANSI_7:
      return GHOST_kKey7;
    case kVK_ANSI_8:
      return GHOST_kKey8;
    case kVK_ANSI_9:
      return GHOST_kKey9;
    case kVK_ANSI_0:
      return GHOST_kKey0;

    case kVK_ANSI_Keypad0:
      return GHOST_kKeyNumpad0;
    case kVK_ANSI_Keypad1:
      return GHOST_kKeyNumpad1;
    case kVK_ANSI_Keypad2:
      return GHOST_kKeyNumpad2;
    case kVK_ANSI_Keypad3:
      return GHOST_kKeyNumpad3;
    case kVK_ANSI_Keypad4:
      return GHOST_kKeyNumpad4;
    case kVK_ANSI_Keypad5:
      return GHOST_kKeyNumpad5;
    case kVK_ANSI_Keypad6:
      return GHOST_kKeyNumpad6;
    case kVK_ANSI_Keypad7:
      return GHOST_kKeyNumpad7;
    case kVK_ANSI_Keypad8:
      return GHOST_kKeyNumpad8;
    case kVK_ANSI_Keypad9:
      return GHOST_kKeyNumpad9;
    case kVK_ANSI_KeypadDecimal:
      return GHOST_kKeyNumpadPeriod;
    case kVK_ANSI_KeypadEnter:
      return GHOST_kKeyNumpadEnter;
    case kVK_ANSI_KeypadPlus:
      return GHOST_kKeyNumpadPlus;
    case kVK_ANSI_KeypadMinus:
      return GHOST_kKeyNumpadMinus;
    case kVK_ANSI_KeypadMultiply:
      return GHOST_kKeyNumpadAsterisk;
    case kVK_ANSI_KeypadDivide:
      return GHOST_kKeyNumpadSlash;
    case kVK_ANSI_KeypadClear:
      return GHOST_kKeyUnknown;

    case kVK_F1:
      return GHOST_kKeyF1;
    case kVK_F2:
      return GHOST_kKeyF2;

    case kVK_F3:
      return GHOST_kKeyF3;
    case kVK_F4:
      return GHOST_kKeyF4;
    case kVK_F5:
      return GHOST_kKeyF5;
    case kVK_F6:
      return GHOST_kKeyF6;
    case kVK_F7:
      return GHOST_kKeyF7;
    case kVK_F8:
      return GHOST_kKeyF8;
    case kVK_F9:
      return GHOST_kKeyF9;
    case kVK_F10:
      return GHOST_kKeyF10;
    case kVK_F11:
      return GHOST_kKeyF11;
    case kVK_F12:
      return GHOST_kKeyF12;
    case kVK_F13:
      return GHOST_kKeyF13;
    case kVK_F14:
      return GHOST_kKeyF14;
    case kVK_F15:
      return GHOST_kKeyF15;
    case kVK_F16:
      return GHOST_kKeyF16;
    case kVK_F17:
      return GHOST_kKeyF17;
    case kVK_F18:
      return GHOST_kKeyF18;
    case kVK_F19:
      return GHOST_kKeyF19;
    case kVK_F20:
      return GHOST_kKeyF20;

    case kVK_UpArrow:
      return GHOST_kKeyUpArrow;
    case kVK_DownArrow:
      return GHOST_kKeyDownArrow;
    case kVK_LeftArrow:
      return GHOST_kKeyLeftArrow;
    case kVK_RightArrow:
      return GHOST_kKeyRightArrow;

    case kVK_Return:
      return GHOST_kKeyEnter;
    case kVK_Delete:
      return GHOST_kKeyBackSpace;
    case kVK_ForwardDelete:
      return GHOST_kKeyDelete;
    case kVK_Escape:
      return GHOST_kKeyEsc;
    case kVK_Tab:
      return GHOST_kKeyTab;
    case kVK_Space:
      return GHOST_kKeySpace;

    case kVK_Home:
      return GHOST_kKeyHome;
    case kVK_End:
      return GHOST_kKeyEnd;
    case kVK_PageUp:
      return GHOST_kKeyUpPage;
    case kVK_PageDown:
      return GHOST_kKeyDownPage;

       */

    default: {
      /* Alphanumerical or punctuation key that is remappable in int'l keyboards. */
      if ((recvChar >= 'A') && (recvChar <= 'Z')) {
        return (GHOST_TKey)(recvChar - 'A' + GHOST_kKeyA);
      }
      else if ((recvChar >= 'a') && (recvChar <= 'z')) {
        return (GHOST_TKey)(recvChar - 'a' + GHOST_kKeyA);
      }
      else {

        switch (recvChar) {
          case '-':
            return GHOST_kKeyMinus;
          case '+':
            return GHOST_kKeyPlus;
          case '=':
            return GHOST_kKeyEqual;
          case ',':
            return GHOST_kKeyComma;
          case '.':
            return GHOST_kKeyPeriod;
          case '/':
            return GHOST_kKeySlash;
          case ';':
            return GHOST_kKeySemicolon;
          case '\'':
            return GHOST_kKeyQuote;
          case '\\':
            return GHOST_kKeyBackslash;
          case '[':
            return GHOST_kKeyLeftBracket;
          case ']':
            return GHOST_kKeyRightBracket;
          case '`':
            return GHOST_kKeyAccentGrave;
          default:
            return GHOST_kKeyUnknown;
        }
      }
    }
  }
  return GHOST_kKeyUnknown;
}

GHOST_TKey convertKeyFromHIDUsage(int hid_usage, uint16_t recv_char)
{
  switch (hid_usage) {
    case 0x28:
      return GHOST_kKeyEnter;
    case 0x29:
      return GHOST_kKeyEsc;
    case 0x2A:
      return GHOST_kKeyBackSpace;
    case 0x2B:
      return GHOST_kKeyTab;
    case 0x2C:
      return GHOST_kKeySpace;
    case 0x2D:
      return GHOST_kKeyMinus;
    case 0x2E:
      return GHOST_kKeyEqual;
    case 0x2F:
      return GHOST_kKeyLeftBracket;
    case 0x30:
      return GHOST_kKeyRightBracket;
    case 0x31:
      return GHOST_kKeyBackslash;
    case 0x33:
      return GHOST_kKeySemicolon;
    case 0x34:
      return GHOST_kKeyQuote;
    case 0x35:
      return GHOST_kKeyAccentGrave;
    case 0x36:
      return GHOST_kKeyComma;
    case 0x37:
      return GHOST_kKeyPeriod;
    case 0x38:
      return GHOST_kKeySlash;
    case 0x39:
      return GHOST_kKeyCapsLock;
    case 0x3A:
      return GHOST_kKeyF1;
    case 0x3B:
      return GHOST_kKeyF2;
    case 0x3C:
      return GHOST_kKeyF3;
    case 0x3D:
      return GHOST_kKeyF4;
    case 0x3E:
      return GHOST_kKeyF5;
    case 0x3F:
      return GHOST_kKeyF6;
    case 0x40:
      return GHOST_kKeyF7;
    case 0x41:
      return GHOST_kKeyF8;
    case 0x42:
      return GHOST_kKeyF9;
    case 0x43:
      return GHOST_kKeyF10;
    case 0x44:
      return GHOST_kKeyF11;
    case 0x45:
      return GHOST_kKeyF12;
    case 0x49:
      return GHOST_kKeyInsert;
    case 0x4A:
      return GHOST_kKeyHome;
    case 0x4B:
      return GHOST_kKeyUpPage;
    case 0x4C:
      return GHOST_kKeyDelete;
    case 0x4D:
      return GHOST_kKeyEnd;
    case 0x4E:
      return GHOST_kKeyDownPage;
    case 0x4F:
      return GHOST_kKeyRightArrow;
    case 0x50:
      return GHOST_kKeyLeftArrow;
    case 0x51:
      return GHOST_kKeyDownArrow;
    case 0x52:
      return GHOST_kKeyUpArrow;
    case 0x53:
      return GHOST_kKeyNumLock;
    case 0x54:
      return GHOST_kKeyNumpadSlash;
    case 0x55:
      return GHOST_kKeyNumpadAsterisk;
    case 0x56:
      return GHOST_kKeyMinus;
    case 0x57:
      return GHOST_kKeyNumpadPlus;
    case 0x58:
      return GHOST_kKeyEnter;
    case 0x59:
      return GHOST_kKeyNumpad1;
    case 0x5A:
      return GHOST_kKeyNumpad2;
    case 0x5B:
      return GHOST_kKeyNumpad3;
    case 0x5C:
      return GHOST_kKeyNumpad4;
    case 0x5D:
      return GHOST_kKeyNumpad5;
    case 0x5E:
      return GHOST_kKeyNumpad6;
    case 0x5F:
      return GHOST_kKeyNumpad7;
    case 0x60:
      return GHOST_kKeyNumpad8;
    case 0x61:
      return GHOST_kKeyNumpad9;
    case 0x62:
      return GHOST_kKeyNumpad0;
    case 0x63:
      return GHOST_kKeyNumpadPeriod;
    case 0xE0:
      return GHOST_kKeyLeftControl;
    case 0xE1:
      return GHOST_kKeyLeftShift;
    case 0xE2:
      return GHOST_kKeyLeftAlt;
    case 0xE3:
      return GHOST_kKeyLeftOS;
    case 0xE4:
      return GHOST_kKeyRightControl;
    case 0xE5:
      return GHOST_kKeyRightShift;
    case 0xE6:
      return GHOST_kKeyRightAlt;
    case 0xE7:
      return GHOST_kKeyRightOS;
    default:
      break;
  }

  if (hid_usage >= 0x04 && hid_usage <= 0x1D) {
    return GHOST_TKey(GHOST_kKeyA + (hid_usage - 0x04));
  }
  if (hid_usage >= 0x1E && hid_usage <= 0x27) {
    return GHOST_TKey(GHOST_kKey1 + (hid_usage - 0x1E));
  }

  return convertKey(0, recv_char, 0);
}

void GHOST_SystemIOS::pushHardwareKeyEvent(GHOST_IWindow *window,
                                           GHOST_TEventType type,
                                           GHOST_TKey key,
                                           bool is_repeat,
                                           const char utf8_buf[6])
{
  if (window == nullptr || key == GHOST_kKeyUnknown) {
    return;
  }

  notifyExternalEventProcessed();

  if (type == GHOST_kEventKeyDown) {
    char utf8[6] = {'\0', '\0', '\0', '\0', '\0', '\0'};
    if (utf8_buf != nullptr) {
      memcpy(utf8, utf8_buf, sizeof(utf8));
    }
    if (modifier_mask_ & (1 << 20)) { /* NSEventModifierFlagCommand */
      utf8[0] = '\0';
    }
    pushEvent(new GHOST_EventKey(getMilliSeconds(), type, window, key, is_repeat, utf8));
  }
  else {
    pushEvent(new GHOST_EventKey(getMilliSeconds(), type, window, key, false, nullptr));
  }
}

void GHOST_SystemIOS::pushHardwareModifierFlags(GHOST_IWindow *window, uint32_t modifier_flags)
{
  if (window == nullptr) {
    return;
  }

  const uint32_t shift_flag = 1 << 17;
  const uint32_t control_flag = 1 << 18;
  const uint32_t alt_flag = 1 << 19;
  const uint32_t command_flag = 1 << 20;

  if ((modifier_flags & shift_flag) != (modifier_mask_ & shift_flag)) {
    pushHardwareKeyEvent(window,
                         (modifier_flags & shift_flag) ? GHOST_kEventKeyDown : GHOST_kEventKeyUp,
                         GHOST_kKeyLeftShift,
                         false);
  }
  if ((modifier_flags & control_flag) != (modifier_mask_ & control_flag)) {
    pushHardwareKeyEvent(window,
                         (modifier_flags & control_flag) ? GHOST_kEventKeyDown : GHOST_kEventKeyUp,
                         GHOST_kKeyLeftControl,
                         false);
  }
  if ((modifier_flags & alt_flag) != (modifier_mask_ & alt_flag)) {
    pushHardwareKeyEvent(window,
                         (modifier_flags & alt_flag) ? GHOST_kEventKeyDown : GHOST_kEventKeyUp,
                         GHOST_kKeyLeftAlt,
                         false);
  }
  if ((modifier_flags & command_flag) != (modifier_mask_ & command_flag)) {
    pushHardwareKeyEvent(window,
                         (modifier_flags & command_flag) ? GHOST_kEventKeyDown : GHOST_kEventKeyUp,
                         GHOST_kKeyLeftOS,
                         false);
  }

  modifier_mask_ = modifier_flags;
  notifyExternalEventProcessed();
}

void GHOST_SystemIOS::pushHardwareCursorMove(GHOST_IWindow *window, int32_t x, int32_t y)
{
  if (window == nullptr) {
    return;
  }
  notifyExternalEventProcessed();
  pushEvent(new GHOST_EventCursor(
      getMilliSeconds(), GHOST_kEventCursorMove, window, x, y, GHOST_TABLET_DATA_NONE));
}

void GHOST_SystemIOS::pushHardwareButtonEvent(GHOST_IWindow *window,
                                              GHOST_TEventType type,
                                              GHOST_TButton mask)
{
  if (window == nullptr) {
    return;
  }
  notifyExternalEventProcessed();
  pushEvent(new GHOST_EventButton(
      getMilliSeconds(), type, window, mask, GHOST_TABLET_DATA_NONE));
}

#pragma mark Utility functions

#define FIRSTFILEBUFLG 512
static bool g_hasFirstFile = false;
static char g_firstFileBuf[512];

extern "C" int GHOST_HACK_getFirstFile(char buf[FIRSTFILEBUFLG])
{
  if (g_hasFirstFile) {
    strncpy(buf, g_firstFileBuf, FIRSTFILEBUFLG - 1);
    buf[FIRSTFILEBUFLG - 1] = '\0';
    return 1;
  }
  else {
    return 0;
  }
}

#pragma mark initialization/finalization

GHOST_SystemIOS::GHOST_SystemIOS()
{
  int mib[2];
  struct timeval boottime;
  size_t len;
  char *rstring = NULL;

  modifier_mask_ = 0;
  outside_loop_event_processed_ = false;
  need_delayed_application_become_active_event_processing_ = false;

  /* TODO: sysctl likely should be replaced with another approach. */
  mib[0] = CTL_KERN;
  mib[1] = KERN_BOOTTIME;
  len = sizeof(struct timeval);

  sysctl(mib, 2, &boottime, &len, NULL, 0);
  m_start_time = ((boottime.tv_sec * 1000) + (boottime.tv_usec / 1000));

  /* Detect multi-touch track-pad. */
  mib[0] = CTL_HW;
  mib[1] = HW_MODEL;
  sysctl(mib, 2, NULL, &len, NULL, 0);
  rstring = (char *)malloc(len);
  sysctl(mib, 2, rstring, &len, NULL, 0);

  free(rstring);
  rstring = NULL;

  ignore_window_sized_message_ = false;
  ignore_momentum_scroll_ = false;
  multi_touch_scroll_ = false;
  last_warp_timestamp_ = 0;
}

void GHOST_SystemIOS::requestInputReactivation()
{
  input_reactivation_pending_ = true;
  input_reactivation_frames_left_ = 8;
}

bool GHOST_SystemIOS::consumeInputReactivationTick()
{
  if (!input_reactivation_pending_) {
    return false;
  }
  if (input_reactivation_frames_left_ <= 0) {
    input_reactivation_pending_ = false;
    return false;
  }
  input_reactivation_frames_left_--;
  if (input_reactivation_frames_left_ <= 0) {
    input_reactivation_pending_ = false;
  }
  return true;
}

GHOST_SystemIOS::~GHOST_SystemIOS() {}

GHOST_TSuccess GHOST_SystemIOS::init()
{
  GHOST_TSuccess success = GHOST_System::init();
  if (success) {

#ifdef WITH_INPUT_NDOF
    m_ndofManager = new GHOST_NDOFManagerCocoa(*this);
#endif
  }
  return success;
}

#pragma mark window management

uint64_t GHOST_SystemIOS::getMilliSeconds() const
{
  struct timeval currentTime;

  gettimeofday(&currentTime, NULL);
  return ((currentTime.tv_sec * 1000) + (currentTime.tv_usec / 1000) - m_start_time);
}

uint8_t GHOST_SystemIOS::getNumDisplays() const
{
  return 1;
}

void GHOST_SystemIOS::getMainDisplayDimensions(uint32_t &width, uint32_t &height) const
{
  CGRect screenRect = [[UIScreen mainScreen] bounds];
  CGFloat scaling_fac = [UIScreen mainScreen].scale;
  CGFloat screenWidth = screenRect.size.width * scaling_fac;
  CGFloat screenHeight = screenRect.size.height * scaling_fac;

  if (screenWidth <= 0 || screenHeight <= 0) {
    GHOST_ASSERT(false, "Negative or null display dimmensions");
    screenWidth = 2532;
    screenHeight = 1170;
  }

  width = screenWidth;
  height = screenHeight;
}

void GHOST_SystemIOS::getAllDisplayDimensions(uint32_t &width, uint32_t &height) const
{
  /* TOOD: iOS passthrough. */
  getMainDisplayDimensions(width, height);
}

GHOST_IWindow *GHOST_SystemIOS::createWindow(const char *title,
                                             int32_t /*left*/,
                                             int32_t /*top*/,
                                             uint32_t width,
                                             uint32_t height,
                                             GHOST_TWindowState state,
                                             GHOST_GPUSettings gpu_settings,
                                             const bool /*exclusive*/,
                                             const bool is_dialog,
                                             const GHOST_IWindow *parent_window)
{
  fprintf(stderr, "[ios] GHOST_SystemIOS::createWindow title=%s size=%ux%u\n", title ? title : "(null)", width, height);
  fflush(stderr);

  /* iOS is single-surface: never allocate a second top-level MTKView (breaks menus/layout). */
  if (!is_dialog && parent_window == nullptr && window_manager_ != nullptr) {
    const std::vector<GHOST_IWindow *> &existing = window_manager_->getWindows();
    for (GHOST_IWindow *w : existing) {
      if (w != nullptr && w->getValid()) {
        fprintf(stderr, "[ios] createWindow reusing existing window=%p\n", (void *)w);
        fflush(stderr);
        return w;
      }
    }
  }

  const GHOST_ContextParams context_params = GHOST_CONTEXT_PARAMS_FROM_GPU_SETTINGS(gpu_settings);
  GHOST_IWindow *window = nullptr;
  @autoreleasepool {

    /* Create window at native size. */
    CGRect bounds = [[UIScreen mainScreen] bounds];

    window = (GHOST_IWindow *)new GHOST_WindowIOS(this,
                                                  title,
                                                  (int)bounds.origin.x,
                                                  (int)bounds.origin.y,
                                                  (unsigned int)bounds.size.width,
                                                  (unsigned int)bounds.size.height,
                                                  state,
                                                  gpu_settings.context_type,
                                                  context_params,
                                                  is_dialog,
                                                  (GHOST_WindowIOS *)parent_window);

    if (window->getValid()) {
      fprintf(stderr, "[ios] createWindow valid window=%p\n", (void *)window);
      fflush(stderr);
      // Store the pointer to the window
      GHOST_ASSERT(window_manager_, "m_windowManager not initialized");
      window_manager_->addWindow(window);
      window_manager_->setActiveWindow(window);
      pushEvent(new GHOST_Event(getMilliSeconds(), GHOST_kEventWindowActivate, window));
      pushEvent(new GHOST_Event(getMilliSeconds(), GHOST_kEventWindowSize, window));
    }
    else {
      fprintf(stderr, "[ios] createWindow INVALID window\n");
      fflush(stderr);
      GHOST_PRINT("GHOST_SystemIOS::createWindow(): window invalid\n");
      delete window;
      window = nullptr;
    }
  }
  return window;
}

/**
 * Create a new offscreen context.
 * Never explicitly delete the context, use #disposeContext() instead.
 * \return The new context (or 0 if creation failed).
 */
GHOST_IContext *GHOST_SystemIOS::createOffscreenContext(GHOST_GPUSettings gpu_settings)
{
  const GHOST_ContextParams context_params_offscreen =
      GHOST_CONTEXT_PARAMS_FROM_GPU_SETTINGS_OFFSCREEN(gpu_settings);

  GHOST_Context *context = new GHOST_ContextIOS(context_params_offscreen, nullptr, nullptr);
  if (context->initializeDrawingContext()) {
    return context;
  }

  delete context;
  return nullptr;
}

/**
 * Dispose of a context.
 * \param context: Pointer to the context to be disposed.
 * \return Indication of success.
 */
GHOST_TSuccess GHOST_SystemIOS::disposeContext(GHOST_IContext *context)
{
  delete context;

  return GHOST_kSuccess;
}

/**
 * \note : returns 0,0 on ios as no cursor is present.
 * TODO: If external mouse or trackpad is connected, we can query cursor position.
 */
GHOST_TSuccess GHOST_SystemIOS::getCursorPosition(int32_t & /*x*/, int32_t & /*y*/) const
{
  /* iOS Passthrough. */
  GHOST_IWindow *window = this->window_manager_->getActiveWindow();
  if (!window) {
    return GHOST_kFailure;
  }
  // GHOST_ASSERT(FALSE,"GHOST_SystemIOS::getCursorPosition unsupported on iOS");
  return GHOST_kSuccess;
}

/**
 * \note : expect Cocoa screen coordinates
 * TODO: If external mouse or trackpad is connected, we can set cursor position.
 */
GHOST_TSuccess GHOST_SystemIOS::setCursorPosition(int32_t x, int32_t y)
{
  GHOST_WindowIOS *window = (GHOST_WindowIOS *)window_manager_->getActiveWindow();
  if (!window)
    return GHOST_kFailure;

  pushEvent(new GHOST_EventCursor(
      getMilliSeconds(), GHOST_kEventCursorMove, window, x, y, window->getTabletData()));
  outside_loop_event_processed_ = true;

  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_SystemIOS::setMouseCursorPosition(int32_t /*x*/, int32_t /*y*/)
{
  /* iOS Passthrough. */
  GHOST_WindowIOS *window = (GHOST_WindowIOS *)window_manager_->getActiveWindow();
  if (!window)
    return GHOST_kFailure;
  GHOST_ASSERT(FALSE, "GHOST_SystemIOS::setMouseCursorPosition unsupported on iOS");
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_SystemIOS::getModifierKeys(GHOST_ModifierKeys & /*keys*/) const
{
  /* iOS Passthrough. */
  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_SystemIOS::getButtons(GHOST_Buttons & /*buttons*/) const
{
  /* iOS Passthrough. */
  return GHOST_kSuccess;
}
GHOST_TCapabilityFlag GHOST_SystemIOS::getCapabilities() const
{
  return GHOST_TCapabilityFlag(GHOST_kCapabilityGPUReadFrontBuffer);
}

#pragma mark Event handlers

/**
 * The event queue polling function
 */
bool GHOST_SystemIOS::processEvents(bool /*waitForEvent*/)
{
  /*
   Touch screen events are being processed through the UIView interactions
   We may need some additional code here to handle key presses if an external keybaord
   is attached
   */
  return true;
}

GHOST_TSuccess GHOST_SystemIOS::handleApplicationBecomeActiveEvent()
{
  modifier_mask_ = 0;

  outside_loop_event_processed_ = true;
  return GHOST_kSuccess;
}

bool GHOST_SystemIOS::hasDialogWindow()
{
  for (GHOST_IWindow *iwindow : window_manager_->getWindows()) {
    GHOST_WindowIOS *window = (GHOST_WindowIOS *)iwindow;
    if (window->isDialog()) {
      return true;
    }
  }
  return false;
}

void GHOST_SystemIOS::notifyExternalEventProcessed()
{
  outside_loop_event_processed_ = true;
}

GHOST_TSuccess GHOST_SystemIOS::handleWindowEvent(GHOST_TEventType eventType,
                                                  GHOST_WindowIOS *window)
{
  if (!validWindow(window)) {
    return GHOST_kFailure;
  }
  switch (eventType) {
    case GHOST_kEventWindowClose:
      pushEvent(new GHOST_Event(getMilliSeconds(), GHOST_kEventWindowClose, window));
      break;
    case GHOST_kEventWindowActivate:
      window_manager_->setActiveWindow(window);
      window->loadCursor(window->getCursorVisibility(), window->getCursorShape());
      pushEvent(new GHOST_Event(getMilliSeconds(), GHOST_kEventWindowActivate, window));
      break;
    case GHOST_kEventWindowDeactivate:
      window_manager_->setWindowInactive(window);
      pushEvent(new GHOST_Event(getMilliSeconds(), GHOST_kEventWindowDeactivate, window));
      break;
    case GHOST_kEventWindowUpdate:
      if (native_pixel_) {
        window->setNativePixelSize();
        pushEvent(new GHOST_Event(getMilliSeconds(), GHOST_kEventNativeResolutionChange, window));
      }
      pushEvent(new GHOST_Event(getMilliSeconds(), GHOST_kEventWindowUpdate, window));
      break;
    case GHOST_kEventWindowMove:
      pushEvent(new GHOST_Event(getMilliSeconds(), GHOST_kEventWindowMove, window));
      break;
    case GHOST_kEventWindowSize:
      if (!ignore_window_sized_message_) {
        // Enforce only one resize message per event loop
        // (coalescing all the live resize messages)
        window->updateDrawingContext();
        pushEvent(new GHOST_Event(getMilliSeconds(), GHOST_kEventWindowSize, window));
        // Mouse up event is trapped by the resizing event loop,
        // so send it anyway to the window manager.
        pushEvent(new GHOST_EventButton(getMilliSeconds(),
                                        GHOST_kEventButtonUp,
                                        window,
                                        GHOST_kButtonMaskLeft,
                                        GHOST_TABLET_DATA_NONE));
      }
      break;
    case GHOST_kEventNativeResolutionChange:

      if (native_pixel_) {
        pushEvent(new GHOST_Event(getMilliSeconds(), GHOST_kEventNativeResolutionChange, window));
      }

    default:
      return GHOST_kFailure;
      break;
  }

  outside_loop_event_processed_ = true;

  return GHOST_kSuccess;
}

GHOST_TSuccess GHOST_SystemIOS::popupOnScreenKeyboard(
    GHOST_IWindow *window, const GHOST_KeyboardProperties &keyboard_properties)
{
  if (!validWindow((GHOST_IWindow *)window)) {
    return GHOST_kFailure;
  }
  GHOST_WindowIOS *windowIOS = (GHOST_WindowIOS *)window;
  return windowIOS->popupOnscreenKeyboard(keyboard_properties);
}

GHOST_TSuccess GHOST_SystemIOS::hideOnScreenKeyboard(GHOST_IWindow *window)
{
  if (!validWindow((GHOST_IWindow *)window)) {
    return GHOST_kFailure;
  }

  GHOST_WindowIOS *windowIOS = (GHOST_WindowIOS *)window;

  return windowIOS->hideOnscreenKeyboard();
}

const char *GHOST_SystemIOS::getKeyboardInput(GHOST_IWindow *window)
{
  if (!validWindow((GHOST_IWindow *)window)) {
    return nullptr;
  }

  GHOST_WindowIOS *windowIOS = (GHOST_WindowIOS *)window;

  return windowIOS->getLastKeyboardString();
}

GHOST_TSuccess GHOST_SystemIOS::startSecurityScopedFileAccess(const char *filepath)
{
  NSURL *url = ios_security_scoped_url_for_path(filepath);
  if (url == nil) {
    url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filepath]];
  }
  const BOOL success = [url startAccessingSecurityScopedResource];

  return success ? GHOST_kSuccess : GHOST_kFailure;
}

GHOST_TSuccess GHOST_SystemIOS::stopSecurityScopedFileAccess(const char *filepath)
{
  NSURL *url = ios_security_scoped_url_for_path(filepath);
  if (url == nil) {
    url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filepath]];
  }
  [url stopAccessingSecurityScopedResource];

  return GHOST_kSuccess;
}

static UIDocumentPickerViewController *ios_create_open_document_picker()
{
  if (@available(iOS 14.0, *)) {
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    UTType *blend_type = [UTType typeWithFilenameExtension:@"blend"];
    if (blend_type != nil) {
      [types addObject:blend_type];
    }
    for (NSString *ext in @[ @"usd", @"usda", @"usdc", @"usdz" ]) {
      UTType *type = [UTType typeWithFilenameExtension:ext];
      if (type != nil) {
        [types addObject:type];
      }
    }
    [types addObject:UTTypeData];
    return [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
  }

  return [[UIDocumentPickerViewController alloc]
      initWithDocumentTypes:@[ @"org.blender.blend", @"com.pixar.usd", @"public.zip", @"public.data" ]
                     inMode:UIDocumentPickerModeImport];
}

bool GHOST_SystemIOS::presentOpenDocumentPicker(IOSFilePickerCallback callback, void *user_data)
{
  if (callback == nullptr || g_ios_file_picker_state.callback != nullptr) {
    return false;
  }

  g_ios_file_picker_state.callback = callback;
  g_ios_file_picker_state.user_data = user_data;

  dispatch_async(dispatch_get_main_queue(), ^{
    @autoreleasepool {
      UIViewController *presenting_vc = ios_top_presenting_view_controller();
      if (presenting_vc == nil) {
        fprintf(stderr, "[ios] open document picker: no presenting view controller\n");
        fflush(stderr);
        ios_file_picker_finish(nullptr, true);
        return;
      }

      UIDocumentPickerViewController *picker = ios_create_open_document_picker();

      if (g_ios_picker_delegate == nil) {
        g_ios_picker_delegate = [[GHOST_IOSDocumentPickerDelegate alloc] init];
      }
      picker.delegate = g_ios_picker_delegate;
      picker.allowsMultipleSelection = NO;
      picker.modalPresentationStyle = UIModalPresentationFullScreen;
      [presenting_vc presentViewController:picker animated:YES completion:nil];
    }
  });

  return true;
}

bool GHOST_SystemIOS::presentExportDocumentPicker(const char *local_blend_path,
                                                  IOSFilePickerCallback callback,
                                                  void *user_data)
{
  if (callback == nullptr || local_blend_path == nullptr ||
      local_blend_path[0] == '\0' || g_ios_file_picker_state.callback != nullptr)
  {
    return false;
  }

  /* Copy path: callers often pass a stack buffer; this method returns before the block runs. */
  const std::string local_path(local_blend_path);

  g_ios_file_picker_state.callback = callback;
  g_ios_file_picker_state.user_data = user_data;

  dispatch_async(dispatch_get_main_queue(), ^{
    @autoreleasepool {
      UIViewController *presenting_vc = ios_top_presenting_view_controller();
      if (presenting_vc == nil) {
        fprintf(stderr, "[ios] export document picker: no presenting view controller\n");
        fflush(stderr);
        ios_file_picker_finish(nullptr, true);
        return;
      }

      NSString *path_string = [NSString stringWithUTF8String:local_path.c_str()];
      if (path_string.length == 0) {
        fprintf(stderr, "[ios] export document picker: empty path\n");
        fflush(stderr);
        ios_file_picker_finish(nullptr, true);
        return;
      }

      NSURL *file_url = nil;
      @try {
        file_url = [NSURL fileURLWithPath:path_string];
      }
      @catch (NSException * /*exception*/) {
        fprintf(stderr, "[ios] export document picker: invalid path\n");
        fflush(stderr);
        ios_file_picker_finish(nullptr, true);
        return;
      }

      if (file_url == nil || ![[NSFileManager defaultManager] fileExistsAtPath:file_url.path]) {
        fprintf(stderr, "[ios] export document picker: staged file missing at %s\n", local_path.c_str());
        fflush(stderr);
        ios_file_picker_finish(nullptr, true);
        return;
      }

      UIDocumentPickerViewController *picker = nil;
      if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ file_url ]
                                                                      asCopy:YES];
      }
      else {
        picker = [[UIDocumentPickerViewController alloc]
            initWithURL:file_url
                 inMode:UIDocumentPickerModeExportToService];
      }

      if (g_ios_picker_delegate == nil) {
        g_ios_picker_delegate = [[GHOST_IOSDocumentPickerDelegate alloc] init];
      }
      picker.delegate = g_ios_picker_delegate;
      picker.modalPresentationStyle = UIModalPresentationFullScreen;
      [presenting_vc presentViewController:picker animated:YES completion:nil];
    }
  });

  return true;
}

static NSString *ios_exports_directory()
{
  NSArray<NSString *> *documents_paths = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES);
  NSString *documents = documents_paths.firstObject;
  if (documents.length == 0) {
    return nil;
  }

  NSString *exports = [documents stringByAppendingPathComponent:@"Exports"];
  NSError *error = nil;
  if (![[NSFileManager defaultManager] createDirectoryAtPath:exports
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&error])
  {
    fprintf(stderr,
            "[ios] exports directory: failed to create %s (%s)\n",
            exports.UTF8String,
            error.localizedDescription.UTF8String ?: "unknown");
    fflush(stderr);
    return nil;
  }

  return exports;
}

static NSString *ios_export_destination_file_path(NSString *destination,
                                                  NSString *filename,
                                                  NSFileManager *file_manager)
{
  if (destination.length == 0 || filename.length == 0) {
    return nil;
  }

  BOOL is_directory = NO;
  if ([file_manager fileExistsAtPath:destination isDirectory:&is_directory] && is_directory) {
    return [destination stringByAppendingPathComponent:filename];
  }

  /* Picker may return a file URL without the trailing component matching filename. */
  if ([file_manager fileExistsAtPath:destination isDirectory:&is_directory] && !is_directory) {
    return destination;
  }

  if ([destination hasSuffix:@"/"] || ![file_manager fileExistsAtPath:destination]) {
    return [destination stringByAppendingPathComponent:filename];
  }

  return destination;
}

static bool ios_copy_file_at_path(NSString *source_path,
                                  NSString *dest_path,
                                  NSFileManager *file_manager)
{
  if (source_path.length == 0 || dest_path.length == 0) {
    return false;
  }
  if (![file_manager fileExistsAtPath:source_path]) {
    return false;
  }

  NSString *dest_dir = [dest_path stringByDeletingLastPathComponent];
  if (dest_dir.length > 0) {
    [file_manager createDirectoryAtPath:dest_dir
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];
  }

  if ([file_manager fileExistsAtPath:dest_path]) {
    [file_manager removeItemAtPath:dest_path error:nil];
  }

  NSError *error = nil;
  if (![file_manager copyItemAtPath:source_path toPath:dest_path error:&error]) {
    fprintf(stderr,
            "[ios] export copy failed %s -> %s (%s)\n",
            source_path.UTF8String,
            dest_path.UTF8String,
            error.localizedDescription.UTF8String ?: "unknown");
    fflush(stderr);
    return false;
  }

  return [file_manager fileExistsAtPath:dest_path];
}

static bool ios_write_final_export_path(char *r_final_path,
                                        const size_t final_path_max,
                                        NSString *path)
{
  if (r_final_path == nullptr || final_path_max == 0 || path.length == 0) {
    return false;
  }
  const char *utf8 = path.UTF8String;
  if (utf8 == nullptr || utf8[0] == '\0') {
    return false;
  }
  strncpy(r_final_path, utf8, final_path_max - 1);
  r_final_path[final_path_max - 1] = '\0';
  return true;
}

bool GHOST_SystemIOS::commitExportFile(const char *staged_path,
                                       const char *destination_path,
                                       const char *filename,
                                       char *r_final_path,
                                       const size_t final_path_max)
{
  if (staged_path == nullptr || staged_path[0] == '\0' || destination_path == nullptr ||
      destination_path[0] == '\0' || filename == nullptr || filename[0] == '\0')
  {
    return false;
  }

  @autoreleasepool {
    NSFileManager *file_manager = [NSFileManager defaultManager];
    NSString *staged = [NSString stringWithUTF8String:staged_path];
    NSString *destination = [NSString stringWithUTF8String:destination_path];
    NSString *name = [NSString stringWithUTF8String:filename];

    if (staged.length == 0 || destination.length == 0 || name.length == 0) {
      return false;
    }
    if (![file_manager fileExistsAtPath:staged]) {
      fprintf(stderr, "[ios] export commit: staged file missing at %s\n", staged_path);
      fflush(stderr);
      return false;
    }

    NSString *dest_file = ios_export_destination_file_path(destination, name, file_manager);
    if (dest_file != nil && [file_manager fileExistsAtPath:dest_file]) {
      [file_manager removeItemAtPath:dest_file error:nil];
    }

    if (dest_file != nil &&
        ios_copy_file_at_path(staged, dest_file, file_manager))
    {
      fprintf(stderr,
              "[ios] export commit: copied staged file to picker destination %s\n",
              dest_file.UTF8String);
      fflush(stderr);
      return ios_write_final_export_path(r_final_path, final_path_max, dest_file);
    }

    NSArray<NSString *> *documents_paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = documents_paths.firstObject;
    if (documents.length == 0) {
      return false;
    }

    NSString *exports_dir = [documents stringByAppendingPathComponent:@"Exports"];
    NSString *fallback_file = [exports_dir stringByAppendingPathComponent:name];
    if (!ios_copy_file_at_path(staged, fallback_file, file_manager)) {
      return false;
    }

    fprintf(stderr,
            "[ios] export commit: copied staged file to Documents fallback %s\n",
            fallback_file.UTF8String);
    fflush(stderr);
    return ios_write_final_export_path(r_final_path, final_path_max, fallback_file);
  }
}

bool GHOST_SystemIOS::documentsExportFilepath(const char *filename,
                                              char *r_final_path,
                                              const size_t final_path_max)
{
  if (filename == nullptr || filename[0] == '\0' || r_final_path == nullptr ||
      final_path_max == 0)
  {
    return false;
  }

  @autoreleasepool {
    NSString *exports = ios_exports_directory();
    if (exports.length == 0) {
      return false;
    }

    NSString *dest = [exports stringByAppendingPathComponent:[NSString stringWithUTF8String:filename]];
    fprintf(stderr, "[ios] documents export path: %s\n", dest.UTF8String);
    fflush(stderr);
    return ios_write_final_export_path(r_final_path, final_path_max, dest);
  }
}

bool GHOST_SystemIOS::saveStagedExportToDocuments(const char *staged_path,
                                                  const char *filename,
                                                  char *r_final_path,
                                                  const size_t final_path_max)
{
  @autoreleasepool {
    NSString *exports = ios_exports_directory();
    if (exports.length == 0) {
      return false;
    }

    fprintf(stderr,
            "[ios] saveStagedExportToDocuments: %s -> %s/%s\n",
            staged_path,
            exports.UTF8String,
            filename);
    fflush(stderr);
    return commitExportFile(
        staged_path, exports.UTF8String, filename, r_final_path, final_path_max);
  }
}

void GHOST_SystemIOS::showNativeAlert(const char *title, const char *message)
{
  dispatch_async(dispatch_get_main_queue(), ^{
    @autoreleasepool {
      UIViewController *presenting_vc = ios_top_presenting_view_controller();
      if (presenting_vc == nil) {
        return;
      }

      NSString *title_string = (title != nullptr) ? [NSString stringWithUTF8String:title] : @"";
      NSString *message_string = (message != nullptr) ? [NSString stringWithUTF8String:message] :
                                                          @"";
      UIAlertController *alert = [UIAlertController alertControllerWithTitle:title_string
                                                                     message:message_string
                                                              preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
      [presenting_vc presentViewController:alert animated:YES completion:nil];
    }
  });
}

// Note: called from NSWindow subclass
GHOST_TSuccess GHOST_SystemIOS::handleDraggingEvent(GHOST_TEventType eventType,
                                                    GHOST_TDragnDropTypes draggedObjectType,
                                                    GHOST_WindowIOS *window,
                                                    int mouseX,
                                                    int mouseY,
                                                    void *data)
{
  if (!validWindow((GHOST_IWindow *)window)) {
    return GHOST_kFailure;
  }
  switch (eventType) {
    case GHOST_kEventDraggingEntered:
    case GHOST_kEventDraggingUpdated:
    case GHOST_kEventDraggingExited:
      window->clientToScreenIntern(mouseX, mouseY, mouseX, mouseY);
      pushEvent(new GHOST_EventDragnDrop(
          getMilliSeconds(), eventType, draggedObjectType, window, mouseX, mouseY, nullptr));
      break;

    case GHOST_kEventDraggingDropDone: {
      uint8_t *temp_buff;
      GHOST_TStringArray *strArray;
      NSArray *droppedArray;
      size_t pastedTextSize;
      NSString *droppedStr;
      GHOST_TDragnDropDataPtr eventData;
      int i;

      if (!data)
        return GHOST_kFailure;

      switch (draggedObjectType) {
        case GHOST_kDragnDropTypeFilenames:
          droppedArray = (NSArray *)data;

          strArray = (GHOST_TStringArray *)malloc(sizeof(GHOST_TStringArray));
          if (!strArray)
            return GHOST_kFailure;

          strArray->count = [droppedArray count];
          if (strArray->count == 0) {
            free(strArray);
            return GHOST_kFailure;
          }

          strArray->strings = (uint8_t **)malloc(strArray->count * sizeof(uint8_t *));

          for (i = 0; i < strArray->count; i++) {
            droppedStr = [droppedArray objectAtIndex:i];

            pastedTextSize = [droppedStr lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            temp_buff = (uint8_t *)malloc(pastedTextSize + 1);

            if (!temp_buff) {
              strArray->count = i;
              break;
            }

            strncpy((char *)temp_buff,
                    [droppedStr cStringUsingEncoding:NSUTF8StringEncoding],
                    pastedTextSize);
            temp_buff[pastedTextSize] = '\0';

            strArray->strings[i] = temp_buff;
          }

          eventData = static_cast<GHOST_TDragnDropDataPtr>(strArray);
          break;

        case GHOST_kDragnDropTypeString:
          droppedStr = (NSString *)data;
          pastedTextSize = [droppedStr lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

          temp_buff = (uint8_t *)malloc(pastedTextSize + 1);

          if (temp_buff == NULL) {
            return GHOST_kFailure;
          }

          strncpy((char *)temp_buff,
                  [droppedStr cStringUsingEncoding:NSUTF8StringEncoding],
                  pastedTextSize);

          temp_buff[pastedTextSize] = '\0';

          eventData = static_cast<GHOST_TDragnDropDataPtr>(temp_buff);
          break;

        case GHOST_kDragnDropTypeBitmap: {
          /* Unsupported iOS. */
          return GHOST_kFailure;
          break;
        }
        default:
          return GHOST_kFailure;
          break;
      }

      pushEvent(new GHOST_EventDragnDrop(
          getMilliSeconds(), eventType, draggedObjectType, window, mouseX, mouseY, eventData));

      break;
    }
    default:
      return GHOST_kFailure;
  }
  outside_loop_event_processed_ = true;
  return GHOST_kSuccess;
}

void GHOST_SystemIOS::handleQuitRequest()
{
  GHOST_Window *window = (GHOST_Window *)window_manager_->getActiveWindow();

  // Discard quit event if we are in cursor grab sequence
  if (window && window->getCursorGrabModeIsWarp())
    return;

  // Push the event to Blender so it can open a dialog if needed
  pushEvent(new GHOST_Event(getMilliSeconds(), GHOST_kEventQuitRequest, window));
  outside_loop_event_processed_ = true;
}

bool GHOST_SystemIOS::handleOpenDocumentRequest(void *filepathStr)
{
  NSString *filepath = (NSString *)filepathStr;

  @autoreleasepool {
    if (filepath == nil || filepath.length == 0) {
      /* Some launch paths can emit an empty document-open callback. Ignore it. */
      return NO;
    }

    if (!current_active_window_) {
      const char *utf8_path = filepath.UTF8String;
      if (utf8_path != nullptr) {
        strncpy(g_firstFileBuf, utf8_path, FIRSTFILEBUFLG - 1);
        g_firstFileBuf[FIRSTFILEBUFLG - 1] = '\0';
        g_hasFirstFile = true;
      }
      return YES;
    }

    /* Discard event if we are in cursor grab sequence,
     * it'll lead to "stuck cursor" situation if the alert panel is raised. */
    if (current_active_window_->getCursorGrabModeIsWarp()) {
      return NO;
    }

    const size_t filenameTextSize = [filepath lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (filenameTextSize == 0) {
      return NO;
    }
    char *temp_buff = (char *)malloc(filenameTextSize + 1);

    if (temp_buff == nullptr) {
      return GHOST_kFailure;
    }

    memcpy(temp_buff, [filepath cStringUsingEncoding:NSUTF8StringEncoding], filenameTextSize);
    temp_buff[filenameTextSize] = '\0';

    pushEvent(new GHOST_EventString(getMilliSeconds(),
                                    GHOST_kEventOpenMainFile,
                                    current_active_window_,
                                    static_cast<GHOST_TEventDataPtr>(temp_buff)));
  }
  return YES;
}

/* None of this currently required for iOS */
#if 0
GHOST_TSuccess GHOST_SystemIOS::handleTabletEvent(void * /*eventPtr*/, short /*eventType*/)
{
  GHOST_WindowIOS *window = (GHOST_WindowIOS *)window_manager_->getActiveWindow();
  if (!window)
    return GHOST_kFailure;
  
  return GHOST_kSuccess;
}

bool GHOST_SystemIOS::handleTabletEvent(void * /*eventPtr*/)
{
  /* TODO: Handle events. */
  GHOST_ASSERT(FALSE,"GHOST_SystemIOS::handleTabletEvent unsupported on iOS");
  return true;
}

GHOST_TSuccess GHOST_SystemIOS::handleMouseEvent(void * /*eventPtr*/)
{
  /* TODO: Handle events (here or elsewhere).
   * NOTE: "Touch" events already handled in other code paths above. */
  GHOST_ASSERT(FALSE,"GHOST_SystemIOS::handleMouseEvent unsupported on iOS");
  return GHOST_kSuccess;
}

#  include <Metal/Metal.h>
bool frame_capture = false;
extern id<MTLDevice> extern_device;
GHOST_TSuccess GHOST_SystemIOS::handleKeyEvent(void * /*eventPtr*/)
{
  /* TODO: Handle events (here or elsewhere). */
  GHOST_ASSERT(FALSE,"GHOST_SystemIOS::handleKeyEvent unsupported on iOS");
  return GHOST_kSuccess;
}
#endif

#pragma mark Clipboard get/set

char *GHOST_SystemIOS::getClipboard(bool /*selection*/) const
{
  @autoreleasepool {
    UIPasteboard *pasteBoard = [UIPasteboard generalPasteboard];
    NSString *textPasted = pasteBoard.string;

    if (textPasted == nil) {
      return nullptr;
    }

    const size_t pastedTextSize = [textPasted lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    char *temp_buff = (char *)malloc(pastedTextSize + 1);

    if (temp_buff == nullptr) {
      return nullptr;
    }

    memcpy(temp_buff, [textPasted cStringUsingEncoding:NSUTF8StringEncoding], pastedTextSize);
    temp_buff[pastedTextSize] = '\0';
    return temp_buff;
  }
  return nullptr;
}

void GHOST_SystemIOS::putClipboard(const char *buffer, bool selection) const
{
  if (selection) {
    return; /* For copying the selection, used on X11. */
  }

  @autoreleasepool {
    UIPasteboard *pasteBoard = UIPasteboard.generalPasteboard;
    NSString *textToCopy = [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
    [pasteBoard setString:textToCopy];
  }
}

GHOST_IWindow *GHOST_SystemIOS::getWindowUnderCursor(int32_t /*x*/, int32_t /*y*/)
{
  GHOST_ASSERT(FALSE, "GHOST_SystemIOS::getWindowUnderCursor unsupported on iOS");
  return nullptr;
}
