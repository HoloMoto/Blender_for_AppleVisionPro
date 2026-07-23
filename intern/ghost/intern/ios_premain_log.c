/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Absolute earliest launch breadcrumb for TestFlight.
 *
 * Runs as a dyld constructor (priority 101) BEFORE typical C++ static
 * initializers. Pure POSIX — no ObjC, no Swift, no GHOST.
 *
 * If Documents/premain.log exists after a TF crash, dyld reached our binary.
 * If it does not exist, the process died during dyld / before constructors
 * (missing framework, codesign, etc.).
 */

#if defined(WITH_APPLE_CROSSPLATFORM)

#  include <fcntl.h>
#  include <stdio.h>
#  include <stdlib.h>
#  include <string.h>
#  include <sys/stat.h>
#  include <time.h>
#  include <unistd.h>

static void ios_premain_append(const char *filename, const char *message)
{
  const char *home = getenv("HOME");
  if (home == NULL || home[0] == '\0' || message == NULL) {
    return;
  }

  char dir[1024];
  snprintf(dir, sizeof(dir), "%s/Documents", home);
  mkdir(dir, 0755);

  char path[1100];
  snprintf(path, sizeof(path), "%s/%s", dir, filename);

  const time_t now = time(NULL);
  struct tm tm_now;
  localtime_r(&now, &tm_now);
  char stamp[64];
  strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tm_now);

  char line[1024];
  snprintf(line, sizeof(line), "%s %s\n", stamp, message);

  const int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0) {
    return;
  }
  const size_t len = strlen(line);
  (void)write(fd, line, len);
  (void)fsync(fd);
  close(fd);
}

__attribute__((constructor(101))) static void ios_premain_log_ctor(void)
{
  ios_premain_append("premain.log", "premain: constructor 101 begin");
  ios_premain_append("boot.log", "premain: constructor 101 begin");
  ios_premain_append("startup.log", "premain: constructor 101 begin");
  ios_premain_append("premain.log", "premain: HOME Documents writable");
}

#endif /* WITH_APPLE_CROSSPLATFORM */
