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
#include "BLI_time.h"
#include "WM_api.hh"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>

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

static std::mutex g_world_mesh_mutex;
static std::vector<float> g_world_mesh_xyz;
static std::vector<uint32_t> g_world_mesh_indices;
static uint32_t g_world_mesh_revision = 0;
static bool g_world_mesh_available = false;
static bool g_world_mesh_truncated = false;
static double g_world_mesh_timestamp = 0.0;

static void wm_ios_visionos_world_mesh_clear()
{
  std::lock_guard lock(g_world_mesh_mutex);
  g_world_mesh_xyz.clear();
  g_world_mesh_indices.clear();
  g_world_mesh_revision = 0;
  g_world_mesh_available = false;
  g_world_mesh_truncated = false;
  g_world_mesh_timestamp = 0.0;
}

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
  bool immersive_active = false;
  {
    std::lock_guard lock(g_visionos_mutex);
    immersive_active = g_immersive_active;
  }
  if (immersive_active) {
    caps |= BLENDER_VISIONOS_CAP_IMMERSIVE_ACTIVE;
  }
  bool mesh_available = false;
  {
    std::lock_guard lock(g_world_mesh_mutex);
    mesh_available = g_world_mesh_available;
  }
  if (mesh_available && immersive_active) {
    caps |= BLENDER_VISIONOS_CAP_REALITYKIT_SCENE;
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
  {
    std::lock_guard lock(g_visionos_mutex);
    g_immersive_active = active != 0;
    if (!g_immersive_active) {
      g_hand_valid = false;
      std::memset(&g_hand_snap, 0, sizeof(g_hand_snap));
      g_hand_snap.struct_size = uint32_t(sizeof(g_hand_snap));
      g_hand_snap.api_version = BLENDER_VISIONOS_API_VERSION;
    }
  }
  if (active == 0) {
    wm_ios_visionos_world_mesh_clear();
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

extern "C" int BLENDER_VISIONOS_world_mesh_meta(BLENDER_VISIONOS_WorldMeshMeta *out)
{
  if (out == nullptr) {
    return 0;
  }
  std::memset(out, 0, sizeof(*out));
  out->struct_size = uint32_t(sizeof(*out));
  out->api_version = BLENDER_VISIONOS_API_VERSION;
#if BLENDER_VISIONOS_HOST
  {
    std::lock_guard lock(g_visionos_mutex);
    out->immersive_active = g_immersive_active ? 1u : 0u;
  }
  std::lock_guard lock(g_world_mesh_mutex);
  out->timestamp = g_world_mesh_timestamp;
  out->available = g_world_mesh_available ? 1u : 0u;
  out->revision = g_world_mesh_revision;
  out->vertex_count = uint32_t(g_world_mesh_xyz.size() / 3);
  out->index_count = uint32_t(g_world_mesh_indices.size());
  out->truncated = g_world_mesh_truncated ? 1u : 0u;
  return g_world_mesh_available ? 1 : 0;
#else
  return 0;
#endif
}

extern "C" int BLENDER_VISIONOS_world_mesh_copy(float *out_xyz,
                                                uint32_t max_verts,
                                                uint32_t *out_vertex_count,
                                                uint32_t *out_indices,
                                                uint32_t max_indices,
                                                uint32_t *out_index_count)
{
#if BLENDER_VISIONOS_HOST
  std::lock_guard lock(g_world_mesh_mutex);
  const uint32_t vcount = uint32_t(g_world_mesh_xyz.size() / 3);
  const uint32_t icount = uint32_t(g_world_mesh_indices.size());
  if (out_vertex_count != nullptr) {
    *out_vertex_count = vcount;
  }
  if (out_index_count != nullptr) {
    *out_index_count = icount;
  }
  if (!g_world_mesh_available) {
    return 0;
  }
  if (out_xyz != nullptr && max_verts > 0) {
    const uint32_t n = std::min(vcount, max_verts);
    std::memcpy(out_xyz, g_world_mesh_xyz.data(), size_t(n) * 3 * sizeof(float));
  }
  if (out_indices != nullptr && max_indices > 0) {
    const uint32_t n = std::min(icount, max_indices);
    std::memcpy(out_indices, g_world_mesh_indices.data(), size_t(n) * sizeof(uint32_t));
  }
  return 1;
#else
  if (out_vertex_count != nullptr) {
    *out_vertex_count = 0;
  }
  if (out_index_count != nullptr) {
    *out_index_count = 0;
  }
  (void)out_xyz;
  (void)max_verts;
  (void)out_indices;
  (void)max_indices;
  return 0;
#endif
}

extern "C" void BLENDER_VISIONOS_world_mesh_publish(uint32_t revision,
                                                    const float *xyz,
                                                    uint32_t vertex_count,
                                                    const uint32_t *indices,
                                                    uint32_t index_count,
                                                    int truncated)
{
#if BLENDER_VISIONOS_HOST
  uint32_t vcount = (xyz != nullptr) ? std::min(vertex_count, BLENDER_VISIONOS_WORLD_MESH_MAX_VERTS) :
                                       0u;
  uint32_t icount = (indices != nullptr) ?
                        std::min(index_count, BLENDER_VISIONOS_WORLD_MESH_MAX_INDICES) :
                        0u;
  std::lock_guard lock(g_world_mesh_mutex);
  if (vcount == 0 || xyz == nullptr) {
    g_world_mesh_xyz.clear();
  }
  else {
    g_world_mesh_xyz.assign(xyz, xyz + size_t(vcount) * 3);
  }
  if (icount == 0 || indices == nullptr) {
    g_world_mesh_indices.clear();
  }
  else {
    g_world_mesh_indices.assign(indices, indices + icount);
  }
  g_world_mesh_revision = revision;
  g_world_mesh_truncated = truncated != 0;
  g_world_mesh_available = !g_world_mesh_xyz.empty();
  g_world_mesh_timestamp = BLI_time_now_seconds();
#else
  (void)revision;
  (void)xyz;
  (void)vertex_count;
  (void)indices;
  (void)index_count;
  (void)truncated;
#endif
}
