/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Ultra-early diagnostic logging for TestFlight / device debugging without USB.
 * Writes append-only logs under the app sandbox Documents folder, visible via Files.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>

static NSString *ios_diag_documents_dir()
{
  NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                                  inDomains:NSUserDomainMask];
  NSURL *docs = urls.firstObject;
  return docs.path.length > 0 ? docs.path : nil;
}

static void ios_diag_append(NSString *filename, const char *line)
{
  @autoreleasepool {
    NSString *dir = ios_diag_documents_dir();
    if (dir == nil || line == nullptr) {
      return;
    }
    NSString *path = [dir stringByAppendingPathComponent:filename];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *entry = [NSString stringWithFormat:@"%@ %s\n", stamp, line];

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle == nil) {
      [[entry dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
      return;
    }
    [handle seekToEndOfFile];
    [handle writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
    /* Flush so the last checkpoint survives a watchdog SIGKILL. */
    if (@available(iOS 13.0, *)) {
      NSError *err = nil;
      [handle synchronizeAndReturnError:&err];
      (void)err;
    }
    else {
      [handle synchronizeFile];
    }
    [handle closeFile];
  }
}

extern "C" void GHOST_IOS_diag_log(const char *message)
{
  if (message == nullptr) {
    return;
  }
  fprintf(stderr, "[ios-diag] %s\n", message);
  fflush(stderr);
  ios_diag_append(@"startup.log", message);
}

static void ios_diag_write_crash(const char *reason)
{
  ios_diag_append(@"ios_crash.log", reason);
  ios_diag_append(@"startup.log", reason);
}

static void ios_diag_signal_handler(int sig, siginfo_t *info, void * /*ucontext*/)
{
  char buf[512];
  const char *name = "signal";
  switch (sig) {
    case SIGABRT:
      name = "SIGABRT";
      break;
    case SIGSEGV:
      name = "SIGSEGV";
      break;
    case SIGBUS:
      name = "SIGBUS";
      break;
    case SIGILL:
      name = "SIGILL";
      break;
    case SIGTRAP:
      name = "SIGTRAP";
      break;
  }
  if (info != nullptr) {
    snprintf(buf,
             sizeof(buf),
             "CRASH %s code=%d addr=%p",
             name,
             info->si_code,
             info->si_addr);
  }
  else {
    snprintf(buf, sizeof(buf), "CRASH %s", name);
  }
  ios_diag_write_crash(buf);
  _exit(128 + sig);
}

static void ios_diag_uncaught_exception(NSException *exception)
{
  char buf[768];
  snprintf(buf,
           sizeof(buf),
           "CRASH NSException %s: %s",
           exception.name.UTF8String ? exception.name.UTF8String : "?",
           exception.reason.UTF8String ? exception.reason.UTF8String : "?");
  ios_diag_write_crash(buf);
}

static void ios_diag_install_signal(int sig)
{
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  sigemptyset(&action.sa_mask);
  action.sa_flags = SA_SIGINFO;
  action.sa_sigaction = ios_diag_signal_handler;
  sigaction(sig, &action, nullptr);
}

extern "C" void GHOST_IOS_diag_install_handlers(void)
{
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    GHOST_IOS_diag_log("diag: handlers installed");
    ios_diag_install_signal(SIGABRT);
    ios_diag_install_signal(SIGSEGV);
    ios_diag_install_signal(SIGBUS);
    ios_diag_install_signal(SIGILL);
    ios_diag_install_signal(SIGTRAP);
    NSSetUncaughtExceptionHandler(ios_diag_uncaught_exception);
  });
}

extern "C" void GHOST_IOS_diag_write_readme(void)
{
  ios_diag_append(
      @"README-logs.txt",
      "Blender visionOS diagnostic logs (TestFlight).\n"
      "premain.log = dyld constructor (before C++/Swift)\n"
      "boot.log = Swift App.init timeline\n"
      "startup.log = launch timeline\n"
      "ios_crash.log = last fatal error\n"
      "After a crash, open Files > On My Vision Pro > Blender and share these files.\n"
      "If ONLY premain.log exists: crash during C++ static init / before App.init.\n"
      "If no files at all: died in dyld before constructors.\n");
}
