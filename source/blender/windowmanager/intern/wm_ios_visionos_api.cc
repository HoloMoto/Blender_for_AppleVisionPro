/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Shared Vision Pro platform state (hand tracking, …) for Python add-ons.
 */

#include "WM_ios_visionos_api.h"

#include "BKE_global.hh"
#include "BKE_main.hh"
#include "BKE_report.hh"
#include "WM_api.hh"

#include <cstdio>
#include <cstring>
#include <mutex>

#if defined(WITH_APPLE_CROSSPLATFORM)
#  define BLENDER_VISIONOS_HOST 1
extern "C" void GHOST_IOS_diag_log(const char *message);
#else
#  define BLENDER_VISIONOS_HOST 0
#endif

static std::mutex g_visionos_mutex;
static BLENDER_VISIONOS_HandSnapshot g_hand_snap{};
static bool g_hand_valid = false;
static bool g_immersive_active = false;

extern "C" int BLENDER_VISIONOS_available(void)
{
#if BLENDER_VISIONOS_HOST
  return 1;
#else
  return 0;
#endif
}

extern "C" uint64_t BLENDER_VISIONOS_capabilities(void)
{
  uint64_t caps = 0;
#if BLENDER_VISIONOS_HOST
  caps |= BLENDER_VISIONOS_CAP_HAND_TRACKING;
  std::lock_guard lock(g_visionos_mutex);
  if (g_immersive_active) {
    caps |= BLENDER_VISIONOS_CAP_IMMERSIVE_ACTIVE;
  }
#endif
  return caps;
}

extern "C" int BLENDER_VISIONOS_hand_snapshot(BLENDER_VISIONOS_HandSnapshot *out)
{
  if (out == nullptr) {
    return 0;
  }
#if !BLENDER_VISIONOS_HOST
  std::memset(out, 0, sizeof(*out));
  out->struct_size = uint32_t(sizeof(*out));
  out->api_version = BLENDER_VISIONOS_API_VERSION;
  return 0;
#else
  std::lock_guard lock(g_visionos_mutex);
  if (!g_hand_valid) {
    std::memset(out, 0, sizeof(*out));
    out->struct_size = uint32_t(sizeof(*out));
    out->api_version = BLENDER_VISIONOS_API_VERSION;
    out->immersive_active = g_immersive_active ? 1u : 0u;
    return 0;
  }
  *out = g_hand_snap;
  return 1;
#endif
}

extern "C" void BLENDER_VISIONOS_hand_publish(const BLENDER_VISIONOS_HandSnapshot *in)
{
#if BLENDER_VISIONOS_HOST
  if (in == nullptr) {
    return;
  }
  std::lock_guard lock(g_visionos_mutex);
  g_hand_snap = *in;
  g_hand_snap.struct_size = uint32_t(sizeof(g_hand_snap));
  if (g_hand_snap.api_version == 0) {
    g_hand_snap.api_version = BLENDER_VISIONOS_API_VERSION;
  }
  g_hand_snap.immersive_active = g_immersive_active ? 1u : 0u;
  g_hand_valid = true;
#else
  (void)in;
#endif
}

extern "C" void BLENDER_VISIONOS_set_immersive_active(int active)
{
#if BLENDER_VISIONOS_HOST
  std::lock_guard lock(g_visionos_mutex);
  g_immersive_active = active != 0;
  if (!g_immersive_active) {
    g_hand_valid = false;
    std::memset(&g_hand_snap, 0, sizeof(g_hand_snap));
    g_hand_snap.struct_size = uint32_t(sizeof(g_hand_snap));
    g_hand_snap.api_version = BLENDER_VISIONOS_API_VERSION;
  }
#else
  (void)active;
#endif
}

extern "C" void BLENDER_IOS_py_stdout_line(const char *line, const int is_err)
{
  if (line == nullptr) {
    return;
  }
#if BLENDER_VISIONOS_HOST
  /* Truncate very long lines for the report banner / Info list. */
  char buf[1024];
  const size_t n = std::strlen(line);
  const char *msg = line;
  if (n >= sizeof(buf)) {
    std::memcpy(buf, line, sizeof(buf) - 4);
    buf[sizeof(buf) - 4] = '.';
    buf[sizeof(buf) - 3] = '.';
    buf[sizeof(buf) - 2] = '.';
    buf[sizeof(buf) - 1] = '\0';
    msg = buf;
  }
  GHOST_IOS_diag_log(msg);
  /* Before WM exists, only the device log is available. */
  if (G_MAIN == nullptr || G_MAIN->wm.first == nullptr) {
    return;
  }
  WM_global_report(is_err ? RPT_WARNING : RPT_INFO, msg);
#else
  (void)is_err;
  fputs(line, is_err ? stderr : stdout);
  fputc('\n', is_err ? stderr : stdout);
#endif
}
