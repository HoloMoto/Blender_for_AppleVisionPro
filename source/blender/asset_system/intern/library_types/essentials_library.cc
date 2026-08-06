/* SPDX-FileCopyrightText: 2023 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup asset_system
 */

#include "BKE_appdir.hh"
#include "BKE_blender_version.h"

#include "BLI_fileops.h"
#include "BLI_path_utils.hh"
#include "BLI_string.h"

#include "utils.hh"

#include "AS_essentials_library.hh"
#include "essentials_library.hh"

namespace blender::asset_system {

EssentialsAssetLibrary::EssentialsAssetLibrary()
    : OnDiskAssetLibrary(ASSET_LIBRARY_ESSENTIALS,
                         {},
                         utils::normalize_directory_path(essentials_directory_path()))
{
  import_method_ = ASSET_IMPORT_APPEND_REUSE;
}

std::optional<AssetLibraryReference> EssentialsAssetLibrary::library_reference() const
{
  AssetLibraryReference library_ref{};
  library_ref.custom_library_index = -1;
  library_ref.type = ASSET_LIBRARY_ESSENTIALS;
  return library_ref;
}

StringRefNull essentials_directory_path()
{
  /* Do not permanently cache an empty result: on Apple cross-platform the first
   * call can race before BLENDER_SYSTEM_DATAFILES is set / appdir is ready. */
  static std::string path;
  if (!path.empty()) {
    return path;
  }

#if defined(WITH_APPLE_CROSSPLATFORM)
  auto assets_contain_sculpt_brushes = [](const char *assets_dir) -> bool {
    if (assets_dir == nullptr || assets_dir[0] == '\0') {
      return false;
    }
    char brush_blend[FILE_MAX];
    BLI_path_join(brush_blend,
                  sizeof(brush_blend),
                  assets_dir,
                  "brushes",
                  "essentials_brushes-mesh_sculpt.blend");
    return BLI_exists(brush_blend);
  };
#endif

  if (const std::optional<std::string> datafiles_path = BKE_appdir_folder_id(
          BLENDER_SYSTEM_DATAFILES, "assets"))
  {
#if defined(WITH_APPLE_CROSSPLATFORM)
    /* Reject paths that resolve but lack the sculpt essentials pack — otherwise
     * Paint stays brush-less and Immersive Sculpt looks "broken". */
    if (assets_contain_sculpt_brushes(datafiles_path->c_str())) {
      path = *datafiles_path;
      return path;
    }
#else
    path = *datafiles_path;
    return path;
#endif
  }

#if defined(WITH_APPLE_CROSSPLATFORM)
  /* Explicit fallback: Blender.app/Assets/<ver>/datafiles/assets */
  const char *program_dir = BKE_appdir_program_dir();
  if (program_dir != nullptr && program_dir[0] != '\0') {
    char candidate[FILE_MAX];
    char ver[16];
    SNPRINTF(ver, "%d.%d", BLENDER_VERSION / 100, BLENDER_VERSION % 100);
    BLI_path_join(candidate, sizeof(candidate), program_dir, "Assets", ver, "datafiles", "assets");
    if (BLI_is_dir(candidate) && assets_contain_sculpt_brushes(candidate)) {
      path = candidate;
      return path;
    }
  }
#endif

  return path;
}

}  // namespace blender::asset_system
