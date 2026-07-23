/* SPDX-FileCopyrightText: 2024 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include <cstdio>
#include <cstdlib>
#include <vector>

#include "usd_utils.hh"

#include "BLI_array.hh"
#include "BLI_fileops.h"
#include "BLI_path_utils.hh"
#include "BLI_string_ref.hh"
#include "BLI_string_utf8.h"

#include "BKE_appdir.hh"

#include <pxr/base/plug/registry.h>
#include <pxr/base/tf/stringUtils.h>
#include <pxr/base/tf/unicodeUtils.h>
#include <pxr/usd/usd/prim.h>
#include <pxr/usd/usd/stage.h>

namespace blender::io::usd {

void USD_platform_runtime_init()
{
#if defined(WITH_APPLE_CROSSPLATFORM)
  static bool initialized = false;
  if (initialized) {
    return;
  }
  initialized = true;

  auto set_env_if_unset = [](const char *name, const char *value) {
    if (value != nullptr && value[0] != '\0' && getenv(name) == nullptr) {
      setenv(name, value, 0);
    }
  };

  /* Plug_InitConfig runs at libusd_ms load time and only reads PXR_PLUGINPATH_NAME
   * then. setenv alone is too late — also RegisterPlugins with absolute paths so
   * ArDefaultResolver (and schemas) are found before UsdStage::CreateNew. */
  std::vector<std::string> plugin_paths;

  if (const std::optional<std::string> usd_datafiles = BKE_appdir_folder_id(
          BLENDER_SYSTEM_DATAFILES, "usd"))
  {
    set_env_if_unset("PXR_PLUGINPATH_NAME", usd_datafiles->c_str());
    plugin_paths.push_back(*usd_datafiles);
  }

  if (const std::optional<std::string> datafiles_root = BKE_appdir_folder_id(
          BLENDER_SYSTEM_DATAFILES, nullptr))
  {
    char lib_usd[FILE_MAX];
    BLI_path_join(
        lib_usd, sizeof(lib_usd), datafiles_root->c_str(), "..", "..", "lib", "usd");
    BLI_path_normalize(lib_usd);
    if (BLI_is_dir(lib_usd)) {
      const char *existing = getenv("PXR_PLUGINPATH_NAME");
      if (existing == nullptr || existing[0] == '\0') {
        set_env_if_unset("PXR_PLUGINPATH_NAME", lib_usd);
      }
      plugin_paths.push_back(lib_usd);
    }

    char mtlx_libs[FILE_MAX];
    BLI_path_join(
        mtlx_libs, sizeof(mtlx_libs), datafiles_root->c_str(), "..", "..", "lib", "materialx", "libraries");
    BLI_path_normalize(mtlx_libs);
    if (BLI_is_dir(mtlx_libs)) {
      set_env_if_unset("MATERIALX_SEARCH_PATH", mtlx_libs);
      set_env_if_unset("PXR_MTLX_STDLIB_SEARCH_PATHS", mtlx_libs);
    }
  }

  if (!plugin_paths.empty()) {
    const pxr::PlugPluginPtrVector registered =
        pxr::PlugRegistry::GetInstance().RegisterPlugins(plugin_paths);
    fprintf(stderr,
            "[ios] USD: RegisterPlugins paths=%zu plugins=%zu\n",
            plugin_paths.size(),
            size_t(registered.size()));
    fflush(stderr);
  }
  else {
    fprintf(stderr, "[ios] USD: WARNING no plugInfo paths found for RegisterPlugins\n");
    fflush(stderr);
  }
#else
  (void)0;
#endif
}

std::string make_safe_name(const StringRef name, bool allow_unicode)
{
  if (name.is_empty()) {
    return "_";
  }

  /* Create temporary buffer with exact amount of space required. */
  const bool has_leading_digit = std::isdigit(name[0]);
  Array<char, 64> storage(name.size() + (has_leading_digit ? 1 : 0));
  MutableSpan<char> buf(storage);

  /* Insert a leading '_' to account for names starting with digits. */
  size_t offset = 0;
  bool first = true;
  if (has_leading_digit) {
    buf[0] = '_';
    offset = 1;
    first = false;
  }

  if (!allow_unicode) {
    buf.take_back(name.size()).copy_from(name);
    offset += name.size();
    return pxr::TfMakeValidIdentifier({buf.data(), offset});
  }

  for (auto cp : pxr::TfUtf8CodePointView{name}) {
    constexpr pxr::TfUtf8CodePoint cp_underscore = pxr::TfUtf8CodePointFromAscii('_');
    const bool cp_allowed = first ? (cp == cp_underscore || pxr::TfIsUtf8CodePointXidStart(cp)) :
                                    pxr::TfIsUtf8CodePointXidContinue(cp);
    if (!cp_allowed) {
      offset += BLI_str_utf8_from_unicode(uint32_t('_'), buf.data() + offset, buf.size() - offset);
    }
    else {
      offset += BLI_str_utf8_from_unicode(cp.AsUInt32(), buf.data() + offset, buf.size() - offset);
    }

    first = false;
  }

  return {buf.data(), offset};
}

pxr::SdfPath get_unique_path(pxr::UsdStageRefPtr stage, const std::string &path)
{
  std::string unique_path = path;
  int suffix = 2;
  while (stage->GetPrimAtPath(pxr::SdfPath(unique_path)).IsValid()) {
    unique_path = path + std::to_string(suffix++);
  }

  return pxr::SdfPath(unique_path);
}

}  // namespace blender::io::usd
