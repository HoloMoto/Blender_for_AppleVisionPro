/* SPDX-FileCopyrightText: 2007 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * Functions for dealing with wmOperator, adding, removing, calling
 * as well as some generic operators and shared operator properties.
 */

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cfloat>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <sstream>
#include <vector>

#include <fmt/format.h>

#ifdef WIN32
#  include "GHOST_C-api.h"
#endif
#if defined(WITH_APPLE_CROSSPLATFORM)
#  include "GHOST_C-api.h"
#endif

#include "MEM_guardedalloc.h"

#include "CLG_log.h"

#include "DNA_ID.h"
#include "DNA_armature_types.h"
#include "DNA_brush_types.h"
#include "DNA_brush_enums.h"
#include "DNA_mesh_types.h"
#include "DNA_object_types.h"
#include "DNA_scene_types.h"
#include "DNA_screen_types.h"
#include "DNA_userdef_types.h"
#include "DNA_windowmanager_types.h"

#include "BLT_translation.hh"

#include "BLI_dial_2d.h"
#include "BLI_fileops.hh"
#include "BLI_listbase.h"
#include "BLI_math_matrix.h"
#include "BLI_math_rotation.h"
#include "BLI_math_vector.h"
#include "BLI_math_vector_types.hh"
#include "BLI_path_utils.hh"
#include "BLI_string.h"
#include "BLI_string_utf8.h"
#include "BLI_time.h"
#include "BLI_utildefines.h"

#include "BKE_anim_data.hh"
#include "BKE_appdir.hh"
#include "BKE_brush.hh"
#include "BKE_colortools.hh"
#include "BKE_context.hh"
#include "BKE_global.hh"
#include "BKE_idprop.hh"
#include "BKE_image.hh"
#include "BKE_image_format.hh"
#include "BKE_lib_id.hh"
#include "BKE_lib_query.hh"
#include "BKE_library.hh"
#include "BKE_main.hh"
#include "BKE_material.hh"
#include "BKE_mesh.hh"
#include "BKE_paint.hh"
#include "BKE_paint_types.hh"
#include "BKE_preview_image.hh"
#include "BKE_report.hh"
#include "BKE_scene.hh"
#include "BKE_screen.hh" /* #BKE_ST_MAXNAME. */

#include "BKE_idtype.hh"

#include "BLF_api.hh"

#include "GPU_immediate.hh"
#include "GPU_immediate_util.hh"
#include "GPU_matrix.hh"
#include "GPU_state.hh"

#include "IMB_imbuf_types.hh"

#include "ED_fileselect.hh"
#include "ED_gpencil_legacy.hh"
#include "ED_grease_pencil.hh"
#include "ED_mesh.hh"
#include "ED_numinput.hh"
#include "ED_screen.hh"
#include "ED_undo.hh"
#include "ED_view3d.hh"

#if defined(WITH_APPLE_CROSSPLATFORM)
#  include "BKE_attribute.h"
#  include "BKE_attribute.hh"
#  include "BKE_attribute_math.hh"
#  include "BKE_action.hh"
#  include "BKE_armature.hh"
#  include "BKE_editmesh.hh"
#  include "BKE_layer.hh"
#  include "BKE_mesh_remesh_voxel.hh"
#  include "BKE_mesh_runtime.hh"
#  include "BKE_paint_bvh.hh"
#  include "BKE_scene.hh"
#  include "BLI_color_types.hh"
#  include "BLI_mutex.hh"
#  include "DNA_action_types.h"
#  include "DNA_armature_types.h"
#  include "DNA_layer_types.h"
#  include "DNA_modifier_types.h"
#  include "DNA_scene_types.h"
#  include "ED_armature.hh"
#  include "ED_object.hh"
#  include "ED_screen.hh"
#  include "BKE_object.hh"
#  include "WM_toolsystem.hh"
#  include "ANIM_action.hh"
#  include "ANIM_action_legacy.hh"
#  include "ANIM_armature.hh"
#  include "ANIM_bone_collections.hh"
#  include "BKE_anim_data.hh"
#  include "BKE_fcurve.hh"
#  include "BKE_node.hh"
#  include "BKE_node_tree_update.hh"
#  include "BLI_math_rotation.h"
#  include "BLI_map.hh"
#  include "BLI_set.hh"
#  include "BLI_string_ref.hh"
#  include "DNA_material_types.h"
#  include "DNA_node_types.h"
#  include "ED_node_c.hh"
#  include "bmesh.hh"
#  ifdef WITH_MOD_REMESH
#    include "dualcon.h"
#  endif
#endif

#include "DEG_depsgraph_query.hh"
#include "DEG_depsgraph.hh"

#include "RNA_access.hh"
#include "RNA_define.hh"
#include "RNA_enum_types.hh"
#include "RNA_path.hh"
#include "RNA_prototypes.hh"

#include "UI_interface.hh"
#include "UI_interface_icons.hh"
#include "UI_interface_layout.hh"
#include "UI_resources.hh"

#include "WM_api.hh"
#include "WM_keymap.hh"
#include "WM_types.hh"

#include "wm.hh"
#include "wm_draw.hh"
#include "wm_event_system.hh"
#include "wm_event_types.hh"
#include "wm_files.hh"
#include "wm_window.hh"
#ifdef WITH_XR_OPENXR
#  include "wm_xr.hh"
#endif

#define UNDOCUMENTED_OPERATOR_TIP N_("(undocumented operator)")

/* -------------------------------------------------------------------- */
/** \name Operator API
 * \{ */

#define OP_BL_SEP_STRING "_OT_"
#define OP_BL_SEP_LEN 4

#define OP_PY_SEP_CHAR '.'
#define OP_PY_SEP_LEN 1

/* Difference between python 'identifier' and BL/C code one ("." separator replaced by "_OT_"),
 * and final `\0` char. */
#define OP_MAX_PY_IDNAME (OP_MAX_TYPENAME - OP_BL_SEP_LEN + OP_PY_SEP_LEN - 1)

size_t WM_operator_py_idname(char *dst, const char *src)
{
  const char *sep = strstr(src, OP_BL_SEP_STRING);
  if (sep) {
    const size_t sep_offset = size_t(sep - src);

    /* NOTE: we use ASCII `tolower` instead of system `tolower`, because the
     * latter depends on the locale, and can lead to `idname` mismatch. */
    memcpy(dst, src, sep_offset);
    BLI_str_tolower_ascii(dst, sep_offset);

    dst[sep_offset] = OP_PY_SEP_CHAR;
    return BLI_strncpy_rlen(dst + (sep_offset + OP_PY_SEP_LEN),
                            sep + OP_BL_SEP_LEN,
                            OP_MAX_TYPENAME - sep_offset - OP_PY_SEP_LEN) +
           (sep_offset + OP_PY_SEP_LEN);
  }
  /* Should not happen but support just in case. */
  return BLI_strncpy_rlen(dst, src, OP_MAX_TYPENAME);
}

size_t WM_operator_bl_idname(char *dst, const char *src)
{
  const size_t from_len = strlen(src);

  const char *sep = strchr(src, OP_PY_SEP_CHAR);
  if (sep && (from_len <= OP_MAX_PY_IDNAME)) {
    const size_t sep_offset = size_t(sep - src);
    memcpy(dst, src, sep_offset);
    BLI_str_toupper_ascii(dst, sep_offset);

    memcpy(dst + sep_offset, OP_BL_SEP_STRING, OP_BL_SEP_LEN);
    BLI_strncpy(dst + sep_offset + OP_BL_SEP_LEN,
                sep + OP_PY_SEP_LEN,
                from_len - sep_offset - OP_PY_SEP_LEN + 1);
    return from_len + OP_BL_SEP_LEN - OP_PY_SEP_LEN;
  }
  /* Should not happen but support just in case. */
  return BLI_strncpy_rlen(dst, src, OP_MAX_TYPENAME);
}

bool WM_operator_bl_idname_is_valid(const char *idname)
{
  const char *sep = strstr(idname, OP_BL_SEP_STRING);
  /* Separator missing or at string beginning/end. */
  if ((sep == nullptr) || (sep == idname) || (sep[OP_BL_SEP_LEN] == '\0')) {
    return false;
  }

  for (const char *ch = idname; ch < sep; ch++) {
    if ((*ch >= 'A' && *ch <= 'Z') || (*ch >= '0' && *ch <= '9') || *ch == '_') {
      continue;
    }
    return false;
  }

  for (const char *ch = sep + OP_BL_SEP_LEN; *ch; ch++) {
    if ((*ch >= 'a' && *ch <= 'z') || (*ch >= '0' && *ch <= '9') || *ch == '_') {
      continue;
    }
    return false;
  }
  return true;
}

bool WM_operator_py_idname_ok_or_report(ReportList *reports,
                                        const char *classname,
                                        const char *idname)
{
  const char *ch = idname;
  int dot = 0;
  int i;
  for (i = 0; *ch; i++, ch++) {
    if ((*ch >= 'a' && *ch <= 'z') || (*ch >= '0' && *ch <= '9') || *ch == '_') {
      /* Pass. */
    }
    else if (*ch == '.') {
      if (ch == idname || (*(ch + 1) == '\0')) {
        BKE_reportf(reports,
                    RPT_ERROR,
                    "Registering operator class: '%s', invalid bl_idname '%s', at position %d",
                    classname,
                    idname,
                    i);
        return false;
      }
      dot++;
    }
    else {
      BKE_reportf(reports,
                  RPT_ERROR,
                  "Registering operator class: '%s', invalid bl_idname '%s', at position %d",
                  classname,
                  idname,
                  i);
      return false;
    }
  }

  if (i > OP_MAX_PY_IDNAME) {
    BKE_reportf(reports,
                RPT_ERROR,
                "Registering operator class: '%s', invalid bl_idname '%s', "
                "is too long, maximum length is %d",
                classname,
                idname,
                OP_MAX_PY_IDNAME);
    return false;
  }

  if (dot != 1) {
    BKE_reportf(
        reports,
        RPT_ERROR,
        "Registering operator class: '%s', invalid bl_idname '%s', must contain 1 '.' character",
        classname,
        idname);
    return false;
  }
  return true;
}

std::string WM_operator_pystring_ex(bContext *C,
                                    wmOperator *op,
                                    const bool all_args,
                                    const bool macro_args,
                                    wmOperatorType *ot,
                                    PointerRNA *opptr)
{
  char idname_py[OP_MAX_TYPENAME];

  /* For building the string. */
  std::stringstream ss;

  /* Arbitrary, but can get huge string with stroke painting otherwise. */
  int max_prop_length = 10;

  WM_operator_py_idname(idname_py, ot->idname);
  ss << "bpy.ops." << idname_py << "(";

  if (op && op->macro.first) {
    /* Special handling for macros, else we only get default values in this case... */
    wmOperator *opm;
    bool first_op = true;

    opm = static_cast<wmOperator *>(macro_args ? op->macro.first : nullptr);

    for (; opm; opm = opm->next) {
      PointerRNA *opmptr = opm->ptr;
      PointerRNA opmptr_default;
      if (opmptr == nullptr) {
        WM_operator_properties_create_ptr(&opmptr_default, opm->type);
        opmptr = &opmptr_default;
      }

      std::string string_args = RNA_pointer_as_string_id(C, opmptr);
      if (first_op) {
        ss << opm->type->idname << '=' << string_args;
        first_op = false;
      }
      else {
        ss << ", " << opm->type->idname << '=' << string_args;
      }

      if (opmptr == &opmptr_default) {
        WM_operator_properties_free(&opmptr_default);
      }
    }
  }
  else {
    /* Only to get the original props for comparisons. */
    PointerRNA opptr_default;
    const bool macro_args_test = ot->macro.first ? macro_args : true;

    if (opptr == nullptr) {
      WM_operator_properties_create_ptr(&opptr_default, ot);
      opptr = &opptr_default;
    }

    ss << RNA_pointer_as_string_keywords(
        C, opptr, false, all_args, macro_args_test, max_prop_length);

    if (opptr == &opptr_default) {
      WM_operator_properties_free(&opptr_default);
    }
  }

  ss << ')';

  return ss.str();
}

std::string WM_operator_pystring(bContext *C,
                                 wmOperator *op,
                                 const bool all_args,
                                 const bool macro_args)
{
  return WM_operator_pystring_ex(C, op, all_args, macro_args, op->type, op->ptr);
}

std::string WM_operator_pystring_abbreviate(std::string str, int str_len_max)
{
  const int str_len = str.size();
  const size_t parens_start = str.find('(');
  if (parens_start == std::string::npos) {
    return str;
  }

  const size_t parens_end = str.find(parens_start + 1, ')');
  if (parens_end == std::string::npos) {
    return str;
  }

  const int parens_len = parens_end - parens_start;
  if (parens_len <= str_len_max) {
    return str;
  }

  /* Truncate after the first comma. */
  const size_t comma_first = str.find(parens_start, ',');
  if (comma_first == std::string::npos) {
    return str;
  }
  const char end_str[] = " ... )";
  const int end_str_len = sizeof(end_str) - 1;

  /* Leave a place for the first argument. */
  const int new_str_len = (comma_first - parens_start) + 1;

  if (str_len < new_str_len + parens_start + end_str_len + 1) {
    return str;
  }

  return str.substr(0, comma_first) + end_str;
}

/* Return nullptr if no match is found. */
#if 0
static const char *wm_context_member_from_ptr(bContext *C, const PointerRNA *ptr, bool *r_is_id)
{
  /* Loop over all context items and do 2 checks
   *
   * - See if the pointer is in the context.
   * - See if the pointers ID is in the context.
   */

  /* Don't get from the context store since this is normally
   * set only for the UI and not usable elsewhere. */
  ListBase lb = CTX_data_dir_get_ex(C, false, true, true);
  LinkData *link;

  const char *member_found = nullptr;
  const char *member_id = nullptr;
  bool member_found_is_id = false;

  for (link = lb.first; link; link = link->next) {
    const char *identifier = link->data;
    PointerRNA ctx_item_ptr = {};
    // CTX_data_pointer_get(C, identifier);  /* XXX, this isn't working. */

    if (ctx_item_ptr.type == nullptr) {
      continue;
    }

    if (ptr->owner_id == ctx_item_ptr.owner_id) {
      const bool is_id = RNA_struct_is_ID(ctx_item_ptr.type);
      if ((ptr->data == ctx_item_ptr.data) && (ptr->type == ctx_item_ptr.type)) {
        /* Found! */
        member_found = identifier;
        member_found_is_id = is_id;
        break;
      }
      if (is_id) {
        /* Found a reference to this ID, so fall back to it if there is no direct reference. */
        member_id = identifier;
      }
    }
  }
  BLI_freelistN(&lb);

  if (member_found) {
    *r_is_id = member_found_is_id;
    return member_found;
  }
  else if (member_id) {
    *r_is_id = true;
    return member_id;
  }
  else {
    return nullptr;
  }
}

#else

/* Use hard coded checks for now. */

/**
 * \param: r_is_id:
 * - When set to true, the returned member is an ID type.
 *   This is a signal that #RNA_path_from_ID_to_struct needs to be used to calculate
 *   the remainder of the RNA path.
 * - When set to false, the returned member is not an ID type.
 *   In this case the context path *must* resolve to `ptr`,
 *   since there is no convenient way to calculate partial RNA paths.
 *
 * \note While the path to the ID is typically sufficient to calculate the remainder of the path,
 * in practice this would cause #WM_context_path_resolve_property_full to create a path such as:
 * `object.data.bones["Bones"].use_deform` such paths are not useful for key-shortcuts,
 * so this function supports returning data-paths directly to context members that aren't ID types.
 */
static const char *wm_context_member_from_ptr(const bContext *C,
                                              const PointerRNA *ptr,
                                              bool *r_is_id)
{
  const char *member_id = nullptr;
  bool is_id = false;

#  define CTX_TEST_PTR_ID(C, member, idptr) \
    { \
      const char *ctx_member = member; \
      PointerRNA ctx_item_ptr = CTX_data_pointer_get(C, ctx_member); \
      if (ctx_item_ptr.owner_id == idptr) { \
        member_id = ctx_member; \
        is_id = true; \
        break; \
      } \
    } \
    (void)0

#  define CTX_TEST_PTR_ID_CAST(C, member, member_full, cast, idptr) \
    { \
      const char *ctx_member = member; \
      const char *ctx_member_full = member_full; \
      PointerRNA ctx_item_ptr = CTX_data_pointer_get(C, ctx_member); \
      if (ctx_item_ptr.owner_id && (ID *)cast(ctx_item_ptr.owner_id) == idptr) { \
        member_id = ctx_member_full; \
        is_id = true; \
        break; \
      } \
    } \
    (void)0

#  define TEST_PTR_DATA_TYPE(member, rna_type, rna_ptr, dataptr_cmp) \
    { \
      const char *ctx_member = member; \
      if (RNA_struct_is_a((rna_ptr)->type, &(rna_type)) && (rna_ptr)->data == (dataptr_cmp)) { \
        member_id = ctx_member; \
        break; \
      } \
    } \
    (void)0

/* A version of #TEST_PTR_DATA_TYPE that calls `CTX_data_pointer_get_type(C, member)`. */
#  define TEST_PTR_DATA_TYPE_FROM_CONTEXT(member, rna_type, rna_ptr) \
    { \
      const char *ctx_member = member; \
      if (RNA_struct_is_a((rna_ptr)->type, &(rna_type)) && \
          (rna_ptr)->data == (CTX_data_pointer_get_type(C, ctx_member, &(rna_type)).data)) \
      { \
        member_id = ctx_member; \
        break; \
      } \
    } \
    (void)0

  /* General checks (multiple ID types). */
  if (ptr->owner_id) {
    const ID_Type ptr_id_type = GS(ptr->owner_id->name);

    /* Support break in the macros for an early exit. */
    do {
      /* Animation Data. */
      if (id_type_can_have_animdata(ptr_id_type)) {
        TEST_PTR_DATA_TYPE_FROM_CONTEXT("active_nla_track", RNA_NlaTrack, ptr);
        TEST_PTR_DATA_TYPE_FROM_CONTEXT("active_nla_strip", RNA_NlaStrip, ptr);
      }
    } while (false);
  }

  /* Specific ID type checks. */
  if (ptr->owner_id && (member_id == nullptr)) {

    const ID_Type ptr_id_type = GS(ptr->owner_id->name);
    switch (ptr_id_type) {
      case ID_SCE: {
        TEST_PTR_DATA_TYPE_FROM_CONTEXT("active_strip", RNA_Strip, ptr);

        CTX_TEST_PTR_ID(C, "scene", ptr->owner_id);
        break;
      }
      case ID_OB: {
        TEST_PTR_DATA_TYPE_FROM_CONTEXT("active_pose_bone", RNA_PoseBone, ptr);

        CTX_TEST_PTR_ID(C, "object", ptr->owner_id);
        break;
      }
      /* From #rna_Main_objects_new. */
      case OB_DATA_SUPPORT_ID_CASE: {

        if (ptr_id_type == ID_AR) {
          const bArmature *arm = (bArmature *)ptr->owner_id;
          if (arm->edbo != nullptr) {
            TEST_PTR_DATA_TYPE("active_bone", RNA_EditBone, ptr, arm->act_edbone);
          }
          else {
            TEST_PTR_DATA_TYPE("active_bone", RNA_Bone, ptr, arm->act_bone);
          }
        }

#  define ID_CAST_OBDATA(id_pt) (((Object *)(id_pt))->data)
        CTX_TEST_PTR_ID_CAST(C, "object", "object.data", ID_CAST_OBDATA, ptr->owner_id);
        break;
#  undef ID_CAST_OBDATA
      }
      case ID_MA: {
#  define ID_CAST_OBMATACT(id_pt) \
    BKE_object_material_get(((Object *)id_pt), ((Object *)id_pt)->actcol)
        CTX_TEST_PTR_ID_CAST(
            C, "object", "object.active_material", ID_CAST_OBMATACT, ptr->owner_id);
        break;
#  undef ID_CAST_OBMATACT
      }
      case ID_WO: {
#  define ID_CAST_SCENEWORLD(id_pt) (((Scene *)(id_pt))->world)
        CTX_TEST_PTR_ID_CAST(C, "scene", "scene.world", ID_CAST_SCENEWORLD, ptr->owner_id);
        break;
#  undef ID_CAST_SCENEWORLD
      }
      case ID_SCR: {
        CTX_TEST_PTR_ID(C, "screen", ptr->owner_id);

        TEST_PTR_DATA_TYPE("area", RNA_Area, ptr, CTX_wm_area(C));
        TEST_PTR_DATA_TYPE("region", RNA_Region, ptr, CTX_wm_region(C));

        SpaceLink *space_data = CTX_wm_space_data(C);
        if (space_data != nullptr) {
          TEST_PTR_DATA_TYPE("space_data", RNA_Space, ptr, space_data);

          switch (space_data->spacetype) {
            case SPACE_VIEW3D: {
              const View3D *v3d = (View3D *)space_data;
              const View3DShading *shading = &v3d->shading;

              TEST_PTR_DATA_TYPE("space_data.overlay", RNA_View3DOverlay, ptr, v3d);
              TEST_PTR_DATA_TYPE("space_data.shading", RNA_View3DShading, ptr, shading);
              break;
            }
            case SPACE_GRAPH: {
              const SpaceGraph *sipo = (SpaceGraph *)space_data;
              const bDopeSheet *ads = sipo->ads;
              TEST_PTR_DATA_TYPE("space_data.dopesheet", RNA_DopeSheet, ptr, ads);
              break;
            }
            case SPACE_FILE: {
              const SpaceFile *sfile = (SpaceFile *)space_data;
              const FileSelectParams *params = ED_fileselect_get_active_params(sfile);
              TEST_PTR_DATA_TYPE("space_data.params", RNA_FileSelectParams, ptr, params);
              break;
            }
            case SPACE_IMAGE: {
              const SpaceImage *sima = (SpaceImage *)space_data;
              TEST_PTR_DATA_TYPE("space_data.overlay", RNA_SpaceImageOverlay, ptr, sima);
              TEST_PTR_DATA_TYPE("space_data.uv_editor", RNA_SpaceUVEditor, ptr, sima);
              break;
            }
            case SPACE_NLA: {
              const SpaceNla *snla = (SpaceNla *)space_data;
              const bDopeSheet *ads = snla->ads;
              TEST_PTR_DATA_TYPE("space_data.dopesheet", RNA_DopeSheet, ptr, ads);
              break;
            }
            case SPACE_ACTION: {
              const SpaceAction *sact = (SpaceAction *)space_data;
              const bDopeSheet *ads = &sact->ads;
              TEST_PTR_DATA_TYPE("space_data.dopesheet", RNA_DopeSheet, ptr, ads);
              break;
            }
            case SPACE_NODE: {
              const SpaceNode *snode = (SpaceNode *)space_data;
              TEST_PTR_DATA_TYPE("space_data.overlay", RNA_SpaceNodeOverlay, ptr, snode);
              break;
            }
            case SPACE_SEQ: {
              const SpaceSeq *sseq = (SpaceSeq *)space_data;
              TEST_PTR_DATA_TYPE(
                  "space_data.preview_overlay", RNA_SequencerPreviewOverlay, ptr, sseq);
              TEST_PTR_DATA_TYPE(
                  "space_data.timeline_overlay", RNA_SequencerTimelineOverlay, ptr, sseq);
              TEST_PTR_DATA_TYPE("space_data.cache_overlay", RNA_SequencerCacheOverlay, ptr, sseq);
              break;
            }
          }
        }

        break;
      }
      default:
        break;
    }
#  undef CTX_TEST_PTR_ID
#  undef CTX_TEST_PTR_ID_CAST
#  undef TEST_PTR_DATA_TYPE
  }

  *r_is_id = is_id;

  return member_id;
}
#endif

std::optional<std::string> WM_context_path_resolve_property_full(const bContext *C,
                                                                 const PointerRNA *ptr,
                                                                 PropertyRNA *prop,
                                                                 int index)
{
  bool is_id;
  const char *member_id = wm_context_member_from_ptr(C, ptr, &is_id);
  if (!member_id) {
    return std::nullopt;
  }
  std::string member_id_data_path;
  if (is_id && !RNA_struct_is_ID(ptr->type)) {
    std::optional<std::string> data_path = RNA_path_from_ID_to_struct(ptr);
    if (data_path) {
      if (prop != nullptr) {
        std::string prop_str = RNA_path_property_py(ptr, prop, index);
        if (prop_str[0] == '[') {
          member_id_data_path = fmt::format("{}.{}{}", member_id, *data_path, prop_str);
        }
        else {
          member_id_data_path = fmt::format("{}.{}.{}", member_id, *data_path, prop_str);
        }
      }
      else {
        member_id_data_path = fmt::format("{}.{}", member_id, *data_path);
      }
    }
  }
  else {
    if (prop != nullptr) {
      std::string prop_str = RNA_path_property_py(ptr, prop, index);
      if (prop_str[0] == '[') {
        member_id_data_path = fmt::format("{}{}", member_id, prop_str);
      }
      else {
        member_id_data_path = fmt::format("{}.{}", member_id, prop_str);
      }
    }
    else {
      member_id_data_path = member_id;
    }
  }

  return member_id_data_path;
}

std::optional<std::string> WM_context_path_resolve_full(bContext *C, const PointerRNA *ptr)
{
  return WM_context_path_resolve_property_full(C, ptr, nullptr, -1);
}

static std::optional<std::string> wm_prop_pystring_from_context(bContext *C,
                                                                PointerRNA *ptr,
                                                                PropertyRNA *prop,
                                                                int index)
{
  std::optional<std::string> member_id_data_path = WM_context_path_resolve_property_full(
      C, ptr, prop, index);
  if (!member_id_data_path.has_value()) {
    return std::nullopt;
  }
  return "bpy.context." + member_id_data_path.value();
}

std::optional<std::string> WM_prop_pystring_assign(bContext *C,
                                                   PointerRNA *ptr,
                                                   PropertyRNA *prop,
                                                   int index)
{
  std::optional<std::string> lhs = C ? wm_prop_pystring_from_context(C, ptr, prop, index) :
                                       std::nullopt;

  if (!lhs.has_value()) {
    /* Fall back to `bpy.data.foo[id]` if we don't find in the context. */
    if (std::optional<std::string> lhs_str = RNA_path_full_property_py(ptr, prop, index)) {
      lhs = lhs_str;
    }
    else {
      return std::nullopt;
    }
  }

  std::string rhs = RNA_property_as_string(C, ptr, prop, index, INT_MAX);

  std::string ret = fmt::format("{} = {}", lhs.value(), rhs);
  return ret;
}

void WM_operator_properties_create_ptr(PointerRNA *ptr, wmOperatorType *ot)
{
  /* Set the ID so the context can be accessed: see #STRUCT_NO_CONTEXT_WITHOUT_OWNER_ID. */
  ID *owner_id = (G_MAIN && G_MAIN->wm.first) ? static_cast<ID *>(G_MAIN->wm.first) : nullptr;
  if (ot == nullptr || ot->srna == nullptr) {
    *ptr = RNA_pointer_create_discrete(owner_id, &RNA_OperatorProperties, nullptr);
    return;
  }
  *ptr = RNA_pointer_create_discrete(owner_id, ot->srna, nullptr);
}

void WM_operator_properties_create(PointerRNA *ptr, const char *opstring)
{
  wmOperatorType *ot = WM_operatortype_find(opstring, false);

  if (ot) {
    WM_operator_properties_create_ptr(ptr, ot);
  }
  else {
    /* Set the ID so the context can be accessed: see #STRUCT_NO_CONTEXT_WITHOUT_OWNER_ID. */
    *ptr = RNA_pointer_create_discrete(
        static_cast<ID *>(G_MAIN->wm.first), &RNA_OperatorProperties, nullptr);
  }
}

void WM_operator_properties_alloc(PointerRNA **ptr, IDProperty **properties, const char *opstring)
{
  IDProperty *tmp_properties = nullptr;
  /* Allow passing nullptr for properties, just create the properties here then. */
  if (properties == nullptr) {
    properties = &tmp_properties;
  }

  if (*properties == nullptr) {
    *properties = blender::bke::idprop::create_group("wmOpItemProp").release();
  }

  if (*ptr == nullptr) {
    *ptr = MEM_new<PointerRNA>("wmOpItemPtr");
    WM_operator_properties_create(*ptr, opstring);
  }

  (*ptr)->data = *properties;
}

void WM_operator_properties_sanitize(PointerRNA *ptr, const bool no_context)
{
  RNA_STRUCT_BEGIN (ptr, prop) {
    switch (RNA_property_type(prop)) {
      case PROP_ENUM:
        if (no_context) {
          RNA_def_property_flag(prop, PROP_ENUM_NO_CONTEXT);
        }
        else {
          RNA_def_property_clear_flag(prop, PROP_ENUM_NO_CONTEXT);
        }
        break;
      case PROP_POINTER: {
        StructRNA *ptype = RNA_property_pointer_type(ptr, prop);

        /* Recurse into operator properties. */
        if (RNA_struct_is_a(ptype, &RNA_OperatorProperties)) {
          PointerRNA opptr = RNA_property_pointer_get(ptr, prop);
          WM_operator_properties_sanitize(&opptr, no_context);
        }
        break;
      }
      default:
        break;
    }
  }
  RNA_STRUCT_END;
}

bool WM_operator_properties_default(PointerRNA *ptr, const bool do_update)
{
  bool changed = false;
  RNA_STRUCT_BEGIN (ptr, prop) {
    switch (RNA_property_type(prop)) {
      case PROP_POINTER: {
        StructRNA *ptype = RNA_property_pointer_type(ptr, prop);
        if (ptype != &RNA_Struct) {
          PointerRNA opptr = RNA_property_pointer_get(ptr, prop);
          changed |= WM_operator_properties_default(&opptr, do_update);
        }
        break;
      }
      default:
        if ((do_update == false) || (RNA_property_is_set(ptr, prop) == false)) {
          if (RNA_property_reset(ptr, prop, -1)) {
            changed = true;
          }
        }
        break;
    }
  }
  RNA_STRUCT_END;

  return changed;
}

void WM_operator_properties_reset(wmOperator *op)
{
  if (op->ptr->data) {
    PropertyRNA *iterprop = RNA_struct_iterator_property(op->type->srna);

    RNA_PROP_BEGIN (op->ptr, itemptr, iterprop) {
      PropertyRNA *prop = static_cast<PropertyRNA *>(itemptr.data);

      if ((RNA_property_flag(prop) & (PROP_SKIP_SAVE | PROP_SKIP_PRESET)) == 0) {
        const char *identifier = RNA_property_identifier(prop);
        RNA_struct_system_idprops_unset(op->ptr, identifier);
      }
    }
    RNA_PROP_END;
  }
}

void WM_operator_properties_clear(PointerRNA *ptr)
{
  IDProperty *properties = static_cast<IDProperty *>(ptr->data);

  if (properties) {
    IDP_ClearProperty(properties);
  }
}

void WM_operator_properties_free(PointerRNA *ptr)
{
  IDProperty *properties = static_cast<IDProperty *>(ptr->data);

  if (properties) {
    IDP_FreeProperty(properties);
    ptr->data = nullptr; /* Just in case. */
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Operator Last Properties API
 * \{ */

#if 1 /* May want to disable operator remembering previous state for testing. */

static bool operator_last_properties_init_impl(wmOperator *op, IDProperty *last_properties)
{
  bool changed = false;
  IDProperty *replaceprops = blender::bke::idprop::create_group("wmOperatorProperties").release();

  PropertyRNA *iterprop = RNA_struct_iterator_property(op->type->srna);

  RNA_PROP_BEGIN (op->ptr, itemptr, iterprop) {
    PropertyRNA *prop = static_cast<PropertyRNA *>(itemptr.data);
    if ((RNA_property_flag(prop) & PROP_SKIP_SAVE) == 0) {
      if (!RNA_property_is_set(op->ptr, prop)) { /* Don't override a setting already set. */
        const char *identifier = RNA_property_identifier(prop);
        IDProperty *idp_src = IDP_GetPropertyFromGroup(last_properties, identifier);
        if (idp_src) {
          IDProperty *idp_dst = IDP_CopyProperty(idp_src);

          /* NOTE: in the future this may need to be done recursively,
           * but for now RNA doesn't access nested operators. */
          idp_dst->flag |= IDP_FLAG_GHOST;

          /* Add to temporary group instead of immediate replace,
           * because we are iterating over this group. */
          IDP_AddToGroup(replaceprops, idp_dst);
          changed = true;
        }
      }
    }
  }
  RNA_PROP_END;

  if (changed) {
    CLOG_DEBUG(WM_LOG_OPERATORS, "Loading previous properties for '%s'", op->type->idname);
  }
  IDP_MergeGroup(op->properties, replaceprops, true);
  IDP_FreeProperty(replaceprops);
  return changed;
}

bool WM_operator_last_properties_init(wmOperator *op)
{
  bool changed = false;
  if (op->type->last_properties) {
    changed |= operator_last_properties_init_impl(op, op->type->last_properties);
    LISTBASE_FOREACH (wmOperator *, opm, &op->macro) {
      IDProperty *idp_src = IDP_GetPropertyFromGroup(op->type->last_properties, opm->idname);
      if (idp_src) {
        changed |= operator_last_properties_init_impl(opm, idp_src);
      }
    }
  }
  return changed;
}

bool WM_operator_last_properties_store(wmOperator *op)
{
  if (op->type->last_properties) {
    IDP_FreeProperty(op->type->last_properties);
    op->type->last_properties = nullptr;
  }

  if (op->properties) {
    if (!BLI_listbase_is_empty(&op->properties->data.group)) {
      CLOG_DEBUG(WM_LOG_OPERATORS, "Storing properties for '%s'", op->type->idname);
    }
    op->type->last_properties = IDP_CopyProperty(op->properties);
  }

  if (op->macro.first != nullptr) {
    LISTBASE_FOREACH (wmOperator *, opm, &op->macro) {
      if (opm->properties) {
        if (op->type->last_properties == nullptr) {
          op->type->last_properties =
              blender::bke::idprop::create_group("wmOperatorProperties").release();
        }
        IDProperty *idp_macro = IDP_CopyProperty(opm->properties);
        STRNCPY(idp_macro->name, opm->type->idname);
        IDP_ReplaceInGroup(op->type->last_properties, idp_macro);
      }
    }
  }

  return (op->type->last_properties != nullptr);
}

#else

bool WM_operator_last_properties_init(wmOperator * /*op*/)
{
  return false;
}

bool WM_operator_last_properties_store(wmOperator * /*op*/)
{
  return false;
}

#endif

/** \} */

/* -------------------------------------------------------------------- */
/** \name Default Operator Callbacks
 * \{ */

wmOperatorStatus WM_generic_select_modal(bContext *C, wmOperator *op, const wmEvent *event)
{
  PropertyRNA *wait_to_deselect_prop = RNA_struct_find_property(op->ptr,
                                                                "wait_to_deselect_others");
  const short init_event_type = short(POINTER_AS_INT(op->customdata));

  /* Get settings from RNA properties for operator. */
  const int mval[2] = {RNA_int_get(op->ptr, "mouse_x"), RNA_int_get(op->ptr, "mouse_y")};

  if (init_event_type == 0) {
    if (event->val == KM_PRESS) {
      RNA_property_boolean_set(op->ptr, wait_to_deselect_prop, true);

      wmOperatorStatus retval = op->type->exec(C, op);
      OPERATOR_RETVAL_CHECK(retval);

      op->customdata = POINTER_FROM_INT(int(event->type));
      if (retval & OPERATOR_RUNNING_MODAL) {
        WM_event_add_modal_handler(C, op);
      }
      return retval | OPERATOR_PASS_THROUGH;
    }
    /* If we are in init phase, and cannot validate init of modal operations,
     * just fall back to basic exec.
     */
    RNA_property_boolean_set(op->ptr, wait_to_deselect_prop, false);

    wmOperatorStatus retval = op->type->exec(C, op);
    OPERATOR_RETVAL_CHECK(retval);

    return retval | OPERATOR_PASS_THROUGH;
  }
  if (event->type == init_event_type && event->val == KM_RELEASE) {
    RNA_property_boolean_set(op->ptr, wait_to_deselect_prop, false);

    wmOperatorStatus retval = op->type->exec(C, op);
    OPERATOR_RETVAL_CHECK(retval);

    return retval | OPERATOR_PASS_THROUGH;
  }
  if (ISMOUSE_MOTION(event->type)) {
    const int drag_delta[2] = {
        mval[0] - event->mval[0],
        mval[1] - event->mval[1],
    };
    /* If user moves mouse more than defined threshold, we consider select operator as
     * finished. Otherwise, it is still running until we get an 'release' event. In any
     * case, we pass through event, but select op is not finished yet. */
    if (WM_event_drag_test_with_delta(event, drag_delta)) {
      return OPERATOR_FINISHED | OPERATOR_PASS_THROUGH;
    }
    /* Important not to return anything other than PASS_THROUGH here,
     * otherwise it prevents underlying drag detection code to work properly. */
    return OPERATOR_PASS_THROUGH;
  }

  return OPERATOR_RUNNING_MODAL | OPERATOR_PASS_THROUGH;
}

wmOperatorStatus WM_generic_select_invoke(bContext *C, wmOperator *op, const wmEvent *event)
{
  ARegion *region = CTX_wm_region(C);

  int mval[2];
  WM_event_drag_start_mval(event, region, mval);

  RNA_int_set(op->ptr, "mouse_x", mval[0]);
  RNA_int_set(op->ptr, "mouse_y", mval[1]);

  op->customdata = POINTER_FROM_INT(0);

  wmOperatorStatus retval = op->type->modal(C, op, event);
  OPERATOR_RETVAL_CHECK(retval);
  return retval;
}

void WM_operator_view3d_unit_defaults(bContext *C, wmOperator *op)
{
  if (op->flag & OP_IS_INVOKE) {
    Scene *scene = CTX_data_scene(C);
    View3D *v3d = CTX_wm_view3d(C);

    const float dia = v3d ? ED_view3d_grid_scale(scene, v3d, nullptr) :
                            ED_scene_grid_scale(scene, nullptr);

    /* Always run, so the values are initialized,
     * otherwise we may get differ behavior when `dia != 1.0`. */
    RNA_STRUCT_BEGIN (op->ptr, prop) {
      if (RNA_property_type(prop) == PROP_FLOAT) {
        PropertySubType pstype = RNA_property_subtype(prop);
        if (pstype == PROP_DISTANCE) {
          /* We don't support arrays yet. */
          BLI_assert(RNA_property_array_check(prop) == false);
          /* Initialize. */
          if (!RNA_property_is_set_ex(op->ptr, prop, false)) {
            const float value = RNA_property_float_get_default(op->ptr, prop) * dia;
            RNA_property_float_set(op->ptr, prop, value);
          }
        }
      }
    }
    RNA_STRUCT_END;
  }
}

int WM_operator_smooth_viewtx_get(const wmOperator *op)
{
  return (op->flag & OP_IS_INVOKE && !(U.uiflag & USER_REDUCE_MOTION)) ? U.smooth_viewtx : 0;
}

wmOperatorStatus WM_menu_invoke_ex(bContext *C,
                                   wmOperator *op,
                                   blender::wm::OpCallContext opcontext)
{
  PropertyRNA *prop = op->type->prop;

  if (prop == nullptr) {
    CLOG_ERROR(WM_LOG_OPERATORS, "'%s' has no enum property set", op->type->idname);
  }
  else if (RNA_property_type(prop) != PROP_ENUM) {
    CLOG_ERROR(WM_LOG_OPERATORS,
               "'%s', '%s' is not an enum property",
               op->type->idname,
               RNA_property_identifier(prop));
  }
  else if (RNA_property_is_set(op->ptr, prop)) {
    const wmOperatorStatus retval = op->type->exec(C, op);
    OPERATOR_RETVAL_CHECK(retval);
    return retval;
  }
  else {
    uiPopupMenu *pup = UI_popup_menu_begin(
        C, WM_operatortype_name(op->type, op->ptr).c_str(), ICON_NONE);
    uiLayout *layout = UI_popup_menu_layout(pup);
    /* Set this so the default execution context is the same as submenus. */
    layout->operator_context_set(opcontext);
    layout->op_enum(op->type->idname,
                    RNA_property_identifier(prop),
                    static_cast<IDProperty *>(op->ptr->data),
                    opcontext,
                    UI_ITEM_NONE);
    UI_popup_menu_end(C, pup);
    return OPERATOR_INTERFACE;
  }

  return OPERATOR_CANCELLED;
}

wmOperatorStatus WM_menu_invoke(bContext *C, wmOperator *op, const wmEvent * /*event*/)
{
  return WM_menu_invoke_ex(C, op, blender::wm::OpCallContext::InvokeRegionWin);
}

struct EnumSearchMenu {
  wmOperator *op; /* The operator that will be executed when selecting an item. */
};

/** Generic enum search invoke popup. */
static uiBlock *wm_enum_search_menu(bContext *C, ARegion *region, void *arg)
{
  EnumSearchMenu *search_menu = static_cast<EnumSearchMenu *>(arg);
  wmWindow *win = CTX_wm_window(C);
  wmOperator *op = search_menu->op;
  /* `template_ID` uses `4 * widget_unit` for width,
   * we use a bit more, some items may have a suffix to show. */
  const int width = UI_searchbox_size_x();
  const int height = UI_searchbox_size_y();
  static char search[256] = "";

  uiBlock *block = UI_block_begin(C, region, "_popup", blender::ui::EmbossType::Emboss);
  UI_block_flag_enable(block, UI_BLOCK_LOOP | UI_BLOCK_MOVEMOUSE_QUIT | UI_BLOCK_SEARCH_MENU);
  UI_block_theme_style_set(block, UI_BLOCK_THEME_STYLE_POPUP);

  search[0] = '\0';
#if 0 /* Ok, this isn't so easy. */
  uiDefBut(block,
           ButType::Label,
           0,
           WM_operatortype_name(op->type, op->ptr),
           0,
           0,
           UI_searchbox_size_x(),
           UI_UNIT_Y,
           nullptr,
           0.0,
           0.0,
           "");
#endif
  uiBut *but = uiDefSearchButO_ptr(block,
                                   op->type,
                                   static_cast<IDProperty *>(op->ptr->data),
                                   search,
                                   0,
                                   ICON_VIEWZOOM,
                                   sizeof(search),
                                   0,
                                   0,
                                   width,
                                   UI_UNIT_Y,
                                   "");

  /* Fake button, it holds space for search items. */
  uiDefBut(block, ButType::Label, 0, "", 0, -height, width, height, nullptr, 0, 0, std::nullopt);

  /* Move it downwards, mouse over button. */
  UI_block_bounds_set_popup(block, UI_SEARCHBOX_BOUNDS, blender::int2{0, -UI_UNIT_Y});

  UI_but_focus_on_enter_event(win, but);

  return block;
}

wmOperatorStatus WM_enum_search_invoke(bContext *C, wmOperator *op, const wmEvent * /*event*/)
{
  static EnumSearchMenu search_menu;
  search_menu.op = op;
  /* Refreshing not supported, because operator might get freed. */
  const bool can_refresh = false;
  UI_popup_block_invoke_ex(C, wm_enum_search_menu, &search_menu, nullptr, can_refresh);
  return OPERATOR_INTERFACE;
}

wmOperatorStatus WM_operator_confirm_message_ex(bContext *C,
                                                wmOperator *op,
                                                const char *title,
                                                const int icon,
                                                const char *message,
                                                const blender::wm::OpCallContext /*opcontext*/)
{
  int alert_icon = ALERT_ICON_QUESTION;
  switch (icon) {
    case ICON_NONE:
      alert_icon = ALERT_ICON_NONE;
      break;
    case ICON_ERROR:
      alert_icon = ALERT_ICON_WARNING;
      break;
    case ICON_QUESTION:
      alert_icon = ALERT_ICON_QUESTION;
      break;
    case ICON_CANCEL:
      alert_icon = ALERT_ICON_ERROR;
      break;
    case ICON_INFO:
      alert_icon = ALERT_ICON_INFO;
      break;
  }
  return WM_operator_confirm_ex(C, op, IFACE_(title), nullptr, IFACE_(message), alert_icon, false);
}

wmOperatorStatus WM_operator_confirm_message(bContext *C, wmOperator *op, const char *message)
{
  return WM_operator_confirm_ex(
      C, op, IFACE_(message), nullptr, IFACE_("OK"), ALERT_ICON_NONE, false);
}

wmOperatorStatus WM_operator_confirm(bContext *C, wmOperator *op, const wmEvent * /*event*/)
{
  return WM_operator_confirm_ex(
      C, op, IFACE_(op->type->name), nullptr, IFACE_("OK"), ALERT_ICON_NONE, false);
}

wmOperatorStatus WM_operator_confirm_or_exec(bContext *C,
                                             wmOperator *op,
                                             const wmEvent * /*event*/)
{
  const bool confirm = RNA_boolean_get(op->ptr, "confirm");
  if (confirm) {
    return WM_operator_confirm_ex(
        C, op, IFACE_(op->type->name), nullptr, IFACE_("OK"), ALERT_ICON_NONE, false);
  }
  return op->type->exec(C, op);
}

wmOperatorStatus WM_operator_filesel(bContext *C, wmOperator *op, const wmEvent * /*event*/)
{
  if (RNA_struct_property_is_set(op->ptr, "filepath")) {
    return WM_operator_call_notest(C, op); /* Call exec direct. */
  }
  WM_event_add_fileselect(C, op);
  return OPERATOR_RUNNING_MODAL;
}

bool WM_operator_filesel_ensure_ext_imtype(wmOperator *op, const ImageFormatData *im_format)
{
  char filepath[FILE_MAX];
  /* Don't nullptr check prop, this can only run on ops with a 'filepath'. */
  PropertyRNA *prop = RNA_struct_find_property(op->ptr, "filepath");
  RNA_property_string_get(op->ptr, prop, filepath);
  if (BKE_image_path_ext_from_imformat_ensure(filepath, sizeof(filepath), im_format)) {
    RNA_property_string_set(op->ptr, prop, filepath);
    /* NOTE: we could check for and update 'filename' here,
     * but so far nothing needs this. */
    return true;
  }
  return false;
}

bool WM_operator_winactive(bContext *C)
{
  if (CTX_wm_window(C) == nullptr) {
    return false;
  }
  return true;
}

bool WM_operator_check_ui_enabled(const bContext *C, const char *idname)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  Scene *scene = CTX_data_scene(C);

  return !((ED_undo_is_valid(C, idname) == false) || WM_jobs_test(wm, scene, WM_JOB_TYPE_ANY));
}

wmOperator *WM_operator_last_redo(const bContext *C)
{
  wmWindowManager *wm = CTX_wm_manager(C);

  /* Only for operators that are registered and did an undo push. */
  LISTBASE_FOREACH_BACKWARD (wmOperator *, op, &wm->runtime->operators) {
    if ((op->type->flag & OPTYPE_REGISTER) && (op->type->flag & OPTYPE_UNDO)) {
      return op;
    }
  }

  return nullptr;
}

IDProperty *WM_operator_last_properties_ensure_idprops(wmOperatorType *ot)
{
  if (ot->last_properties == nullptr) {
    ot->last_properties = blender::bke::idprop::create_group("wmOperatorProperties").release();
  }
  return ot->last_properties;
}

void WM_operator_last_properties_ensure(wmOperatorType *ot, PointerRNA *ptr)
{
  IDProperty *props = WM_operator_last_properties_ensure_idprops(ot);
  *ptr = RNA_pointer_create_discrete(static_cast<ID *>(G_MAIN->wm.first), ot->srna, props);
}

ID *WM_operator_drop_load_path(bContext *C, wmOperator *op, const short idcode)
{
  Main *bmain = CTX_data_main(C);
  ID *id = nullptr;

  /* Check input variables. */
  if (RNA_struct_property_is_set(op->ptr, "filepath")) {
    const bool is_relative_path = RNA_boolean_get(op->ptr, "relative_path");
    char filepath[FILE_MAX];
    bool exists = false;

    RNA_string_get(op->ptr, "filepath", filepath);

    errno = 0;

    if (idcode == ID_IM) {
      id = reinterpret_cast<ID *>(BKE_image_load_exists(bmain, filepath, &exists));
    }
    else {
      BLI_assert_unreachable();
    }

    if (!id) {
      BKE_reportf(op->reports,
                  RPT_ERROR,
                  "Cannot read %s '%s': %s",
                  BKE_idtype_idcode_to_name(idcode),
                  filepath,
                  errno ? strerror(errno) : RPT_("unsupported format"));
      return nullptr;
    }

    if (is_relative_path) {
      if (exists == false) {
        if (idcode == ID_IM) {
          BLI_path_rel(((Image *)id)->filepath, BKE_main_blendfile_path(bmain));
        }
        else {
          BLI_assert_unreachable();
        }
      }
    }

    return id;
  }

  if (!WM_operator_properties_id_lookup_is_set(op->ptr)) {
    return nullptr;
  }

  /* Lookup an already existing ID. */
  id = WM_operator_properties_id_lookup_from_name_or_session_uid(bmain, op->ptr, ID_Type(idcode));

  if (!id) {
    /* Print error with the name if the name is available. */

    if (RNA_struct_property_is_set(op->ptr, "name")) {
      char name[MAX_ID_NAME - 2];
      RNA_string_get(op->ptr, "name", name);
      BKE_reportf(
          op->reports, RPT_ERROR, "%s '%s' not found", BKE_idtype_idcode_to_name(idcode), name);
      return nullptr;
    }

    BKE_reportf(op->reports, RPT_ERROR, "%s not found", BKE_idtype_idcode_to_name(idcode));
    return nullptr;
  }

  id_us_plus(id);
  return id;
}

static void wm_block_redo_cb(bContext *C, void *arg_op, int /*arg_event*/)
{
  wmOperator *op = static_cast<wmOperator *>(arg_op);

  if (op == WM_operator_last_redo(C)) {
    /* Operator was already executed once? undo & repeat. */
    ED_undo_operator_repeat(C, op);
  }
  else {
    /* Operator not executed yet, call it. */
    ED_undo_push_op(C, op);
    wm_operator_register(C, op);

    WM_operator_repeat(C, op);
  }
}

static void wm_block_redo_cancel_cb(bContext *C, void *arg_op)
{
  wmOperator *op = static_cast<wmOperator *>(arg_op);

  /* If operator never got executed, free it. */
  if (op != WM_operator_last_redo(C)) {
    WM_operator_free(op);
  }
}

static uiBlock *wm_block_create_redo(bContext *C, ARegion *region, void *arg_op)
{
  wmOperator *op = static_cast<wmOperator *>(arg_op);
  const uiStyle *style = UI_style_get_dpi();
  int width = 15 * UI_UNIT_X;

  uiBlock *block = UI_block_begin(C, region, __func__, blender::ui::EmbossType::Emboss);
  UI_block_flag_disable(block, UI_BLOCK_LOOP);
  UI_block_theme_style_set(block, UI_BLOCK_THEME_STYLE_REGULAR);

  /* #UI_BLOCK_NUMSELECT for layer buttons. */
  UI_block_flag_enable(block, UI_BLOCK_NUMSELECT | UI_BLOCK_KEEP_OPEN | UI_BLOCK_MOVEMOUSE_QUIT);

  /* If register is not enabled, the operator gets freed on #OPERATOR_FINISHED
   * ui_apply_but_funcs_after calls #ED_undo_operator_repeate_cb and crashes. */
  BLI_assert(op->type->flag & OPTYPE_REGISTER);

  UI_block_func_handle_set(block, wm_block_redo_cb, arg_op);
  UI_popup_dummy_panel_set(region, block);
  uiLayout &layout = blender::ui::block_layout(block,
                                               blender::ui::LayoutDirection::Vertical,
                                               blender::ui::LayoutType::Panel,
                                               0,
                                               0,
                                               width,
                                               UI_UNIT_Y,
                                               0,
                                               style);

  if (op == WM_operator_last_redo(C)) {
    if (!WM_operator_check_ui_enabled(C, op->type->name)) {
      layout.enabled_set(false);
    }
  }

  uiItemL_ex(&layout, WM_operatortype_name(op->type, op->ptr), ICON_NONE, true, false);
  layout.separator(0.2f, LayoutSeparatorType::Line);
  layout.separator(0.5f);

  uiLayout *col = &layout.column(false);
  uiTemplateOperatorPropertyButs(C, col, op, UI_BUT_LABEL_ALIGN_NONE, 0);

  UI_block_bounds_set_popup(block, 7 * UI_SCALE_FAC, nullptr);

  return block;
}

struct wmOpPopUp {
  wmOperator *op;
  int width;
  int free_op;
  std::string title;
  std::string message;
  std::string confirm_text;
  eAlertIcon icon;
  wmPopupSize size;
  wmPopupPosition position;
  bool cancel_default;
  bool mouse_move_quit;
  bool include_properties;
};

/* Only invoked by OK button in popups created with #wm_block_dialog_create(). */
static void dialog_exec_cb(bContext *C, void *arg1, void *arg2)
{
  wmOperator *op;
  {
    /* Execute will free the operator.
     * In this case, wm_operator_ui_popup_cancel won't run. */
    wmOpPopUp *data = static_cast<wmOpPopUp *>(arg1);
    op = data->op;
    MEM_delete(data);
  }

  uiBlock *block = static_cast<uiBlock *>(arg2);
  /* Explicitly set UI_RETURN_OK flag, otherwise the menu might be canceled
   * in case WM_operator_call_ex exits/reloads the current file (#49199). */

  UI_popup_menu_retval_set(block, UI_RETURN_OK, true);

  /* Get context data *after* WM_operator_call_ex
   * which might have closed the current file and changed context. */
  wmWindow *win = CTX_wm_window(C);
  UI_popup_block_close(C, win, block);

  WM_operator_call_ex(C, op, true);
}

static void wm_operator_ui_popup_cancel(bContext *C, void *user_data);

/* Only invoked by Cancel button in popups created with #wm_block_dialog_create(). */
static void dialog_cancel_cb(bContext *C, void *arg1, void *arg2)
{
  wm_operator_ui_popup_cancel(C, arg1);
  uiBlock *block = static_cast<uiBlock *>(arg2);
  UI_popup_menu_retval_set(block, UI_RETURN_CANCEL, true);
  wmWindow *win = CTX_wm_window(C);
  UI_popup_block_close(C, win, block);
}

/**
 * Dialogs are popups that require user verification (click OK) before exec.
 */
static uiBlock *wm_block_dialog_create(bContext *C, ARegion *region, void *user_data)
{
  wmOpPopUp *data = static_cast<wmOpPopUp *>(user_data);
  wmOperator *op = data->op;
  const uiStyle *style = UI_style_get_dpi();
  const bool small = data->size == WM_POPUP_SIZE_SMALL;
  const short icon_size = (small ? 32 : 40) * UI_SCALE_FAC;

  uiBlock *block = UI_block_begin(C, region, __func__, blender::ui::EmbossType::Emboss);
  UI_block_flag_disable(block, UI_BLOCK_LOOP);
  UI_block_theme_style_set(block, UI_BLOCK_THEME_STYLE_POPUP);
  UI_popup_dummy_panel_set(region, block);

  if (data->mouse_move_quit) {
    UI_block_flag_enable(block, UI_BLOCK_MOVEMOUSE_QUIT);
  }
  if (data->icon < ALERT_ICON_NONE || data->icon >= ALERT_ICON_MAX) {
    data->icon = ALERT_ICON_QUESTION;
  }

  UI_block_flag_enable(block, UI_BLOCK_KEEP_OPEN | UI_BLOCK_NUMSELECT);

  UI_fontstyle_set(&style->widget);
  /* Width based on the text lengths. */
  int text_width = std::max(
      120 * UI_SCALE_FAC,
      BLF_width(style->widget.uifont_id, data->title.c_str(), BLF_DRAW_STR_DUMMY_MAX));

  /* Break Message into multiple lines. */
  blender::Vector<std::string> message_lines;
  blender::StringRef messaged_trimmed = blender::StringRef(data->message).trim();
  std::istringstream message_stream(messaged_trimmed);
  std::string line;
  while (std::getline(message_stream, line)) {
    message_lines.append(line);
    text_width = std::max(
        text_width, int(BLF_width(style->widget.uifont_id, line.c_str(), BLF_DRAW_STR_DUMMY_MAX)));
  }

  int dialog_width = std::max(text_width + int(style->columnspace * 2.5), data->width);

  /* Adjust width if the button text is long. */
  const int longest_button_text = std::max(
      BLF_width(style->widget.uifont_id, data->confirm_text.c_str(), BLF_DRAW_STR_DUMMY_MAX),
      BLF_width(style->widget.uifont_id, IFACE_("Cancel"), BLF_DRAW_STR_DUMMY_MAX));
  dialog_width = std::max(dialog_width, 3 * longest_button_text);

  uiLayout *layout;
  if (data->icon != ALERT_ICON_NONE) {
    layout = uiItemsAlertBox(
        block, style, dialog_width + icon_size, eAlertIcon(data->icon), icon_size);
  }
  else {
    layout = &blender::ui::block_layout(block,
                                        blender::ui::LayoutDirection::Vertical,
                                        blender::ui::LayoutType::Panel,
                                        0,
                                        0,
                                        dialog_width,
                                        0,
                                        0,
                                        style);
  }

  /* Title. */
  if (!data->title.empty()) {
    uiItemL_ex(layout, data->title, ICON_NONE, true, false);

    /* Line under the title if there are properties but no message body. */
    if (data->include_properties && message_lines.size() == 0) {
      layout->separator(0.2f, LayoutSeparatorType::Line);
    };
  }

  /* Message lines. */
  if (message_lines.size() > 0) {
    uiLayout *lines = &layout->column(false);
    lines->scale_y_set(0.65f);
    lines->separator(0.1f);
    for (auto &st : message_lines) {
      lines->label(st, ICON_NONE);
    }
  }

  if (data->include_properties) {
    layout->separator(0.5f);
    uiTemplateOperatorPropertyButs(C, layout, op, UI_BUT_LABEL_ALIGN_SPLIT_COLUMN, 0);
  }

  layout->separator(small ? 0.1f : 1.8f);

  /* Clear so the OK button is left alone. */
  UI_block_func_set(block, nullptr, nullptr, nullptr);

#ifdef _WIN32
  const bool windows_layout = true;
#else
  const bool windows_layout = false;
#endif

  /* Check there are no active default buttons, allowing a dialog to define its own
   * confirmation buttons which are shown instead of these, see: #124098. */
  if (!UI_block_has_active_default_button(layout->block())) {
    /* New column so as not to interfere with custom layouts, see: #26436. */
    uiLayout *col = &layout->column(false);
    uiBlock *col_block = col->block();
    uiBut *confirm_but;
    uiBut *cancel_but;

    col = &col->split(0.0f, true);
    col->scale_y_set(small ? 1.0f : 1.2f);

    if (windows_layout) {
      confirm_but = uiDefBut(col_block,
                             ButType::But,
                             0,
                             data->confirm_text.c_str(),
                             0,
                             0,
                             0,
                             UI_UNIT_Y,
                             nullptr,
                             0,
                             0,
                             "");
      col->column(false);
    }

    cancel_but = uiDefBut(
        col_block, ButType::But, 0, IFACE_("Cancel"), 0, 0, 0, UI_UNIT_Y, nullptr, 0, 0, "");

    if (!windows_layout) {
      col->column(false);
      confirm_but = uiDefBut(col_block,
                             ButType::But,
                             0,
                             data->confirm_text.c_str(),
                             0,
                             0,
                             0,
                             UI_UNIT_Y,
                             nullptr,
                             0,
                             0,
                             "");
    }

    UI_but_func_set(confirm_but, dialog_exec_cb, data, col_block);
    UI_but_func_set(cancel_but, dialog_cancel_cb, data, col_block);
    UI_but_flag_enable((data->cancel_default) ? cancel_but : confirm_but, UI_BUT_ACTIVE_DEFAULT);
  }

  const int padding = (small ? 7 : 14) * UI_SCALE_FAC;

  if (data->position == WM_POPUP_POSITION_MOUSE) {
    const float button_center_x = windows_layout ? -0.4f : -0.90f;
    const float button_center_y = small ? 2.0f : 3.1f;
    const int bounds_offset[2] = {int(button_center_x * layout->width()),
                                  int(button_center_y * UI_UNIT_X)};
    UI_block_bounds_set_popup(block, padding, bounds_offset);
  }
  else if (data->position == WM_POPUP_POSITION_CENTER) {
    UI_block_bounds_set_centered(block, padding);
  }

  return block;
}

static uiBlock *wm_operator_ui_create(bContext *C, ARegion *region, void *user_data)
{
  wmOpPopUp *data = static_cast<wmOpPopUp *>(user_data);
  wmOperator *op = data->op;
  const uiStyle *style = UI_style_get_dpi();

  uiBlock *block = UI_block_begin(C, region, __func__, blender::ui::EmbossType::Emboss);
  UI_block_flag_disable(block, UI_BLOCK_LOOP);
  UI_block_flag_enable(block, UI_BLOCK_KEEP_OPEN | UI_BLOCK_MOVEMOUSE_QUIT);
  UI_block_theme_style_set(block, UI_BLOCK_THEME_STYLE_REGULAR);

  UI_popup_dummy_panel_set(region, block);

  uiLayout &layout = blender::ui::block_layout(block,
                                               blender::ui::LayoutDirection::Vertical,
                                               blender::ui::LayoutType::Panel,
                                               0,
                                               0,
                                               data->width,
                                               0,
                                               0,
                                               style);

  /* Since UI is defined the auto-layout args are not used. */
  uiTemplateOperatorPropertyButs(C, &layout, op, UI_BUT_LABEL_ALIGN_COLUMN, 0);

  UI_block_func_set(block, nullptr, nullptr, nullptr);

  UI_block_bounds_set_popup(block, 6 * UI_SCALE_FAC, nullptr);

  return block;
}

static void wm_operator_ui_popup_cancel(bContext *C, void *user_data)
{
  wmOpPopUp *data = static_cast<wmOpPopUp *>(user_data);
  wmOperator *op = data->op;

  if (op) {
    if (op->type->cancel) {
      op->type->cancel(C, op);
    }

    if (data->free_op) {
      WM_operator_free(op);
    }
  }

  MEM_delete(data);
}

static void wm_operator_ui_popup_ok(bContext *C, void *arg, int retval)
{
  wmOpPopUp *data = static_cast<wmOpPopUp *>(arg);
  wmOperator *op = data->op;

  if (op && retval > 0) {
    WM_operator_call_ex(C, op, true);
  }

  MEM_delete(data);
}

wmOperatorStatus WM_operator_confirm_ex(bContext *C,
                                        wmOperator *op,
                                        const char *title,
                                        const char *message,
                                        const char *confirm_text,
                                        int icon,
                                        bool cancel_default)
{
  wmOpPopUp *data = MEM_new<wmOpPopUp>(__func__);
  data->op = op;

  /* Larger dialog needs a wider minimum width to balance with the big icon. */
  const float min_width = (message == nullptr) ? 180.0f : 230.0f;
  data->width = int(min_width * UI_SCALE_FAC * UI_style_get()->widget.points /
                    UI_DEFAULT_TEXT_POINTS);

  data->free_op = true;
  data->title = (title == nullptr) ? WM_operatortype_name(op->type, op->ptr) : title;
  data->message = (message == nullptr) ? std::string() : message;
  data->confirm_text = (confirm_text == nullptr) ? IFACE_("OK") : confirm_text;
  data->icon = eAlertIcon(icon);
  data->size = (message == nullptr) ? WM_POPUP_SIZE_SMALL : WM_POPUP_SIZE_LARGE;
  data->position = (message == nullptr) ? WM_POPUP_POSITION_MOUSE : WM_POPUP_POSITION_CENTER;
  data->cancel_default = cancel_default;
  data->mouse_move_quit = (message == nullptr) ? true : false;
  data->include_properties = false;

  UI_popup_block_ex(
      C, wm_block_dialog_create, wm_operator_ui_popup_ok, wm_operator_ui_popup_cancel, data, op);

  return OPERATOR_RUNNING_MODAL;
}

wmOperatorStatus WM_operator_ui_popup(bContext *C, wmOperator *op, int width)
{
  wmOpPopUp *data = MEM_new<wmOpPopUp>(__func__);
  data->op = op;
  data->width = width * UI_SCALE_FAC;
  data->free_op = true; /* If this runs and gets registered we may want not to free it. */
  UI_popup_block_ex(C, wm_operator_ui_create, nullptr, wm_operator_ui_popup_cancel, data, op);
  return OPERATOR_RUNNING_MODAL;
}

/**
 * For use by #WM_operator_props_popup_call, #WM_operator_props_popup only.
 *
 * \note operator menu needs undo flag enabled, for redo callback.
 */
static wmOperatorStatus wm_operator_props_popup_ex(
    bContext *C,
    wmOperator *op,
    const bool do_call,
    const bool do_redo,
    std::optional<std::string> title = std::nullopt,
    std::optional<std::string> confirm_text = std::nullopt,
    const bool cancel_default = false,
    std::optional<std::string> message = std::nullopt)
{
  if ((op->type->flag & OPTYPE_REGISTER) == 0) {
    BKE_reportf(op->reports,
                RPT_ERROR,
                "Operator '%s' does not have register enabled, incorrect invoke function",
                op->type->idname);
    return OPERATOR_CANCELLED;
  }

  if (do_redo) {
    if ((op->type->flag & OPTYPE_UNDO) == 0) {
      BKE_reportf(op->reports,
                  RPT_ERROR,
                  "Operator '%s' does not have undo enabled, incorrect invoke function",
                  op->type->idname);
      return OPERATOR_CANCELLED;
    }
  }

  /* If we don't have global undo, we can't do undo push for automatic redo,
   * so we require manual OK clicking in this popup. */
  if (!do_redo || !(U.uiflag & USER_GLOBALUNDO)) {
    return WM_operator_props_dialog_popup(
        C, op, 300, title, confirm_text, cancel_default, message);
  }

  UI_popup_block_ex(C, wm_block_create_redo, nullptr, wm_block_redo_cancel_cb, op, op);

  if (do_call) {
    wm_block_redo_cb(C, op, 0);
  }

  return OPERATOR_RUNNING_MODAL;
}

wmOperatorStatus WM_operator_props_popup_confirm_ex(bContext *C,
                                                    wmOperator *op,
                                                    const wmEvent * /*event*/,
                                                    std::optional<std::string> title,
                                                    std::optional<std::string> confirm_text,
                                                    const bool cancel_default,
                                                    std::optional<std::string> message)
{
  return wm_operator_props_popup_ex(
      C, op, false, false, title, confirm_text, cancel_default, message);
}

wmOperatorStatus WM_operator_props_popup_confirm(bContext *C,
                                                 wmOperator *op,
                                                 const wmEvent * /*event*/)
{
  return wm_operator_props_popup_ex(C, op, false, false, {}, {});
}

wmOperatorStatus WM_operator_props_popup_call(bContext *C,
                                              wmOperator *op,
                                              const wmEvent * /*event*/)
{
  return wm_operator_props_popup_ex(C, op, true, true);
}

wmOperatorStatus WM_operator_props_popup(bContext *C, wmOperator *op, const wmEvent * /*event*/)
{
  return wm_operator_props_popup_ex(C, op, false, true);
}

wmOperatorStatus WM_operator_props_dialog_popup(bContext *C,
                                                wmOperator *op,
                                                int width,
                                                std::optional<std::string> title,
                                                std::optional<std::string> confirm_text,
                                                const bool cancel_default,
                                                std::optional<std::string> message)
{
  wmOpPopUp *data = MEM_new<wmOpPopUp>(__func__);
  data->op = op;
  data->width = int(float(width) * UI_SCALE_FAC * UI_style_get()->widget.points /
                    UI_DEFAULT_TEXT_POINTS);
  data->free_op = true; /* If this runs and gets registered we may want not to free it. */
  data->title = title ? std::move(*title) : WM_operatortype_name(op->type, op->ptr);
  data->confirm_text = confirm_text ? std::move(*confirm_text) : IFACE_("OK");
  data->message = message ? std::move(*message) : std::string();
  data->icon = ALERT_ICON_NONE;
  data->size = WM_POPUP_SIZE_SMALL;
  data->position = (message) ? WM_POPUP_POSITION_CENTER : WM_POPUP_POSITION_MOUSE;
  data->cancel_default = cancel_default;
  data->mouse_move_quit = false;
  data->include_properties = true;

  /* The operator is not executed until popup OK button is clicked. */
  UI_popup_block_ex(
      C, wm_block_dialog_create, wm_operator_ui_popup_ok, wm_operator_ui_popup_cancel, data, op);

  return OPERATOR_RUNNING_MODAL;
}

wmOperatorStatus WM_operator_redo_popup(bContext *C, wmOperator *op)
{
  /* `CTX_wm_reports(C)` because operator is on stack, not active in event system. */
  if ((op->type->flag & OPTYPE_REGISTER) == 0) {
    BKE_reportf(CTX_wm_reports(C),
                RPT_ERROR,
                "Operator redo '%s' does not have register enabled, incorrect invoke function",
                op->type->idname);
    return OPERATOR_CANCELLED;
  }
  if (op->type->poll && op->type->poll(C) == 0) {
    BKE_reportf(
        CTX_wm_reports(C), RPT_ERROR, "Operator redo '%s': wrong context", op->type->idname);
    return OPERATOR_CANCELLED;
  }

  /* Operator is stored and kept alive in the window manager. So passing a pointer to the UI is
   * fine, it will remain valid. */
  UI_popup_block_invoke(C, wm_block_create_redo, op, nullptr);

  return OPERATOR_CANCELLED;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Debug Menu Operator
 *
 * Set internal debug value, mainly for developers.
 * \{ */

static wmOperatorStatus wm_debug_menu_exec(bContext *C, wmOperator *op)
{
  G.debug_value = RNA_int_get(op->ptr, "debug_value");
  ED_screen_refresh(C, CTX_wm_manager(C), CTX_wm_window(C));
  WM_event_add_notifier(C, NC_WINDOW, nullptr);

  return OPERATOR_FINISHED;
}

static wmOperatorStatus wm_debug_menu_invoke(bContext *C,
                                             wmOperator *op,
                                             const wmEvent * /*event*/)
{
  RNA_int_set(op->ptr, "debug_value", G.debug_value);
  return WM_operator_props_dialog_popup(C, op, 250, IFACE_("Set Debug Value"), IFACE_("Set"));
}

static void WM_OT_debug_menu(wmOperatorType *ot)
{
  ot->name = "Debug Menu";
  ot->idname = "WM_OT_debug_menu";
  ot->description = "Open a popup to set the debug level";

  ot->invoke = wm_debug_menu_invoke;
  ot->exec = wm_debug_menu_exec;
  ot->poll = WM_operator_winactive;

  ot->prop = RNA_def_int(
      ot->srna, "debug_value", 0, SHRT_MIN, SHRT_MAX, "Debug Value", "", -10000, 10000);
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Reset Defaults Operator
 * \{ */

static wmOperatorStatus wm_operator_defaults_exec(bContext *C, wmOperator *op)
{
  PointerRNA ptr = CTX_data_pointer_get_type(C, "active_operator", &RNA_Operator);

  if (!ptr.data) {
    BKE_report(op->reports, RPT_ERROR, "No operator in context");
    return OPERATOR_CANCELLED;
  }

  WM_operator_properties_reset((wmOperator *)ptr.data);
  return OPERATOR_FINISHED;
}

/* Used by operator preset menu. pre-2.65 this was a 'Reset' button. */
static void WM_OT_operator_defaults(wmOperatorType *ot)
{
  ot->name = "Restore Operator Defaults";
  ot->idname = "WM_OT_operator_defaults";
  ot->description = "Set the active operator to its default values";

  ot->exec = wm_operator_defaults_exec;

  ot->flag = OPTYPE_INTERNAL;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Operator/Menu Search Operator
 * \{ */

enum SearchType {
  SEARCH_TYPE_OPERATOR = 0,
  SEARCH_TYPE_MENU = 1,
  SEARCH_TYPE_SINGLE_MENU = 2,
};

struct SearchPopupInit_Data {
  SearchType search_type;
  int size[2];
  std::string single_menu_idname;
};

static char g_search_text[256] = "";

static uiBlock *wm_block_search_menu(bContext *C, ARegion *region, void *userdata)
{
  const SearchPopupInit_Data *init_data = static_cast<const SearchPopupInit_Data *>(userdata);

  uiBlock *block = UI_block_begin(C, region, "_popup", blender::ui::EmbossType::Emboss);
  UI_block_flag_enable(block, UI_BLOCK_LOOP | UI_BLOCK_MOVEMOUSE_QUIT | UI_BLOCK_SEARCH_MENU);
  UI_block_theme_style_set(block, UI_BLOCK_THEME_STYLE_POPUP);

  uiBut *but = uiDefSearchBut(block,
                              g_search_text,
                              0,
                              ICON_VIEWZOOM,
                              sizeof(g_search_text),
                              0,
                              0,
                              init_data->size[0],
                              UI_UNIT_Y,
                              "");

  if (init_data->search_type == SEARCH_TYPE_OPERATOR) {
    UI_but_func_operator_search(but);
  }
  else if (init_data->search_type == SEARCH_TYPE_MENU) {
    UI_but_func_menu_search(but);
  }
  else if (init_data->search_type == SEARCH_TYPE_SINGLE_MENU) {
    UI_but_func_menu_search(but, init_data->single_menu_idname.c_str());
    UI_but_flag2_enable(but, UI_BUT2_ACTIVATE_ON_INIT_NO_SELECT);
  }
  else {
    BLI_assert_unreachable();
  }

  UI_but_flag_enable(but, UI_BUT_ACTIVATE_ON_INIT);

  /* Fake button, it holds space for search items. */
  const int height = init_data->size[1] - UI_SEARCHBOX_BOUNDS;
  uiDefBut(block,
           ButType::Label,
           0,
           "",
           0,
           -height,
           init_data->size[0],
           height,
           nullptr,
           0,
           0,
           std::nullopt);

  /* Move it downwards, mouse over button. */
  UI_block_bounds_set_popup(block, UI_SEARCHBOX_BOUNDS, blender::int2{0, -UI_UNIT_Y});

  return block;
}

static wmOperatorStatus wm_search_menu_exec(bContext * /*C*/, wmOperator * /*op*/)
{
  return OPERATOR_FINISHED;
}

static wmOperatorStatus wm_search_menu_invoke(bContext *C, wmOperator *op, const wmEvent *event)
{
  /* Exception for launching via space-bar. */
  if (event->type == EVT_SPACEKEY) {
    bool ok = true;
    ScrArea *area = CTX_wm_area(C);
    if (area) {
      if (area->spacetype == SPACE_CONSOLE) {
        /* So we can use the shortcut in the console. */
        ok = false;
      }
      else if (area->spacetype == SPACE_TEXT) {
        /* So we can use the space-bar in the text editor. */
        ok = false;
      }
    }
    else {
      Object *editob = CTX_data_edit_object(C);
      if (editob && editob->type == OB_FONT) {
        /* So we can use the space-bar for entering text. */
        ok = false;
      }
    }
    if (!ok) {
      return OPERATOR_PASS_THROUGH;
    }
  }

  SearchType search_type;
  if (STREQ(op->type->idname, "WM_OT_search_menu")) {
    search_type = SEARCH_TYPE_MENU;
  }
  else if (STREQ(op->type->idname, "WM_OT_search_single_menu")) {
    search_type = SEARCH_TYPE_SINGLE_MENU;
  }
  else {
    search_type = SEARCH_TYPE_OPERATOR;
  }

  static SearchPopupInit_Data data{};

  if (search_type == SEARCH_TYPE_SINGLE_MENU) {
    data.single_menu_idname = RNA_string_get(op->ptr, "menu_idname");

    std::string buffer = RNA_string_get(op->ptr, "initial_query");
    STRNCPY(g_search_text, buffer.c_str());
  }
  else {
    g_search_text[0] = '\0';
  }

  data.search_type = search_type;
  data.size[0] = UI_searchbox_size_x() * 2;
  data.size[1] = UI_searchbox_size_y();

  UI_popup_block_invoke_ex(C, wm_block_search_menu, &data, nullptr, false);

  return OPERATOR_INTERFACE;
}

static void WM_OT_search_menu(wmOperatorType *ot)
{
  ot->name = "Search Menu";
  ot->idname = "WM_OT_search_menu";
  ot->description = "Pop-up a search over all menus in the current context";

  ot->invoke = wm_search_menu_invoke;
  ot->exec = wm_search_menu_exec;
  ot->poll = WM_operator_winactive;
}

static void WM_OT_search_operator(wmOperatorType *ot)
{
  ot->name = "Search Operator";
  ot->idname = "WM_OT_search_operator";
  ot->description = "Pop-up a search over all available operators in current context";

  ot->invoke = wm_search_menu_invoke;
  ot->exec = wm_search_menu_exec;
  ot->poll = WM_operator_winactive;
}

static void WM_OT_search_single_menu(wmOperatorType *ot)
{
  ot->name = "Search Single Menu";
  ot->idname = "WM_OT_search_single_menu";
  ot->description = "Pop-up a search for a menu in current context";

  ot->invoke = wm_search_menu_invoke;
  ot->exec = wm_search_menu_exec;
  ot->poll = WM_operator_winactive;

  RNA_def_string(ot->srna, "menu_idname", nullptr, 0, "Menu Name", "Menu to search in");
  RNA_def_string(ot->srna,
                 "initial_query",
                 nullptr,
                 0,
                 "Initial Query",
                 "Query to insert into the search box");
}

static wmOperatorStatus wm_call_menu_exec(bContext *C, wmOperator *op)
{
  char idname[BKE_ST_MAXNAME];
  RNA_string_get(op->ptr, "name", idname);

  return UI_popup_menu_invoke(C, idname, op->reports);
}

static std::string wm_call_menu_get_name(wmOperatorType *ot, PointerRNA *ptr)
{
  char idname[BKE_ST_MAXNAME];
  RNA_string_get(ptr, "name", idname);
  MenuType *mt = WM_menutype_find(idname, true);
  return (mt) ? CTX_IFACE_(mt->translation_context, mt->label) :
                CTX_IFACE_(ot->translation_context, ot->name);
}

static void WM_OT_call_menu(wmOperatorType *ot)
{
  ot->name = "Call Menu";
  ot->idname = "WM_OT_call_menu";
  ot->description = "Open a predefined menu";

  ot->exec = wm_call_menu_exec;
  ot->poll = WM_operator_winactive;
  ot->get_name = wm_call_menu_get_name;

  ot->flag = OPTYPE_INTERNAL;

  PropertyRNA *prop;

  prop = RNA_def_string(ot->srna, "name", nullptr, BKE_ST_MAXNAME, "Name", "Name of the menu");
  RNA_def_property_string_search_func_runtime(
      prop,
      WM_menutype_idname_visit_for_search,
      /* Only a suggestion as menu items may be referenced from add-ons that have been disabled. */
      (PROP_STRING_SEARCH_SORT | PROP_STRING_SEARCH_SUGGESTION));
}

static wmOperatorStatus wm_call_pie_menu_invoke(bContext *C, wmOperator *op, const wmEvent *event)
{
  char idname[BKE_ST_MAXNAME];
  RNA_string_get(op->ptr, "name", idname);

  return UI_pie_menu_invoke(C, idname, event);
}

static wmOperatorStatus wm_call_pie_menu_exec(bContext *C, wmOperator *op)
{
  char idname[BKE_ST_MAXNAME];
  RNA_string_get(op->ptr, "name", idname);

  return UI_pie_menu_invoke(C, idname, CTX_wm_window(C)->eventstate);
}

static void WM_OT_call_menu_pie(wmOperatorType *ot)
{
  ot->name = "Call Pie Menu";
  ot->idname = "WM_OT_call_menu_pie";
  ot->description = "Open a predefined pie menu";

  ot->invoke = wm_call_pie_menu_invoke;
  ot->exec = wm_call_pie_menu_exec;
  ot->poll = WM_operator_winactive;
  ot->get_name = wm_call_menu_get_name;

  ot->flag = OPTYPE_INTERNAL;

  PropertyRNA *prop;

  prop = RNA_def_string(ot->srna, "name", nullptr, BKE_ST_MAXNAME, "Name", "Name of the pie menu");
  RNA_def_property_string_search_func_runtime(
      prop,
      WM_menutype_idname_visit_for_search,
      /* Only a suggestion as menu items may be referenced from add-ons that have been disabled. */
      (PROP_STRING_SEARCH_SORT | PROP_STRING_SEARCH_SUGGESTION));
}

static wmOperatorStatus wm_call_panel_exec(bContext *C, wmOperator *op)
{
  char idname[BKE_ST_MAXNAME];
  RNA_string_get(op->ptr, "name", idname);
  const bool keep_open = RNA_boolean_get(op->ptr, "keep_open");

  return UI_popover_panel_invoke(C, idname, keep_open, op->reports);
}

static std::string wm_call_panel_get_name(wmOperatorType *ot, PointerRNA *ptr)
{
  char idname[BKE_ST_MAXNAME];
  RNA_string_get(ptr, "name", idname);
  PanelType *pt = WM_paneltype_find(idname, true);
  return (pt) ? CTX_IFACE_(pt->translation_context, pt->label) :
                CTX_IFACE_(ot->translation_context, ot->name);
}

static void WM_OT_call_panel(wmOperatorType *ot)
{
  ot->name = "Call Panel";
  ot->idname = "WM_OT_call_panel";
  ot->description = "Open a predefined panel";

  ot->exec = wm_call_panel_exec;
  ot->poll = WM_operator_winactive;
  ot->get_name = wm_call_panel_get_name;

  ot->flag = OPTYPE_INTERNAL;

  PropertyRNA *prop;

  prop = RNA_def_string(ot->srna, "name", nullptr, BKE_ST_MAXNAME, "Name", "Name of the menu");
  RNA_def_property_string_search_func_runtime(
      prop,
      WM_paneltype_idname_visit_for_search,
      /* Only a suggestion as menu items may be referenced from add-ons that have been disabled. */
      (PROP_STRING_SEARCH_SORT | PROP_STRING_SEARCH_SUGGESTION));
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
  prop = RNA_def_boolean(ot->srna, "keep_open", true, "Keep Open", "");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
}

static wmOperatorStatus asset_shelf_popover_invoke(bContext *C,
                                                   wmOperator *op,
                                                   const wmEvent * /*event*/)
{
  std::string asset_shelf_id = RNA_string_get(op->ptr, "name");

  if (!blender::ui::asset_shelf_popover_invoke(*C, asset_shelf_id, *op->reports)) {
    return OPERATOR_CANCELLED | OPERATOR_PASS_THROUGH;
  }

  return OPERATOR_INTERFACE;
}

/* Needs to be defined at WM level to be globally accessible. */
static void WM_OT_call_asset_shelf_popover(wmOperatorType *ot)
{
  /* identifiers */
  ot->name = "Call Asset Shelf Popover";
  ot->idname = "WM_OT_call_asset_shelf_popover";
  ot->description = "Open a predefined asset shelf in a popup";

  /* API callbacks. */
  ot->invoke = asset_shelf_popover_invoke;

  ot->flag = OPTYPE_INTERNAL;

  RNA_def_string(ot->srna,
                 "name",
                 nullptr,
                 0,
                 "Asset Shelf Name",
                 "Identifier of the asset shelf to display");
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Window/Screen Operators
 * \{ */

/**
 * This poll functions is needed in place of #WM_operator_winactive
 * while it crashes on full screen.
 */
static bool wm_operator_winactive_normal(bContext *C)
{
  wmWindow *win = CTX_wm_window(C);
  bScreen *screen;

  if (win == nullptr) {
    return false;
  }
  if (!((screen = WM_window_get_active_screen(win)) && (screen->state == SCREENNORMAL))) {
    return false;
  }
  if (G.background) {
    return false;
  }

  return true;
}

static bool wm_operator_winactive_not_full(bContext *C)
{
  wmWindow *win = CTX_wm_window(C);
  bScreen *screen;

  if (win == nullptr) {
    return false;
  }
  if (!((screen = WM_window_get_active_screen(win)) && (screen->state != SCREENFULL))) {
    return false;
  }
  if (G.background) {
    return false;
  }

  return true;
}

/* Included for script-access. */
static void WM_OT_window_close(wmOperatorType *ot)
{
  ot->name = "Close Window";
  ot->idname = "WM_OT_window_close";
  ot->description = "Close the current window";

  ot->exec = wm_window_close_exec;
  ot->poll = WM_operator_winactive;
}

static void WM_OT_window_new(wmOperatorType *ot)
{
  ot->name = "New Window";
  ot->idname = "WM_OT_window_new";
  ot->description = "Create a new window";

  ot->exec = wm_window_new_exec;
  ot->poll = wm_operator_winactive_not_full;
}

static void WM_OT_window_new_main(wmOperatorType *ot)
{
  ot->name = "New Main Window";
  ot->idname = "WM_OT_window_new_main";
  ot->description = "Create a new main window with its own workspace and scene selection";

  ot->exec = wm_window_new_main_exec;
  ot->poll = wm_operator_winactive_normal;
}

static void WM_OT_window_fullscreen_toggle(wmOperatorType *ot)
{
  ot->name = "Toggle Window Fullscreen";
  ot->idname = "WM_OT_window_fullscreen_toggle";
  ot->description = "Toggle the current window full-screen";

  ot->exec = wm_window_fullscreen_toggle_exec;
  ot->poll = WM_operator_winactive;
}

static wmOperatorStatus wm_exit_blender_exec(bContext *C, wmOperator * /*op*/)
{
  wm_exit_schedule_delayed(C);
  return OPERATOR_FINISHED;
}

static wmOperatorStatus wm_exit_blender_invoke(bContext *C,
                                               wmOperator * /*op*/,
                                               const wmEvent * /*event*/)
{
  if (U.uiflag & USER_SAVE_PROMPT) {
    wm_quit_with_optional_confirmation_prompt(C, CTX_wm_window(C));
  }
  else {
    wm_exit_schedule_delayed(C);
  }
  return OPERATOR_FINISHED;
}

static void WM_OT_quit_blender(wmOperatorType *ot)
{
  ot->name = "Quit Blender";
  ot->idname = "WM_OT_quit_blender";
  ot->description = "Quit Blender";

  ot->invoke = wm_exit_blender_invoke;
  ot->exec = wm_exit_blender_exec;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Console Toggle Operator (WIN32 only)
 * \{ */

#if defined(WIN32)

static wmOperatorStatus wm_console_toggle_exec(bContext * /*C*/, wmOperator * /*op*/)
{
  GHOST_setConsoleWindowState(GHOST_kConsoleWindowStateToggle);
  return OPERATOR_FINISHED;
}

static void WM_OT_console_toggle(wmOperatorType *ot)
{
  /* XXX Have to mark these for xgettext, as under linux they do not exists... */
  ot->name = CTX_N_(BLT_I18NCONTEXT_OPERATOR_DEFAULT, "Toggle System Console");
  ot->idname = "WM_OT_console_toggle";
  ot->description = N_("Toggle System Console");

  ot->exec = wm_console_toggle_exec;
  ot->poll = WM_operator_winactive;
}

#endif

/** \} */

/* -------------------------------------------------------------------- */
/** \name default paint cursors, draw always around cursor
 *
 * - Returns handler to free.
 * - `poll(bContext)`: returns 1 if draw should happen.
 * - `draw(bContext)`: drawing callback for paint cursor.
 *
 * \{ */

wmPaintCursor *WM_paint_cursor_activate(short space_type,
                                        short region_type,
                                        bool (*poll)(bContext *C),
                                        wmPaintCursorDraw draw,
                                        void *customdata)
{
  wmWindowManager *wm = static_cast<wmWindowManager *>(G_MAIN->wm.first);

  wmPaintCursor *pc = MEM_callocN<wmPaintCursor>("paint cursor");

  BLI_addtail(&wm->runtime->paintcursors, pc);

  pc->customdata = customdata;
  pc->poll = poll;
  pc->draw = draw;

  pc->space_type = space_type;
  pc->region_type = region_type;

  return pc;
}

bool WM_paint_cursor_end(wmPaintCursor *handle)
{
  wmWindowManager *wm = static_cast<wmWindowManager *>(G_MAIN->wm.first);
  LISTBASE_FOREACH (wmPaintCursor *, pc, &wm->runtime->paintcursors) {
    if (pc == handle) {
      BLI_remlink(&wm->runtime->paintcursors, pc);
      MEM_freeN(pc);
      return true;
    }
  }
  return false;
}

void WM_paint_cursor_remove_by_type(wmWindowManager *wm, void *draw_fn, void (*free)(void *))
{
  LISTBASE_FOREACH_MUTABLE (wmPaintCursor *, pc, &wm->runtime->paintcursors) {
    if (pc->draw == draw_fn) {
      if (free) {
        free(pc->customdata);
      }
      BLI_remlink(&wm->runtime->paintcursors, pc);
      MEM_freeN(pc);
    }
  }
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Radial Control Operator
 * \{ */

#define WM_RADIAL_CONTROL_DISPLAY_SIZE (200 * UI_SCALE_FAC)
#define WM_RADIAL_CONTROL_DISPLAY_MIN_SIZE (35 * UI_SCALE_FAC)
#define WM_RADIAL_CONTROL_DISPLAY_WIDTH \
  (WM_RADIAL_CONTROL_DISPLAY_SIZE - WM_RADIAL_CONTROL_DISPLAY_MIN_SIZE)
#define WM_RADIAL_MAX_STR 10

struct RadialControl {
  PropertyType type;
  PropertySubType subtype;
  PointerRNA ptr, col_ptr, fill_col_ptr, rot_ptr, zoom_ptr, image_id_ptr;
  PointerRNA fill_col_override_ptr, fill_col_override_test_ptr;
  PropertyRNA *prop = nullptr;
  PropertyRNA *col_prop = nullptr;
  PropertyRNA *fill_col_prop = nullptr;
  PropertyRNA *rot_prop = nullptr;
  PropertyRNA *zoom_prop = nullptr;
  PropertyRNA *fill_col_override_prop = nullptr;
  PropertyRNA *fill_col_override_test_prop = nullptr;
  StructRNA *image_id_srna = nullptr;
  float initial_value = 0.0f;
  float current_value = 0.0f;
  float min_value = 0.0f;
  float max_value = 0.0f;
  /* Original screen space coordinates that the operator started on. */
  int initial_co[2] = {};
  /* Modified value of #initial_co to simplify calculating new values. */
  int initial_radial_center[2] = {};
  int slow_mouse[2] = {};
  bool slow_mode = false;
  Dial *dial = nullptr;
  blender::gpu::Texture *texture = nullptr;
  ListBase orig_paintcursors = {};
  bool use_secondary_tex = false;
  void *cursor = nullptr;
  NumInput num_input = {};
  int init_event = 0;
};

static void radial_control_update_header(wmOperator *op, bContext *C)
{
  RadialControl *rc = static_cast<RadialControl *>(op->customdata);
  char msg[UI_MAX_DRAW_STR];
  ScrArea *area = CTX_wm_area(C);
  Scene *scene = CTX_data_scene(C);

  if (hasNumInput(&rc->num_input)) {
    char num_str[NUM_STR_REP_LEN];
    outputNumInput(&rc->num_input, num_str, scene->unit);
    SNPRINTF(msg, "%s: %s", RNA_property_ui_name(rc->prop), num_str);
  }
  else {
    const char *ui_name = RNA_property_ui_name(rc->prop);
    switch (rc->subtype) {
      case PROP_NONE:
      case PROP_DISTANCE:
      case PROP_DISTANCE_DIAMETER:
        SNPRINTF(msg, "%s: %0.4f", ui_name, rc->current_value);
        break;
      case PROP_PIXEL:
      case PROP_PIXEL_DIAMETER:
        SNPRINTF(msg, "%s: %d", ui_name, int(rc->current_value)); /* XXX: round to nearest? */
        break;
      case PROP_PERCENTAGE:
        SNPRINTF(msg, "%s: %3.1f%%", ui_name, rc->current_value);
        break;
      case PROP_FACTOR:
        SNPRINTF(msg, "%s: %1.3f", ui_name, rc->current_value);
        break;
      case PROP_ANGLE:
        SNPRINTF(msg, "%s: %3.2f", ui_name, RAD2DEGF(rc->current_value));
        break;
      default:
        STRNCPY(msg, ui_name); /* XXX: No value? */
        break;
    }
  }

  ED_area_status_text(area, msg);
}

static void radial_control_set_initial_mouse(RadialControl *rc, const wmEvent *event)
{
  float d[2] = {0, 0};
  float zoom[2] = {1, 1};

  copy_v2_v2_int(rc->initial_radial_center, event->xy);
  copy_v2_v2_int(rc->initial_co, event->xy);

  switch (rc->subtype) {
    case PROP_NONE:
    case PROP_DISTANCE:
    case PROP_DISTANCE_DIAMETER:
    case PROP_PIXEL:
    case PROP_PIXEL_DIAMETER:
      d[0] = rc->initial_value;
      break;
    case PROP_PERCENTAGE:
      d[0] = (rc->initial_value) / 100.0f * WM_RADIAL_CONTROL_DISPLAY_WIDTH +
             WM_RADIAL_CONTROL_DISPLAY_MIN_SIZE;
      break;
    case PROP_FACTOR:
      d[0] = rc->initial_value * WM_RADIAL_CONTROL_DISPLAY_WIDTH +
             WM_RADIAL_CONTROL_DISPLAY_MIN_SIZE;
      break;
    case PROP_ANGLE:
      d[0] = WM_RADIAL_CONTROL_DISPLAY_SIZE * cosf(rc->initial_value);
      d[1] = WM_RADIAL_CONTROL_DISPLAY_SIZE * sinf(rc->initial_value);
      break;
    default:
      return;
  }

  if (rc->zoom_prop) {
    RNA_property_float_get_array(&rc->zoom_ptr, rc->zoom_prop, zoom);
    d[0] *= zoom[0];
    d[1] *= zoom[1];
  }

  rc->initial_radial_center[0] -= d[0];
  rc->initial_radial_center[1] -= d[1];
}

static void radial_control_set_tex(RadialControl *rc)
{
  ImBuf *ibuf;

  switch (RNA_type_to_ID_code(rc->image_id_ptr.type)) {
    case ID_BR:
      if ((ibuf = BKE_brush_gen_radial_control_imbuf(static_cast<Brush *>(rc->image_id_ptr.data),
                                                     rc->use_secondary_tex,
                                                     !ELEM(rc->subtype,
                                                           PROP_NONE,
                                                           PROP_PIXEL,
                                                           PROP_PIXEL_DIAMETER,
                                                           PROP_DISTANCE,
                                                           PROP_DISTANCE_DIAMETER))))
      {

        rc->texture = GPU_texture_create_2d("radial_control",
                                            ibuf->x,
                                            ibuf->y,
                                            1,
                                            blender::gpu::TextureFormat::UNORM_8,
                                            GPU_TEXTURE_USAGE_SHADER_READ,
                                            ibuf->float_buffer.data);

        GPU_texture_filter_mode(rc->texture, true);
        GPU_texture_swizzle_set(rc->texture, "111r");

        MEM_freeN(ibuf->float_buffer.data);
        MEM_freeN(ibuf);
      }
      break;
    default:
      break;
  }
}

static void radial_control_paint_tex(RadialControl *rc, float radius, float alpha)
{

  /* Set fill color. */
  float col[3] = {0, 0, 0};
  if (rc->fill_col_prop) {
    PointerRNA *fill_ptr;
    PropertyRNA *fill_prop;

    if (rc->fill_col_override_prop &&
        RNA_property_boolean_get(&rc->fill_col_override_test_ptr, rc->fill_col_override_test_prop))
    {
      fill_ptr = &rc->fill_col_override_ptr;
      fill_prop = rc->fill_col_override_prop;
    }
    else {
      fill_ptr = &rc->fill_col_ptr;
      fill_prop = rc->fill_col_prop;
    }

    RNA_property_float_get_array(fill_ptr, fill_prop, col);
  }

  GPUVertFormat *format = immVertexFormat();
  uint pos = GPU_vertformat_attr_add(format, "pos", blender::gpu::VertAttrType::SFLOAT_32_32);

  if (rc->texture) {
    uint texCoord = GPU_vertformat_attr_add(
        format, "texCoord", blender::gpu::VertAttrType::SFLOAT_32_32);

    /* Set up rotation if available. */
    if (rc->rot_prop) {
      float rot = RNA_property_float_get(&rc->rot_ptr, rc->rot_prop);
      GPU_matrix_push();
      GPU_matrix_rotate_2d(RAD2DEGF(rot));
    }

    immBindBuiltinProgram(GPU_SHADER_3D_IMAGE_COLOR);

    immUniformColor3fvAlpha(col, alpha);
    immBindTexture("image", rc->texture);

    /* Draw textured quad. */
    immBegin(GPU_PRIM_TRI_FAN, 4);

    immAttr2f(texCoord, 0, 0);
    immVertex2f(pos, -radius, -radius);

    immAttr2f(texCoord, 1, 0);
    immVertex2f(pos, radius, -radius);

    immAttr2f(texCoord, 1, 1);
    immVertex2f(pos, radius, radius);

    immAttr2f(texCoord, 0, 1);
    immVertex2f(pos, -radius, radius);

    immEnd();

    GPU_texture_unbind(rc->texture);

    /* Undo rotation. */
    if (rc->rot_prop) {
      GPU_matrix_pop();
    }
  }
  else {
    /* Flat color if no texture available. */
    immBindBuiltinProgram(GPU_SHADER_3D_UNIFORM_COLOR);
    immUniformColor3fvAlpha(col, alpha);
    imm_draw_circle_fill_2d(pos, 0.0f, 0.0f, radius, 40);
  }

  immUnbindProgram();
}

static void radial_control_paint_curve(uint pos, Brush *br, float radius, int line_segments)
{
  GPU_line_width(2.0f);
  immUniformColor4f(0.8f, 0.8f, 0.8f, 0.85f);
  float step = (radius * 2.0f) / float(line_segments);
  BKE_curvemapping_init(br->curve);
  immBegin(GPU_PRIM_LINES, line_segments * 2);
  for (int i = 0; i < line_segments; i++) {
    float h1 = BKE_brush_curve_strength_clamped(br, fabsf((i * step) - radius), radius);
    immVertex2f(pos, -radius + (i * step), h1 * radius);
    float h2 = BKE_brush_curve_strength_clamped(br, fabsf(((i + 1) * step) - radius), radius);
    immVertex2f(pos, -radius + ((i + 1) * step), h2 * radius);
  }
  immEnd();
}

static void radial_control_paint_cursor(bContext * /*C*/,
                                        const blender::int2 & /*xy*/,
                                        const blender::float2 & /*tilt*/,
                                        void *customdata)
{
  RadialControl *rc = static_cast<RadialControl *>(customdata);
  const uiStyle *style = UI_style_get();
  const uiFontStyle *fstyle = &style->widget;
  const int fontid = fstyle->uifont_id;
  short fstyle_points = fstyle->points;
  char str[WM_RADIAL_MAX_STR];
  short strdrawlen = 0;
  float strwidth, strheight;
  float r1 = 0.0f, r2 = 0.0f, rmin = 0.0, tex_radius, alpha;
  float zoom[2], col[4] = {1.0f, 1.0f, 1.0f, 1.0f};
  float text_color[4];

  switch (rc->subtype) {
    case PROP_NONE:
    case PROP_DISTANCE:
    case PROP_PIXEL:
      r1 = rc->current_value;
      r2 = rc->initial_value;
      tex_radius = r1;
      alpha = 0.75;
      break;
    case PROP_DISTANCE_DIAMETER:
    case PROP_PIXEL_DIAMETER:
      r1 = rc->current_value / 2.0f;
      r2 = rc->initial_value / 2.0f;
      tex_radius = r1;
      alpha = 0.75;
      break;
    case PROP_PERCENTAGE:
      r1 = rc->current_value / 100.0f * WM_RADIAL_CONTROL_DISPLAY_WIDTH +
           WM_RADIAL_CONTROL_DISPLAY_MIN_SIZE;
      r2 = tex_radius = WM_RADIAL_CONTROL_DISPLAY_SIZE;
      rmin = WM_RADIAL_CONTROL_DISPLAY_MIN_SIZE;
      SNPRINTF(str, "%3.1f%%", rc->current_value);
      strdrawlen = BLI_strlen_utf8(str);
      tex_radius = r1;
      alpha = 0.75;
      break;
    case PROP_FACTOR:
      r1 = rc->current_value * WM_RADIAL_CONTROL_DISPLAY_WIDTH +
           WM_RADIAL_CONTROL_DISPLAY_MIN_SIZE;
      r2 = tex_radius = WM_RADIAL_CONTROL_DISPLAY_SIZE;
      rmin = WM_RADIAL_CONTROL_DISPLAY_MIN_SIZE;
      alpha = rc->current_value / 2.0f + 0.5f;
      SNPRINTF(str, "%1.3f", rc->current_value);
      strdrawlen = BLI_strlen_utf8(str);
      break;
    case PROP_ANGLE:
      r1 = r2 = tex_radius = WM_RADIAL_CONTROL_DISPLAY_SIZE;
      alpha = 0.75;
      rmin = WM_RADIAL_CONTROL_DISPLAY_MIN_SIZE;
      SNPRINTF(str, "%3.2f", RAD2DEGF(rc->current_value));
      strdrawlen = BLI_strlen_utf8(str);
      break;
    default:
      tex_radius = WM_RADIAL_CONTROL_DISPLAY_SIZE; /* NOTE: this is a dummy value. */
      alpha = 0.75;
      break;
  }

  int x, y;
  if (rc->subtype == PROP_ANGLE) {
    /* Use the initial mouse position to draw the rotation preview. This avoids starting the
     * rotation in a random direction. */
    x = rc->initial_radial_center[0];
    y = rc->initial_radial_center[1];
  }
  else {
    /* Keep cursor in the original place. */
    x = rc->initial_co[0];
    y = rc->initial_co[1];
  }
  GPU_matrix_translate_2f(float(x), float(y));

  GPU_blend(GPU_BLEND_ALPHA);
  GPU_line_smooth(true);

  /* Apply zoom if available. */
  if (rc->zoom_prop) {
    RNA_property_float_get_array(&rc->zoom_ptr, rc->zoom_prop, zoom);
    GPU_matrix_scale_2fv(zoom);
  }

  /* Draw rotated texture. */
  radial_control_paint_tex(rc, tex_radius, alpha);

  /* Set line color. */
  if (rc->col_prop) {
    RNA_property_float_get_array(&rc->col_ptr, rc->col_prop, col);
  }

  GPUVertFormat *format = immVertexFormat();
  uint pos = GPU_vertformat_attr_add(format, "pos", blender::gpu::VertAttrType::SFLOAT_32_32);

  immBindBuiltinProgram(GPU_SHADER_3D_UNIFORM_COLOR);

  if (rc->subtype == PROP_ANGLE) {
    GPU_matrix_push();

    /* Draw original angle line. */
    GPU_matrix_rotate_3f(RAD2DEGF(rc->initial_value), 0.0f, 0.0f, 1.0f);
    immBegin(GPU_PRIM_LINES, 2);
    immVertex2f(pos, float(WM_RADIAL_CONTROL_DISPLAY_MIN_SIZE), 0.0f);
    immVertex2f(pos, float(WM_RADIAL_CONTROL_DISPLAY_SIZE), 0.0f);
    immEnd();

    /* Draw new angle line. */
    GPU_matrix_rotate_3f(RAD2DEGF(rc->current_value - rc->initial_value), 0.0f, 0.0f, 1.0f);
    immBegin(GPU_PRIM_LINES, 2);
    immVertex2f(pos, float(WM_RADIAL_CONTROL_DISPLAY_MIN_SIZE), 0.0f);
    immVertex2f(pos, float(WM_RADIAL_CONTROL_DISPLAY_SIZE), 0.0f);
    immEnd();

    GPU_matrix_pop();
  }

  /* Draw circles on top. */
  GPU_line_width(2.0f);
  immUniformColor3fvAlpha(col, 0.8f);
  imm_draw_circle_wire_2d(pos, 0.0f, 0.0f, r1, 80);

  GPU_line_width(1.0f);
  immUniformColor3fvAlpha(col, 0.5f);
  imm_draw_circle_wire_2d(pos, 0.0f, 0.0f, r2, 80);
  if (rmin > 0.0f) {
    /* Inner fill circle to increase the contrast of the value. */
    const float black[3] = {0.0f};
    immUniformColor3fvAlpha(black, 0.2f);
    imm_draw_circle_fill_2d(pos, 0.0, 0.0f, rmin, 80);

    immUniformColor3fvAlpha(col, 0.5f);
    imm_draw_circle_wire_2d(pos, 0.0, 0.0f, rmin, 80);
  }

  /* Draw curve falloff preview. */
  if (RNA_type_to_ID_code(rc->image_id_ptr.type) == ID_BR && rc->subtype == PROP_FACTOR) {
    Brush *br = static_cast<Brush *>(rc->image_id_ptr.data);
    if (br) {
      radial_control_paint_curve(pos, br, r2, 120);
    }
  }

  immUnbindProgram();

  BLF_size(fontid, 1.75f * fstyle_points * UI_SCALE_FAC);
  UI_GetThemeColor4fv(TH_TEXT_HI, text_color);
  BLF_color4fv(fontid, text_color);

  /* Draw value. */
  BLF_width_and_height(fontid, str, strdrawlen, &strwidth, &strheight);
  BLF_position(fontid, -0.5f * strwidth, -0.5f * strheight, 0.0f);
  BLF_draw(fontid, str, strdrawlen);

  GPU_blend(GPU_BLEND_NONE);
  GPU_line_smooth(false);
}

enum RCPropFlags {
  RC_PROP_ALLOW_MISSING = 1,
  RC_PROP_REQUIRE_FLOAT = 2,
  RC_PROP_REQUIRE_BOOL = 4,
};

/**
 * Attempt to retrieve the rna pointer/property from an rna path.
 *
 * \return 0 for failure, 1 for success, and also 1 if property is not set.
 */
static int radial_control_get_path(PointerRNA *ctx_ptr,
                                   wmOperator *op,
                                   const char *name,
                                   PointerRNA *r_ptr,
                                   PropertyRNA **r_prop,
                                   int req_length,
                                   RCPropFlags flags)
{
  PropertyRNA *unused_prop;

  /* Check flags. */
  if ((flags & RC_PROP_REQUIRE_BOOL) && (flags & RC_PROP_REQUIRE_FLOAT)) {
    BKE_report(op->reports, RPT_ERROR, "Property cannot be both boolean and float");
    return 0;
  }

  /* Get an rna string path from the operator's properties. */
  std::string str = RNA_string_get(op->ptr, name);
  if (str.empty()) {
    if (r_prop) {
      *r_prop = nullptr;
    }
    return 1;
  }

  if (!r_prop) {
    r_prop = &unused_prop;
  }

  /* Get rna from path. */
  if (!RNA_path_resolve(ctx_ptr, str.c_str(), r_ptr, r_prop)) {
    if (flags & RC_PROP_ALLOW_MISSING) {
      return 1;
    }
    BKE_reportf(op->reports, RPT_ERROR, "Could not resolve path '%s'", name);
    return 0;
  }

  /* Check property type. */
  if (flags & (RC_PROP_REQUIRE_BOOL | RC_PROP_REQUIRE_FLOAT)) {
    PropertyType prop_type = RNA_property_type(*r_prop);

    if (((flags & RC_PROP_REQUIRE_BOOL) && (prop_type != PROP_BOOLEAN)) ||
        ((flags & RC_PROP_REQUIRE_FLOAT) && (prop_type != PROP_FLOAT)))
    {
      BKE_reportf(op->reports, RPT_ERROR, "Property from path '%s' is not a float", name);
      return 0;
    }
  }

  /* Check property's array length. */
  int len;
  if (*r_prop && (len = RNA_property_array_length(r_ptr, *r_prop)) != req_length) {
    BKE_reportf(op->reports,
                RPT_ERROR,
                "Property from path '%s' has length %d instead of %d",
                name,
                len,
                req_length);
    return 0;
  }

  /* Success. */
  return 1;
}

/* Initialize the rna pointers and properties using rna paths. */
static int radial_control_get_properties(bContext *C, wmOperator *op)
{
  RadialControl *rc = static_cast<RadialControl *>(op->customdata);

  PointerRNA ctx_ptr = RNA_pointer_create_discrete(nullptr, &RNA_Context, C);

  /* Check if we use primary or secondary path. */
  PointerRNA use_secondary_ptr;
  PropertyRNA *use_secondary_prop = nullptr;
  if (!radial_control_get_path(&ctx_ptr,
                               op,
                               "use_secondary",
                               &use_secondary_ptr,
                               &use_secondary_prop,
                               0,
                               RCPropFlags(RC_PROP_ALLOW_MISSING | RC_PROP_REQUIRE_BOOL)))
  {
    return 0;
  }

  const char *data_path;
  if (use_secondary_prop && RNA_property_boolean_get(&use_secondary_ptr, use_secondary_prop)) {
    data_path = "data_path_secondary";
  }
  else {
    data_path = "data_path_primary";
  }

  if (!radial_control_get_path(&ctx_ptr, op, data_path, &rc->ptr, &rc->prop, 0, RCPropFlags(0))) {
    return 0;
  }

  /* Data path is required. */
  if (!rc->prop) {
    return 0;
  }

  if (!radial_control_get_path(
          &ctx_ptr, op, "rotation_path", &rc->rot_ptr, &rc->rot_prop, 0, RC_PROP_REQUIRE_FLOAT))
  {
    return 0;
  }

  if (!radial_control_get_path(
          &ctx_ptr, op, "color_path", &rc->col_ptr, &rc->col_prop, 4, RC_PROP_REQUIRE_FLOAT))
  {
    return 0;
  }

  if (!radial_control_get_path(&ctx_ptr,
                               op,
                               "fill_color_path",
                               &rc->fill_col_ptr,
                               &rc->fill_col_prop,
                               3,
                               RC_PROP_REQUIRE_FLOAT))
  {
    return 0;
  }

  if (!radial_control_get_path(&ctx_ptr,
                               op,
                               "fill_color_override_path",
                               &rc->fill_col_override_ptr,
                               &rc->fill_col_override_prop,
                               3,
                               RC_PROP_REQUIRE_FLOAT))
  {
    return 0;
  }
  if (!radial_control_get_path(&ctx_ptr,
                               op,
                               "fill_color_override_test_path",
                               &rc->fill_col_override_test_ptr,
                               &rc->fill_col_override_test_prop,
                               0,
                               RC_PROP_REQUIRE_BOOL))
  {
    return 0;
  }

  /* Slightly ugly; allow this property to not resolve correctly.
   * Needed because 3d texture paint shares the same key-map as 2d image paint. */
  if (!radial_control_get_path(&ctx_ptr,
                               op,
                               "zoom_path",
                               &rc->zoom_ptr,
                               &rc->zoom_prop,
                               2,
                               RCPropFlags(RC_PROP_REQUIRE_FLOAT | RC_PROP_ALLOW_MISSING)))
  {
    return 0;
  }

  if (!radial_control_get_path(
          &ctx_ptr, op, "image_id", &rc->image_id_ptr, nullptr, 0, RCPropFlags(0)))
  {
    return 0;
  }
  if (rc->image_id_ptr.data) {
    /* Extra check, pointer must be to an ID. */
    if (!RNA_struct_is_ID(rc->image_id_ptr.type)) {
      BKE_report(op->reports, RPT_ERROR, "Pointer from path image_id is not an ID");
      return 0;
    }
  }

  rc->use_secondary_tex = RNA_boolean_get(op->ptr, "secondary_tex");

  return 1;
}

static wmOperatorStatus radial_control_invoke(bContext *C, wmOperator *op, const wmEvent *event)
{
  op->customdata = MEM_new<RadialControl>(__func__);
  if (!op->customdata) {
    return OPERATOR_CANCELLED;
  }
  RadialControl *rc = static_cast<RadialControl *>(op->customdata);

  if (!radial_control_get_properties(C, op)) {
    MEM_delete(rc);
    return OPERATOR_CANCELLED;
  }

  /* Get type, initial, min, and max values of the property. */
  switch (rc->type = RNA_property_type(rc->prop)) {
    case PROP_INT: {
      int value, min, max, step;

      value = RNA_property_int_get(&rc->ptr, rc->prop);
      RNA_property_int_ui_range(&rc->ptr, rc->prop, &min, &max, &step);

      rc->initial_value = value;
      rc->min_value = min_ii(value, min);
      rc->max_value = max_ii(value, max);
      break;
    }
    case PROP_FLOAT: {
      float value, min, max, step, precision;

      value = RNA_property_float_get(&rc->ptr, rc->prop);
      RNA_property_float_ui_range(&rc->ptr, rc->prop, &min, &max, &step, &precision);

      rc->initial_value = value;
      rc->min_value = min_ff(value, min);
      rc->max_value = max_ff(value, max);
      break;
    }
    default:
      BKE_report(op->reports, RPT_ERROR, "Property must be an integer or a float");
      MEM_delete(rc);
      return OPERATOR_CANCELLED;
  }

  /* Initialize numerical input. */
  initNumInput(&rc->num_input);
  rc->num_input.idx_max = 0;
  rc->num_input.val_flag[0] |= NUM_NO_NEGATIVE;
  rc->num_input.unit_sys = USER_UNIT_NONE;
  rc->num_input.unit_type[0] = RNA_SUBTYPE_UNIT_VALUE(RNA_property_unit(rc->prop));

  /* Get subtype of property. */
  rc->subtype = RNA_property_subtype(rc->prop);
  if (!ELEM(rc->subtype,
            PROP_NONE,
            PROP_DISTANCE,
            PROP_DISTANCE_DIAMETER,
            PROP_FACTOR,
            PROP_PERCENTAGE,
            PROP_ANGLE,
            PROP_PIXEL,
            PROP_PIXEL_DIAMETER))
  {
    BKE_report(op->reports,
               RPT_ERROR,
               "Property must be a none, distance, factor, percentage, angle, or pixel");
    MEM_delete(rc);
    return OPERATOR_CANCELLED;
  }

  rc->current_value = rc->initial_value;
  radial_control_set_initial_mouse(rc, event);
  radial_control_set_tex(rc);

  rc->init_event = WM_userdef_event_type_from_keymap_type(event->type);

  /* Temporarily disable other paint cursors. */
  wmWindowManager *wm = CTX_wm_manager(C);
  rc->orig_paintcursors = wm->runtime->paintcursors;
  BLI_listbase_clear(&wm->runtime->paintcursors);

  /* Add radial control paint cursor. */
  rc->cursor = WM_paint_cursor_activate(
      SPACE_TYPE_ANY, RGN_TYPE_ANY, op->type->poll, radial_control_paint_cursor, rc);

  WM_event_add_modal_handler(C, op);

  return OPERATOR_RUNNING_MODAL;
}

static void radial_control_set_value(RadialControl *rc, float val)
{
  switch (rc->type) {
    case PROP_INT:
      RNA_property_int_set(&rc->ptr, rc->prop, val);
      break;
    case PROP_FLOAT:
      RNA_property_float_set(&rc->ptr, rc->prop, val);
      break;
    default:
      break;
  }
}

static void radial_control_cancel(bContext *C, wmOperator *op)
{
  RadialControl *rc = static_cast<RadialControl *>(op->customdata);
  wmWindowManager *wm = CTX_wm_manager(C);
  ScrArea *area = CTX_wm_area(C);

  if (rc->dial) {
    BLI_dial_free(rc->dial);
    rc->dial = nullptr;
  }

  ED_area_status_text(area, nullptr);

  WM_paint_cursor_end(static_cast<wmPaintCursor *>(rc->cursor));

  /* Restore original paint cursors. */
  wm->runtime->paintcursors = rc->orig_paintcursors;

  /* Not sure if this is a good notifier to use;
   * intended purpose is to update the UI so that the
   * new value is displayed in sliders/number-fields. */
  WM_event_add_notifier(C, NC_WINDOW, nullptr);

  if (rc->texture != nullptr) {
    GPU_texture_free(rc->texture);
  }

  MEM_delete(rc);
}

static wmOperatorStatus radial_control_modal(bContext *C, wmOperator *op, const wmEvent *event)
{
  RadialControl *rc = static_cast<RadialControl *>(op->customdata);
  float new_value, dist = 0.0f, zoom[2];
  float delta[2];
  wmOperatorStatus ret = OPERATOR_RUNNING_MODAL;
  float angle_precision = 0.0f;
  const bool has_numInput = hasNumInput(&rc->num_input);
  bool handled = false;
  float numValue;
  /* TODO: fix hard-coded events. */

  bool snap = (event->modifier & KM_CTRL) != 0;

  /* Modal numinput active, try to handle numeric inputs first... */
  if (event->val == KM_PRESS && has_numInput && handleNumInput(C, &rc->num_input, event)) {
    handled = true;
    applyNumInput(&rc->num_input, &numValue);

    if (rc->subtype == PROP_ANGLE) {
      numValue = fmod(numValue, 2.0f * float(M_PI));
      if (numValue < 0.0f) {
        numValue += 2.0f * float(M_PI);
      }
    }

    CLAMP(numValue, rc->min_value, rc->max_value);
    new_value = numValue;

    radial_control_set_value(rc, new_value);
    rc->current_value = new_value;
    radial_control_update_header(op, C);
    return OPERATOR_RUNNING_MODAL;
  }

  handled = false;
  switch (event->type) {
    case EVT_ESCKEY:
    case RIGHTMOUSE:
      /* Canceled; restore original value. */
      if (rc->init_event != RIGHTMOUSE) {
        radial_control_set_value(rc, rc->initial_value);
        ret = OPERATOR_CANCELLED;
      }
      break;

    case LEFTMOUSE:
    case EVT_PADENTER:
    case EVT_RETKEY:
      /* Done; value already set. */
      /* Keep the RNA update separate from setting the value, for some properties this could lead
       * to a continues flickering due to invalidating the overlay texture. */
      RNA_property_update(C, &rc->ptr, rc->prop);
      ret = OPERATOR_FINISHED;
      break;

    case MOUSEMOVE:
      if (!has_numInput) {
        if (rc->slow_mode) {
          if (rc->subtype == PROP_ANGLE) {
            /* Calculate the initial angle here first. */
            delta[0] = rc->initial_radial_center[0] - rc->slow_mouse[0];
            delta[1] = rc->initial_radial_center[1] - rc->slow_mouse[1];

            /* Precision angle gets calculated from dial and gets added later. */
            angle_precision = -0.1f * BLI_dial_angle(rc->dial,
                                                     blender::float2{float(event->xy[0]),
                                                                     float(event->xy[1])});
          }
          else {
            delta[0] = rc->initial_radial_center[0] - rc->slow_mouse[0];
            delta[1] = 0.0f;

            if (rc->zoom_prop) {
              RNA_property_float_get_array(&rc->zoom_ptr, rc->zoom_prop, zoom);
              delta[0] /= zoom[0];
            }

            dist = len_v2(delta);

            delta[0] = event->xy[0] - rc->slow_mouse[0];

            if (rc->zoom_prop) {
              delta[0] /= zoom[0];
            }

            dist = dist + 0.1f * (delta[0]);
          }
        }
        else {
          delta[0] = float(rc->initial_radial_center[0] - event->xy[0]);
          delta[1] = float(rc->initial_radial_center[1] - event->xy[1]);
          if (rc->zoom_prop) {
            RNA_property_float_get_array(&rc->zoom_ptr, rc->zoom_prop, zoom);
            delta[0] /= zoom[0];
            delta[1] /= zoom[1];
          }
          if (rc->subtype == PROP_ANGLE) {
            dist = len_v2(delta);
          }
          else {
            dist = clamp_f(-delta[0], 0.0f, FLT_MAX);
          }
        }

        /* Calculate new value and apply snapping. */
        switch (rc->subtype) {
          case PROP_NONE:
          case PROP_DISTANCE:
          case PROP_DISTANCE_DIAMETER:
          case PROP_PIXEL:
          case PROP_PIXEL_DIAMETER:
            new_value = dist;
            if (snap) {
              new_value = (int(new_value) + 5) / 10 * 10;
            }
            break;
          case PROP_PERCENTAGE:
            new_value = ((dist - WM_RADIAL_CONTROL_DISPLAY_MIN_SIZE) /
                         WM_RADIAL_CONTROL_DISPLAY_WIDTH) *
                        100.0f;
            if (snap) {
              new_value = int(new_value + 2.5f) / 5 * 5;
            }
            break;
          case PROP_FACTOR:
            new_value = (WM_RADIAL_CONTROL_DISPLAY_SIZE - dist) / WM_RADIAL_CONTROL_DISPLAY_WIDTH;
            if (snap) {
              new_value = (int(ceil(new_value * 10.0f)) * 10.0f) / 100.0f;
            }
            /* Invert new value to increase the factor moving the mouse to the right. */
            new_value = 1 - new_value;
            break;
          case PROP_ANGLE:
            new_value = atan2f(delta[1], delta[0]) + float(M_PI) + angle_precision;
            new_value = fmod(new_value, 2.0f * float(M_PI));
            if (new_value < 0.0f) {
              new_value += 2.0f * float(M_PI);
            }
            if (snap) {
              new_value = DEG2RADF((int(RAD2DEGF(new_value)) + 5) / 10 * 10);
            }
            break;
          default:
            new_value = dist; /* NOTE(@ideasman42): Dummy value, should this ever happen? */
            break;
        }

        /* Clamp and update. */
        CLAMP(new_value, rc->min_value, rc->max_value);
        radial_control_set_value(rc, new_value);
        rc->current_value = new_value;
        handled = true;
        break;
      }
      break;

    case EVT_LEFTSHIFTKEY:
    case EVT_RIGHTSHIFTKEY: {
      if (event->val == KM_PRESS) {
        rc->slow_mouse[0] = event->xy[0];
        rc->slow_mouse[1] = event->xy[1];
        rc->slow_mode = true;
        if (rc->subtype == PROP_ANGLE) {
          const float initial_position[2] = {float(rc->initial_radial_center[0]),
                                             float(rc->initial_radial_center[1])};
          const float current_position[2] = {float(rc->slow_mouse[0]), float(rc->slow_mouse[1])};
          rc->dial = BLI_dial_init(initial_position, 0.0f);
          /* Immediately set the position to get a an initial direction. */
          BLI_dial_angle(rc->dial, current_position);
        }
        handled = true;
      }
      if (event->val == KM_RELEASE) {
        rc->slow_mode = false;
        handled = true;
        if (rc->dial) {
          BLI_dial_free(rc->dial);
          rc->dial = nullptr;
        }
      }
      break;
    }
    default: {
      break;
    }
  }

  /* Modal numinput inactive, try to handle numeric inputs last... */
  if (!handled && event->val == KM_PRESS && handleNumInput(C, &rc->num_input, event)) {
    applyNumInput(&rc->num_input, &numValue);

    if (rc->subtype == PROP_ANGLE) {
      numValue = fmod(numValue, 2.0f * float(M_PI));
      if (numValue < 0.0f) {
        numValue += 2.0f * float(M_PI);
      }
    }

    CLAMP(numValue, rc->min_value, rc->max_value);
    new_value = numValue;

    radial_control_set_value(rc, new_value);

    rc->current_value = new_value;
    radial_control_update_header(op, C);
    return OPERATOR_RUNNING_MODAL;
  }

  if (!handled && (event->val == KM_RELEASE) && (rc->init_event == event->type) &&
      RNA_boolean_get(op->ptr, "release_confirm"))
  {
    /* Keep the RNA update separate from setting the value, for some properties this could lead to
     * a continues flickering due to invalidating the overlay texture. */
    RNA_property_update(C, &rc->ptr, rc->prop);
    ret = OPERATOR_FINISHED;
  }

  ED_region_tag_redraw(CTX_wm_region(C));
  radial_control_update_header(op, C);

  if (ret & OPERATOR_FINISHED) {
    wmWindowManager *wm = CTX_wm_manager(C);
    if (wm->op_undo_depth == 0) {
      ID *id = rc->ptr.owner_id;
      if (ED_undo_is_legacy_compatible_for_property(C, id, rc->ptr)) {
        ED_undo_push(C, op->type->name);
      }
    }
  }

  if (ret != OPERATOR_RUNNING_MODAL) {
    radial_control_cancel(C, op);
  }

  return ret;
}

static void WM_OT_radial_control(wmOperatorType *ot)
{
  ot->name = "Radial Control";
  ot->idname = "WM_OT_radial_control";
  ot->description = "Set some size property (e.g. brush size) with mouse wheel";

  ot->invoke = radial_control_invoke;
  ot->modal = radial_control_modal;
  ot->cancel = radial_control_cancel;

  ot->flag = OPTYPE_REGISTER | OPTYPE_BLOCKING;

  /* All paths relative to the context. */
  PropertyRNA *prop;
  prop = RNA_def_string(ot->srna,
                        "data_path_primary",
                        nullptr,
                        0,
                        "Primary Data Path",
                        "Primary path of property to be set by the radial control");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);

  prop = RNA_def_string(ot->srna,
                        "data_path_secondary",
                        nullptr,
                        0,
                        "Secondary Data Path",
                        "Secondary path of property to be set by the radial control");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);

  prop = RNA_def_string(ot->srna,
                        "use_secondary",
                        nullptr,
                        0,
                        "Use Secondary",
                        "Path of property to select between the primary and secondary data paths");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);

  prop = RNA_def_string(ot->srna,
                        "rotation_path",
                        nullptr,
                        0,
                        "Rotation Path",
                        "Path of property used to rotate the texture display");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);

  prop = RNA_def_string(ot->srna,
                        "color_path",
                        nullptr,
                        0,
                        "Color Path",
                        "Path of property used to set the color of the control");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);

  prop = RNA_def_string(ot->srna,
                        "fill_color_path",
                        nullptr,
                        0,
                        "Fill Color Path",
                        "Path of property used to set the fill color of the control");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);

  prop = RNA_def_string(
      ot->srna, "fill_color_override_path", nullptr, 0, "Fill Color Override Path", "");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
  prop = RNA_def_string(
      ot->srna, "fill_color_override_test_path", nullptr, 0, "Fill Color Override Test", "");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);

  prop = RNA_def_string(ot->srna,
                        "zoom_path",
                        nullptr,
                        0,
                        "Zoom Path",
                        "Path of property used to set the zoom level for the control");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);

  prop = RNA_def_string(ot->srna,
                        "image_id",
                        nullptr,
                        0,
                        "Image ID",
                        "Path of ID that is used to generate an image for the control");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);

  prop = RNA_def_boolean(
      ot->srna, "secondary_tex", false, "Secondary Texture", "Tweak brush secondary/mask texture");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);

  prop = RNA_def_boolean(
      ot->srna, "release_confirm", false, "Confirm On Release", "Finish operation on key release");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Redraw Timer Operator
 *
 * Use for simple benchmarks.
 * \{ */

/* Uses no type defines, fully local testing function anyway. */

static void redraw_timer_window_swap(bContext *C)
{
  wmWindow *win = CTX_wm_window(C);
  bScreen *screen = CTX_wm_screen(C);

  CTX_wm_region_popup_set(C, nullptr);

  LISTBASE_FOREACH (ScrArea *, area, &screen->areabase) {
    ED_area_tag_redraw(area);
  }
  wm_draw_update(C);

  CTX_wm_window_set(C, win); /* XXX context manipulation warning! */
}

enum {
  eRTDrawRegion = 0,
  eRTDrawRegionSwap = 1,
  eRTDrawWindow = 2,
  eRTDrawWindowSwap = 3,
  eRTAnimationStep = 4,
  eRTAnimationPlay = 5,
  eRTUndo = 6,
};

static const EnumPropertyItem redraw_timer_type_items[] = {
    {eRTDrawRegion, "DRAW", 0, "Draw Region", "Draw region"},
    {eRTDrawRegionSwap, "DRAW_SWAP", 0, "Draw Region & Swap", "Draw region and swap"},
    {eRTDrawWindow, "DRAW_WIN", 0, "Draw Window", "Draw window"},
    {eRTDrawWindowSwap, "DRAW_WIN_SWAP", 0, "Draw Window & Swap", "Draw window and swap"},
    {eRTAnimationStep, "ANIM_STEP", 0, "Animation Step", "Animation steps"},
    {eRTAnimationPlay, "ANIM_PLAY", 0, "Animation Play", "Animation playback"},
    {eRTUndo, "UNDO", 0, "Undo/Redo", "Undo and redo"},
    {0, nullptr, 0, nullptr, nullptr},
};

static void redraw_timer_step(bContext *C,
                              Scene *scene,
                              Depsgraph *depsgraph,
                              wmWindow *win,
                              ScrArea *area,
                              ARegion *region,
                              const int type,
                              const int cfra,
                              const int steps_done,
                              const int steps_total)
{
  if (type == eRTDrawRegion) {
    if (region) {
      wm_draw_region_test(C, area, region);
    }
  }
  else if (type == eRTDrawRegionSwap) {
    CTX_wm_region_popup_set(C, nullptr);

    ED_region_tag_redraw(region);
    wm_draw_update(C);

    CTX_wm_window_set(C, win); /* XXX context manipulation warning! */
  }
  else if (type == eRTDrawWindow) {
    bScreen *screen = WM_window_get_active_screen(win);

    CTX_wm_region_popup_set(C, nullptr);

    LISTBASE_FOREACH (ScrArea *, area_iter, &screen->areabase) {
      CTX_wm_area_set(C, area_iter);
      LISTBASE_FOREACH (ARegion *, region_iter, &area_iter->regionbase) {
        if (!region_iter->runtime->visible) {
          continue;
        }
        CTX_wm_region_set(C, region_iter);
        wm_draw_region_test(C, area_iter, region_iter);
      }
    }

    CTX_wm_window_set(C, win); /* XXX context manipulation warning! */

    CTX_wm_area_set(C, area);
    CTX_wm_region_set(C, region);
  }
  else if (type == eRTDrawWindowSwap) {
    redraw_timer_window_swap(C);
  }
  else if (type == eRTAnimationStep) {
    scene->r.cfra += (cfra == scene->r.cfra) ? 1 : -1;
    BKE_scene_graph_update_for_newframe(depsgraph);
  }
  else if (type == eRTAnimationPlay) {
    /* Play anim, return on same frame as started with. */
    int tot = (scene->r.efra - scene->r.sfra) + 1;
    const int frames_total = tot * steps_total;
    int frames_done = tot * steps_done;

    while (tot--) {
      WM_progress_set(win, float(frames_done) / float(frames_total));
      frames_done++;

      /* TODO: ability to escape! */
      scene->r.cfra++;
      if (scene->r.cfra > scene->r.efra) {
        scene->r.cfra = scene->r.sfra;
      }

      BKE_scene_graph_update_for_newframe(depsgraph);
      redraw_timer_window_swap(C);
    }
  }
  else { /* #eRTUndo. */
    /* Undo and redo, including depsgraph update since that can be a
     * significant part of the cost. */
    ED_undo_pop(C);
    wm_event_do_refresh_wm_and_depsgraph(C);
    ED_undo_redo(C);
    wm_event_do_refresh_wm_and_depsgraph(C);
  }
}

static bool redraw_timer_poll(bContext *C)
{
  /* Check background mode as many of these actions use redrawing.
   * NOTE(@ideasman42): if it's useful to support undo or animation step this could
   * be allowed at the moment this seems like a corner case that isn't needed. */
  return !G.background && WM_operator_winactive(C);
}

static wmOperatorStatus redraw_timer_exec(bContext *C, wmOperator *op)
{
  Scene *scene = CTX_data_scene(C);
  wmWindow *win = CTX_wm_window(C);
  ScrArea *area = CTX_wm_area(C);
  ARegion *region = CTX_wm_region(C);
  wmWindowManager *wm = CTX_wm_manager(C);
  const int type = RNA_enum_get(op->ptr, "type");
  const int iter = RNA_int_get(op->ptr, "iterations");
  const double time_limit = double(RNA_float_get(op->ptr, "time_limit"));
  const int cfra = scene->r.cfra;
  const char *infostr = "";

  /* NOTE: Depsgraph is used to update scene for a new state, so no need to ensure evaluation
   * here.
   */
  Depsgraph *depsgraph = CTX_data_depsgraph_pointer(C);

  RNA_enum_description(redraw_timer_type_items, type, &infostr);

  WM_cursor_wait(true);

  double time_start = BLI_time_now_seconds();

  wm_window_make_drawable(wm, win);

  int iter_steps = 0;
  for (int a = 0; a < iter; a++) {

    if (type == eRTAnimationPlay) {
      WorkspaceStatus status(C);
      status.item(fmt::format("{} / {} {}", a + 1, iter, infostr), ICON_INFO);
    }

    redraw_timer_step(C, scene, depsgraph, win, area, region, type, cfra, a, iter);
    iter_steps += 1;

    if (time_limit != 0.0) {
      if ((BLI_time_now_seconds() - time_start) > time_limit) {
        break;
      }
      a = 0;
    }
  }

  double time_delta = (BLI_time_now_seconds() - time_start) * 1000;

  if (type == eRTAnimationPlay) {
    ED_workspace_status_text(C, nullptr);
    WM_progress_clear(win);
  }

  WM_cursor_wait(false);

  BKE_reportf(op->reports,
              RPT_WARNING,
              "%d \u00D7 %s: %.4f ms, average: %.8f ms",
              iter_steps,
              infostr,
              time_delta,
              time_delta / iter_steps);

  return OPERATOR_FINISHED;
}

static void WM_OT_redraw_timer(wmOperatorType *ot)
{
  ot->name = "Redraw Timer";
  ot->idname = "WM_OT_redraw_timer";
  ot->description = "Simple redraw timer to test the speed of updating the interface";

  ot->invoke = WM_menu_invoke;
  ot->exec = redraw_timer_exec;
  ot->poll = redraw_timer_poll;

  ot->prop = RNA_def_enum(ot->srna, "type", redraw_timer_type_items, eRTDrawRegion, "Type", "");
  RNA_def_int(
      ot->srna, "iterations", 10, 1, INT_MAX, "Iterations", "Number of times to redraw", 1, 1000);
  RNA_def_float(ot->srna,
                "time_limit",
                0.0,
                0.0,
                FLT_MAX,
                "Time Limit",
                "Seconds to run the test for (override iterations)",
                0.0,
                60.0);
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Report Memory Statistics
 *
 * Use for testing/debugging.
 * \{ */

static wmOperatorStatus memory_statistics_exec(bContext * /*C*/, wmOperator * /*op*/)
{
  MEM_printmemlist_stats();
  return OPERATOR_FINISHED;
}

static void WM_OT_memory_statistics(wmOperatorType *ot)
{
  ot->name = "Memory Statistics";
  ot->idname = "WM_OT_memory_statistics";
  ot->description = "Print memory statistics to the console";

  ot->exec = memory_statistics_exec;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Data-Block Preview Generation Operator
 *
 * Use for material/texture/light ... etc.
 * \{ */

struct PreviewsIDEnsureData {
  bContext *C;
  Scene *scene;
};

static void previews_id_ensure(bContext *C, Scene *scene, ID *id)
{
  BLI_assert(ELEM(GS(id->name), ID_MA, ID_TE, ID_IM, ID_WO, ID_LA));

  /* Only preview non-library datablocks, lib ones do not pertain to this .blend file!
   * Same goes for ID with no user. */
  if (ID_IS_EDITABLE(id) && (id->us != 0)) {
    UI_icon_render_id(C, scene, id, ICON_SIZE_ICON, false);
    UI_icon_render_id(C, scene, id, ICON_SIZE_PREVIEW, false);
  }
}

static int previews_id_ensure_callback(LibraryIDLinkCallbackData *cb_data)
{
  const LibraryForeachIDCallbackFlag cb_flag = cb_data->cb_flag;

  if (cb_flag & (IDWALK_CB_EMBEDDED | IDWALK_CB_EMBEDDED_NOT_OWNING)) {
    return IDWALK_RET_NOP;
  }

  PreviewsIDEnsureData *data = static_cast<PreviewsIDEnsureData *>(cb_data->user_data);
  ID *id = *cb_data->id_pointer;

  if (id && (id->tag & ID_TAG_DOIT)) {
    BLI_assert(ELEM(GS(id->name), ID_MA, ID_TE, ID_IM, ID_WO, ID_LA));
    previews_id_ensure(data->C, data->scene, id);
    id->tag &= ~ID_TAG_DOIT;
  }

  return IDWALK_RET_NOP;
}

static wmOperatorStatus previews_ensure_exec(bContext *C, wmOperator * /*op*/)
{
  Main *bmain = CTX_data_main(C);
  ListBase *lb[] = {&bmain->materials,
                    &bmain->textures,
                    &bmain->images,
                    &bmain->worlds,
                    &bmain->lights,
                    nullptr};
  PreviewsIDEnsureData preview_id_data;

  /* We use ID_TAG_DOIT to check whether we have already handled a given ID or not. */
  BKE_main_id_tag_all(bmain, ID_TAG_DOIT, false);
  for (int i = 0; lb[i]; i++) {
    BKE_main_id_tag_listbase(lb[i], ID_TAG_DOIT, true);
  }

  preview_id_data.C = C;
  LISTBASE_FOREACH (Scene *, scene, &bmain->scenes) {
    preview_id_data.scene = scene;
    ID *id = (ID *)scene;

    BKE_library_foreach_ID_link(
        nullptr, id, previews_id_ensure_callback, &preview_id_data, IDWALK_RECURSE);
  }

  /* Check a last time for ID not used (fake users only, in theory), and
   * do our best for those, using current scene... */
  for (int i = 0; lb[i]; i++) {
    LISTBASE_FOREACH (ID *, id, lb[i]) {
      if (id->tag & ID_TAG_DOIT) {
        previews_id_ensure(C, nullptr, id);
        id->tag &= ~ID_TAG_DOIT;
      }
    }
  }

  return OPERATOR_FINISHED;
}

static void WM_OT_previews_ensure(wmOperatorType *ot)
{
  ot->name = "Refresh Data-Block Previews";
  ot->idname = "WM_OT_previews_ensure";
  ot->description =
      "Ensure data-block previews are available and up-to-date "
      "(to be saved in .blend file, only for some types like materials, textures, etc.)";

  ot->exec = previews_ensure_exec;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Data-Block Preview Clear Operator
 * \{ */

enum PreviewFilterID {
  PREVIEW_FILTER_ALL,
  PREVIEW_FILTER_GEOMETRY,
  PREVIEW_FILTER_SHADING,
  PREVIEW_FILTER_SCENE,
  PREVIEW_FILTER_COLLECTION,
  PREVIEW_FILTER_OBJECT,
  PREVIEW_FILTER_MATERIAL,
  PREVIEW_FILTER_LIGHT,
  PREVIEW_FILTER_WORLD,
  PREVIEW_FILTER_TEXTURE,
  PREVIEW_FILTER_IMAGE,
};

/* Only types supporting previews currently. */
static const EnumPropertyItem preview_id_type_items[] = {
    {PREVIEW_FILTER_ALL, "ALL", 0, "All Types", ""},
    {PREVIEW_FILTER_GEOMETRY,
     "GEOMETRY",
     0,
     "All Geometry Types",
     "Clear previews for scenes, collections and objects"},
    {PREVIEW_FILTER_SHADING,
     "SHADING",
     0,
     "All Shading Types",
     "Clear previews for materials, lights, worlds, textures and images"},
    {PREVIEW_FILTER_SCENE, "SCENE", 0, "Scenes", ""},
    {PREVIEW_FILTER_COLLECTION, "COLLECTION", 0, "Collections", ""},
    {PREVIEW_FILTER_OBJECT, "OBJECT", 0, "Objects", ""},
    {PREVIEW_FILTER_MATERIAL, "MATERIAL", 0, "Materials", ""},
    {PREVIEW_FILTER_LIGHT, "LIGHT", 0, "Lights", ""},
    {PREVIEW_FILTER_WORLD, "WORLD", 0, "Worlds", ""},
    {PREVIEW_FILTER_TEXTURE, "TEXTURE", 0, "Textures", ""},
    {PREVIEW_FILTER_IMAGE, "IMAGE", 0, "Images", ""},
#if 0 /* XXX: TODO. */
    {PREVIEW_FILTER_BRUSH, "BRUSH", 0, "Brushes", ""},
#endif
    {0, nullptr, 0, nullptr, nullptr},
};

static uint preview_filter_to_idfilter(enum PreviewFilterID filter)
{
  switch (filter) {
    case PREVIEW_FILTER_ALL:
      return FILTER_ID_SCE | FILTER_ID_GR | FILTER_ID_OB | FILTER_ID_MA | FILTER_ID_LA |
             FILTER_ID_WO | FILTER_ID_TE | FILTER_ID_IM;
    case PREVIEW_FILTER_GEOMETRY:
      return FILTER_ID_SCE | FILTER_ID_GR | FILTER_ID_OB;
    case PREVIEW_FILTER_SHADING:
      return FILTER_ID_MA | FILTER_ID_LA | FILTER_ID_WO | FILTER_ID_TE | FILTER_ID_IM;
    case PREVIEW_FILTER_SCENE:
      return FILTER_ID_SCE;
    case PREVIEW_FILTER_COLLECTION:
      return FILTER_ID_GR;
    case PREVIEW_FILTER_OBJECT:
      return FILTER_ID_OB;
    case PREVIEW_FILTER_MATERIAL:
      return FILTER_ID_MA;
    case PREVIEW_FILTER_LIGHT:
      return FILTER_ID_LA;
    case PREVIEW_FILTER_WORLD:
      return FILTER_ID_WO;
    case PREVIEW_FILTER_TEXTURE:
      return FILTER_ID_TE;
    case PREVIEW_FILTER_IMAGE:
      return FILTER_ID_IM;
  }

  return 0;
}

static wmOperatorStatus previews_clear_exec(bContext *C, wmOperator *op)
{
  Main *bmain = CTX_data_main(C);
  ListBase *lb[] = {
      &bmain->objects,
      &bmain->collections,
      &bmain->materials,
      &bmain->worlds,
      &bmain->lights,
      &bmain->textures,
      &bmain->images,
      nullptr,
  };

  const int id_filters = preview_filter_to_idfilter(
      PreviewFilterID(RNA_enum_get(op->ptr, "id_type")));

  for (int i = 0; lb[i]; i++) {
    ID *id = static_cast<ID *>(lb[i]->first);
    if (!id) {
      continue;
    }

#if 0
    printf("%s: %d, %d, %d -> %d\n",
           id->name,
           GS(id->name),
           BKE_idtype_idcode_to_idfilter(GS(id->name)),
           id_filters,
           BKE_idtype_idcode_to_idfilter(GS(id->name)) & id_filters);
#endif

    if (!(BKE_idtype_idcode_to_idfilter(GS(id->name)) & id_filters)) {
      continue;
    }

    for (; id; id = static_cast<ID *>(id->next)) {
      PreviewImage *prv_img = BKE_previewimg_id_ensure(id);

      BKE_previewimg_clear(prv_img);
    }
  }

  return OPERATOR_FINISHED;
}

static void WM_OT_previews_clear(wmOperatorType *ot)
{
  ot->name = "Clear Data-Block Previews";
  ot->idname = "WM_OT_previews_clear";
  ot->description =
      "Clear data-block previews (only for some types like objects, materials, textures, etc.)";

  ot->exec = previews_clear_exec;
  ot->invoke = WM_menu_invoke;

  ot->prop = RNA_def_enum_flag(ot->srna,
                               "id_type",
                               preview_id_type_items,
                               PREVIEW_FILTER_ALL,
                               "Data-Block Type",
                               "Which data-block previews to clear");
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Doc from UI Operator
 * \{ */

static wmOperatorStatus doc_view_manual_ui_context_exec(bContext *C, wmOperator * /*op*/)
{
  PointerRNA ptr_props;
  wmOperatorStatus retval = OPERATOR_CANCELLED;

  if (std::optional<std::string> manual_id = UI_but_online_manual_id_from_active(C)) {
    WM_operator_properties_create(&ptr_props, "WM_OT_doc_view_manual");
    RNA_string_set(&ptr_props, "doc_id", manual_id.value().c_str());

    retval = WM_operator_name_call_ptr(C,
                                       WM_operatortype_find("WM_OT_doc_view_manual", false),
                                       blender::wm::OpCallContext::ExecDefault,
                                       &ptr_props,
                                       nullptr);

    WM_operator_properties_free(&ptr_props);
  }

  return retval;
}

static void WM_OT_doc_view_manual_ui_context(wmOperatorType *ot)
{
  /* Identifiers. */
  ot->name = "View Online Manual";
  ot->idname = "WM_OT_doc_view_manual_ui_context";
  ot->description = "View a context based online manual in a web browser";

  /* Callbacks. */
  ot->poll = ED_operator_regionactive;
  ot->exec = doc_view_manual_ui_context_exec;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Toggle Stereo 3D Operator
 *
 * Turning it full-screen if needed.
 * \{ */

static void WM_OT_stereo3d_set(wmOperatorType *ot)
{
  PropertyRNA *prop;

  ot->name = "Set Stereo 3D";
  ot->idname = "WM_OT_set_stereo_3d";
  ot->description = "Toggle 3D stereo support for current window (or change the display mode)";

  ot->exec = wm_stereo3d_set_exec;
  ot->invoke = wm_stereo3d_set_invoke;
  ot->poll = WM_operator_winactive;
  ot->ui = wm_stereo3d_set_draw;
  ot->check = wm_stereo3d_set_check;
  ot->cancel = wm_stereo3d_set_cancel;

  prop = RNA_def_enum(ot->srna,
                      "display_mode",
                      rna_enum_stereo3d_display_items,
                      S3D_DISPLAY_ANAGLYPH,
                      "Display Mode",
                      "");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
  prop = RNA_def_enum(ot->srna,
                      "anaglyph_type",
                      rna_enum_stereo3d_anaglyph_type_items,
                      S3D_ANAGLYPH_REDCYAN,
                      "Anaglyph Type",
                      "");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
  prop = RNA_def_enum(ot->srna,
                      "interlace_type",
                      rna_enum_stereo3d_interlace_type_items,
                      S3D_INTERLACE_ROW,
                      "Interlace Type",
                      "");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
  prop = RNA_def_boolean(ot->srna,
                         "use_interlace_swap",
                         false,
                         "Swap Left/Right",
                         "Swap left and right stereo channels");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
  prop = RNA_def_boolean(ot->srna,
                         "use_sidebyside_crosseyed",
                         false,
                         "Cross-Eyed",
                         "Right eye should see left image and vice versa");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name iOS Immersive Toggle Operator (RealityKit)
 * \{ */

#if defined(WITH_APPLE_CROSSPLATFORM)
struct WMIOSImmersivePendingMove {
  std::mutex mutex;
  std::string object_name;
  float z = 0.0f;
  bool pending = false;
};

static WMIOSImmersivePendingMove g_wm_ios_immersive_pending_move;

struct WMIOSImmersiveMuseSample {
  std::mutex mutex;
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
  float pressure = 0.0f;
  int tip_pressed = 0;
  bool pending = false;
};

static WMIOSImmersiveMuseSample g_wm_ios_immersive_muse_sample;
static bool g_wm_ios_muse_stroke_active = false;
static bool g_wm_ios_muse_tip_down = false;
static bool g_wm_ios_muse_tip_just_released = false;
/** Set when Muse actually changed mesh geometry — drives Immersive USD refresh. */
static bool g_wm_ios_muse_geometry_dirty = false;
/**
 * Immersive USDZ re-export pacing (seconds). Tunable from Immersive sidebar.
 * Shorter = snappier spatial scene, heavier; longer = lighter on CPU/GPU.
 */
static float g_wm_ios_usd_refresh_interval = 0.35f;
/**
 * When true, Object Mode location/rotation/scale changes also dirty the USD
 * path so non-active meshes (games demos, etc.) appear in Immersive Space.
 * Off by default — avoids fighting live active-object transform sync.
 */
static bool g_wm_ios_sync_transforms_to_space = false;

/**
 * Called by BlenderImmersiveSpaceView.swift while dragging an entity. Queue the
 * change instead of touching Blender DNA from SwiftUI/RealityKit callbacks.
 * `z` is Blender *world* height (gravity-up), not parent-local loc[2].
 */
extern "C" void WM_IOS_immersive_set_object_z(const char *object_name, const float z)
{
  if (object_name == nullptr || object_name[0] == '\0') {
    return;
  }
  std::lock_guard lock(g_wm_ios_immersive_pending_move.mutex);
  g_wm_ios_immersive_pending_move.object_name = object_name;
  g_wm_ios_immersive_pending_move.z = z;
  g_wm_ios_immersive_pending_move.pending = true;
}

/**
 * Called by BlenderImmersiveMusePen.swift (~60 Hz). Queue the latest Muse tip
 * sample for consumption on the Blender main/draw loop.
 */
extern "C" void WM_IOS_immersive_muse_sample(const float x,
                                             const float y,
                                             const float z,
                                             const float pressure,
                                             const int tip_pressed)
{
  std::lock_guard lock(g_wm_ios_immersive_muse_sample.mutex);
  g_wm_ios_immersive_muse_sample.x = x;
  g_wm_ios_immersive_muse_sample.y = y;
  g_wm_ios_immersive_muse_sample.z = z;
  g_wm_ios_immersive_muse_sample.pressure = pressure;
  g_wm_ios_immersive_muse_sample.tip_pressed = tip_pressed;
  g_wm_ios_immersive_muse_sample.pending = true;
}

/** Muse / hand-menu brush style used by Immersive 3D deform. */
enum {
  WMIOS_MUSE_BRUSH_DRAW = 0,
  WMIOS_MUSE_BRUSH_CLAY = 1,
  WMIOS_MUSE_BRUSH_GRAB = 2,
  WMIOS_MUSE_BRUSH_SMOOTH = 3,
  WMIOS_MUSE_BRUSH_INFLATE_ADD = 4,
  WMIOS_MUSE_BRUSH_INFLATE_SUB = 5,
};

struct WMIOSImmersiveHandMenuPending {
  std::mutex mutex;
  bool pending_mode = false;
  int mode = 0; /* 0 object, 1 edit, 2 sculpt, 3 vpaint, 4 anim/pose */
  bool pending_brush = false;
  int brush_kind = WMIOS_MUSE_BRUSH_INFLATE_ADD;
  char brush_tool_id[64] = "builtin.brush";
  bool pending_strength = false;
  float strength = 0.5f;
  bool pending_radius = false;
  float radius = 0.25f;
  bool pending_dismiss = false;
  bool pending_remesh = false;
  bool pending_dyntopo = false;
  int dyntopo = 1;
  bool pending_anim_key = false;
  bool pending_anim_key_delete = false;
  bool pending_anim_play = false;
  bool pending_anim_stop = false;
  bool pending_anim_frame = false;
  int anim_frame_delta = 0;
  bool pending_anim_set_frame = false;
  int anim_set_frame = 1;
  bool pending_pose_xform = false;
  int pose_xform_mode = 0; /* 0 rotate, 1 move, 2 scale */
  bool pending_anim_target = false;
  int anim_target = 0; /* 0 bone, 1 object */
  bool pending_camera_key = false;
};

static WMIOSImmersiveHandMenuPending g_wm_ios_hand_menu_cmd;
/** Last mode requested from Immersive hand menu / N-panel (0–4).
 * Published back to Swift so Anim stays selected even if Pose entry is delayed
 * (no armature yet / mode_set toggle failed). */
static int g_wm_ios_immersive_ui_mode = 0;
static int g_wm_ios_muse_brush_kind = WMIOS_MUSE_BRUSH_INFLATE_ADD;
static bool g_wm_ios_muse_vpaint_erase = false;
/** Hand-menu radius/strength — prefer these over brush asset values for Muse. */
static float g_wm_ios_muse_radius_m = 0.25f;
static float g_wm_ios_muse_strength = 0.5f;
/** Immersive default: DynTopo (desktop Dynamic Topology) on. */
static bool g_wm_ios_muse_dyntopo_wanted = true;
/** Immersive: use right-hand pinch instead of Muse stylus. */
static bool g_wm_ios_use_hand_as_pen = false;
/** Immersive: when hand input is active, sculpt by proximity without pinch. */
static bool g_wm_ios_hand_proximity_sculpt = false;
/** Immersive: spatial material node editor (Shading equivalent). */
static bool g_wm_ios_shader_space = false;
/** Selected shader node name for Immersive Mat editing. */
static char g_wm_ios_shader_selected[64] = "";

struct WMIOSImmersiveShaderPending {
  std::mutex mutex;
  bool pending_move = false;
  char move_name[64] = "";
  float move_x = 0.0f;
  float move_y = 0.0f;
  bool pending_select = false;
  char select_name[64] = "";
  bool pending_add = false;
  char add_idname[64] = "";
  float add_x = 0.0f;
  float add_y = 0.0f;
  bool pending_delete = false;
  char delete_name[64] = "";
  bool pending_connect = false;
  char conn_from_node[64] = "";
  char conn_from_sock[64] = "";
  char conn_to_node[64] = "";
  char conn_to_sock[64] = "";
  bool pending_disconnect = false;
  char disc_to_node[64] = "";
  char disc_to_sock[64] = "";
  bool pending_sock_float = false;
  char sockf_node[64] = "";
  char sockf_id[64] = "";
  float sockf_value = 0.0f;
  bool pending_sock_rgba = false;
  char sockc_node[64] = "";
  char sockc_id[64] = "";
  float sockc_rgba[4] = {0.8f, 0.8f, 0.8f, 1.0f};
  bool pending_repair = false;
  bool repair_force = false;
};
static WMIOSImmersiveShaderPending g_wm_ios_shader_cmd;

struct WMIOSMuseSculptVert {
  int index;
  float weight;
};
static std::vector<WMIOSMuseSculptVert> g_wm_ios_muse_sculpt_verts;
struct WMIOSMuseSculptBMVert {
  BMVert *v;
  float weight;
};
static std::vector<WMIOSMuseSculptBMVert> g_wm_ios_muse_sculpt_bm_verts;

static const char *wm_ios_muse_tool_id_for_kind(const int /*kind*/)
{
  /* Blender 5.0+: sculpt tools collapsed to a single USE_BRUSHES tool.
   * Old ids like builtin_brush.Inflate are gone (Info: "Tool not found"). */
  return "builtin.brush";
}

static const char *wm_ios_muse_essentials_brush_name(const int kind)
{
  switch (kind) {
    case WMIOS_MUSE_BRUSH_CLAY:
      return "Clay";
    case WMIOS_MUSE_BRUSH_GRAB:
      return "Grab";
    case WMIOS_MUSE_BRUSH_SMOOTH:
      return "Smooth";
    case WMIOS_MUSE_BRUSH_INFLATE_ADD:
    case WMIOS_MUSE_BRUSH_INFLATE_SUB:
      /* Essentials asset id in 5.0. */
      return "Inflate/Deflate";
    case WMIOS_MUSE_BRUSH_DRAW:
    default:
      return "Draw";
  }
}

static char wm_ios_muse_sculpt_brush_type(const int kind)
{
  switch (kind) {
    case WMIOS_MUSE_BRUSH_CLAY:
      return SCULPT_BRUSH_TYPE_CLAY;
    case WMIOS_MUSE_BRUSH_GRAB:
      return SCULPT_BRUSH_TYPE_GRAB;
    case WMIOS_MUSE_BRUSH_SMOOTH:
      return SCULPT_BRUSH_TYPE_SMOOTH;
    case WMIOS_MUSE_BRUSH_INFLATE_ADD:
    case WMIOS_MUSE_BRUSH_INFLATE_SUB:
      return SCULPT_BRUSH_TYPE_INFLATE;
    case WMIOS_MUSE_BRUSH_DRAW:
    default:
      return SCULPT_BRUSH_TYPE_DRAW;
  }
}

/** True when Paint.brush is bound (essentials or local Muse fallback). */
static bool g_wm_ios_paint_brush_ok = false;

/**
 * Ensure Sculpt / Vertex Paint has an active Brush*.
 * Muse 3D deform does not require assets, but mode tooling and UI do — if
 * essentials fail to resolve, create a local fallback so Paint is never null.
 *
 * \param prefer_kind: when true, try to switch to the essentials brush matching
 *                     muse_kind even if Paint already has some brush.
 */
static Brush *wm_ios_ensure_paint_brush(bContext *C,
                                        const PaintMode paint_mode,
                                        const int muse_kind,
                                        const bool prefer_kind = false)
{
  Main *bmain = CTX_data_main(C);
  Scene *scene = CTX_data_scene(C);
  if (bmain == nullptr || scene == nullptr) {
    g_wm_ios_paint_brush_ok = false;
    return nullptr;
  }

  BKE_paint_init(bmain, scene, paint_mode, true);
  Paint *paint = BKE_paint_get_active_from_paintmode(scene, paint_mode);
  if (paint == nullptr) {
    g_wm_ios_paint_brush_ok = false;
    return nullptr;
  }

  Brush *brush = BKE_paint_brush(paint);
  if (brush != nullptr && !prefer_kind) {
    g_wm_ios_paint_brush_ok = true;
    return brush;
  }

  const char *try_names[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
  if (paint_mode == PaintMode::Sculpt) {
    try_names[0] = wm_ios_muse_essentials_brush_name(muse_kind);
    try_names[1] = (muse_kind == WMIOS_MUSE_BRUSH_INFLATE_ADD ||
                    muse_kind == WMIOS_MUSE_BRUSH_INFLATE_SUB) ?
                       "Inflate" :
                       nullptr;
    try_names[2] = "Draw";
    try_names[3] = "Smooth";
    try_names[4] = "Grab";
  }
  else {
    try_names[0] = "Paint Hard";
    try_names[1] = "Paint Soft";
  }

  for (int i = 0; i < 5; i++) {
    if (try_names[i] == nullptr) {
      continue;
    }
    Brush *loaded = BKE_paint_brush_from_essentials(bmain, paint_mode, try_names[i]);
    if (loaded != nullptr && BKE_paint_can_use_brush(paint, loaded)) {
      BKE_paint_brush_set(paint, loaded);
      g_wm_ios_paint_brush_ok = true;
      fprintf(stderr, "[immersive] brush ensure essentials='%s'\n", try_names[i]);
      fflush(stderr);
      GHOST_IOS_diag_log("brush: essentials OK");
      return loaded;
    }
  }

  if (brush != nullptr) {
    /* Keep existing brush if essentials names failed but something is bound. */
    g_wm_ios_paint_brush_ok = true;
    return brush;
  }

  const eObjectMode ob_mode = (paint_mode == PaintMode::Vertex) ? OB_MODE_VERTEX_PAINT :
                                                                 OB_MODE_SCULPT;
  brush = BKE_brush_add(bmain, "MuseFallback", ob_mode);
  if (brush == nullptr) {
    g_wm_ios_paint_brush_ok = false;
    GHOST_IOS_diag_log("brush: MISSING");
    return nullptr;
  }
  if (paint_mode == PaintMode::Sculpt) {
    brush->sculpt_brush_type = wm_ios_muse_sculpt_brush_type(muse_kind);
    if (muse_kind == WMIOS_MUSE_BRUSH_INFLATE_SUB) {
      brush->flag |= BRUSH_DIR_IN;
    }
    else {
      brush->flag &= ~BRUSH_DIR_IN;
    }
  }
  BKE_paint_brush_set(paint, brush);
  BKE_brush_alpha_set(paint, brush, g_wm_ios_muse_strength);
  BKE_brush_unprojected_size_set(paint, brush, g_wm_ios_muse_radius_m * 2.0f);
  g_wm_ios_paint_brush_ok = true;
  fprintf(stderr, "[immersive] brush ensure LOCAL fallback kind=%d\n", muse_kind);
  fflush(stderr);
  GHOST_IOS_diag_log("brush: local fallback OK");
  return brush;
}

static void wm_ios_muse_queue_brush_kind(const int kind)
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  STRNCPY(g_wm_ios_hand_menu_cmd.brush_tool_id, wm_ios_muse_tool_id_for_kind(kind));
  g_wm_ios_hand_menu_cmd.brush_kind = kind;
  g_wm_ios_hand_menu_cmd.pending_brush = true;
}

extern "C" void WM_IOS_immersive_hand_menu_set_mode(const int mode)
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.mode = mode;
  g_wm_ios_hand_menu_cmd.pending_mode = true;
  /* Sticky immediately so the next publish cannot snap the UI back to Obj. */
  g_wm_ios_immersive_ui_mode = mode;
}

extern "C" void WM_IOS_immersive_hand_menu_set_brush(const char *tool_id, const int kind)
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  if (tool_id != nullptr && tool_id[0] != '\0') {
    STRNCPY(g_wm_ios_hand_menu_cmd.brush_tool_id, tool_id);
  }
  else {
    STRNCPY(g_wm_ios_hand_menu_cmd.brush_tool_id, wm_ios_muse_tool_id_for_kind(kind));
  }
  g_wm_ios_hand_menu_cmd.brush_kind = kind;
  g_wm_ios_hand_menu_cmd.pending_brush = true;
}

/** Pen front button: cycle Inflate+ → Inflate− → Smooth. */
extern "C" void WM_IOS_immersive_muse_cycle_brush()
{
  int next = WMIOS_MUSE_BRUSH_INFLATE_ADD;
  switch (g_wm_ios_muse_brush_kind) {
    case WMIOS_MUSE_BRUSH_INFLATE_ADD:
      next = WMIOS_MUSE_BRUSH_INFLATE_SUB;
      break;
    case WMIOS_MUSE_BRUSH_INFLATE_SUB:
      next = WMIOS_MUSE_BRUSH_SMOOTH;
      break;
    case WMIOS_MUSE_BRUSH_SMOOTH:
    default:
      next = WMIOS_MUSE_BRUSH_INFLATE_ADD;
      break;
  }
  wm_ios_muse_queue_brush_kind(next);
}

/** Pen middle button: toggle Inflate add ↔ subtract (or jump to Inflate+). */
extern "C" void WM_IOS_immersive_muse_toggle_inflate_direction()
{
  int next = WMIOS_MUSE_BRUSH_INFLATE_ADD;
  if (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_INFLATE_ADD) {
    next = WMIOS_MUSE_BRUSH_INFLATE_SUB;
  }
  else if (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_INFLATE_SUB) {
    next = WMIOS_MUSE_BRUSH_INFLATE_ADD;
  }
  wm_ios_muse_queue_brush_kind(next);
}

/** Pen middle button while Vertex Paint: toggle paint ↔ erase. */
extern "C" void WM_IOS_immersive_muse_toggle_vpaint_erase()
{
  g_wm_ios_muse_vpaint_erase = !g_wm_ios_muse_vpaint_erase;
}

extern "C" void WM_IOS_immersive_hand_menu_set_strength(const float strength)
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.strength = std::clamp(strength, 0.01f, 1.0f);
  g_wm_ios_muse_strength = g_wm_ios_hand_menu_cmd.strength;
  g_wm_ios_hand_menu_cmd.pending_strength = true;
}

extern "C" void WM_IOS_immersive_hand_menu_set_radius(const float radius_m)
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.radius = std::clamp(radius_m, 0.01f, 2.0f);
  g_wm_ios_muse_radius_m = g_wm_ios_hand_menu_cmd.radius;
  g_wm_ios_hand_menu_cmd.pending_radius = true;
}

extern "C" void WM_IOS_immersive_hand_menu_dismiss()
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.pending_dismiss = true;
}

extern "C" void WM_IOS_immersive_hand_menu_remesh()
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.pending_remesh = true;
}

extern "C" void WM_IOS_immersive_hand_menu_set_dyntopo(const int enabled)
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.dyntopo = enabled ? 1 : 0;
  g_wm_ios_muse_dyntopo_wanted = enabled != 0;
  g_wm_ios_hand_menu_cmd.pending_dyntopo = true;
}

extern "C" void WM_IOS_immersive_set_hand_as_pen(const int enabled)
{
  g_wm_ios_use_hand_as_pen = enabled != 0;
  GHOST_IOS_immersive_set_use_hand_as_pen(g_wm_ios_use_hand_as_pen);
}

extern "C" void WM_IOS_immersive_set_hand_proximity_sculpt(const int enabled)
{
  g_wm_ios_hand_proximity_sculpt = enabled != 0;
}

extern "C" void WM_IOS_immersive_set_usd_refresh_interval(const float seconds)
{
  g_wm_ios_usd_refresh_interval = std::clamp(seconds, 0.08f, 2.0f);
}

extern "C" void WM_IOS_immersive_set_sync_transforms_to_space(const int enabled)
{
  g_wm_ios_sync_transforms_to_space = enabled != 0;
}

extern "C" void WM_IOS_immersive_set_shader_space(const int enabled)
{
  g_wm_ios_shader_space = enabled != 0;
  GHOST_IOS_immersive_set_shader_space_enabled(g_wm_ios_shader_space);
  /* Always clear selection on toggle — avoids Hand Menu prop Sliders with
   * stale/corrupt ranges crashing on Mat entry. */
  g_wm_ios_shader_selected[0] = '\0';
  if (!g_wm_ios_shader_space) {
    GHOST_IOS_immersive_update_shader_graph(
        "", 0, nullptr, "", "", 0, nullptr, 0, nullptr, "");
    GHOST_IOS_immersive_update_shader_props("", "", 0, nullptr, "");
  }
  else {
    GHOST_IOS_immersive_update_shader_props("", "", 0, nullptr, "");
  }
}

extern "C" void WM_IOS_immersive_shader_move_node(const char *node_name,
                                                    const float locx,
                                                    const float locy)
{
  if (node_name == nullptr || node_name[0] == '\0') {
    return;
  }
  std::lock_guard lock(g_wm_ios_shader_cmd.mutex);
  STRNCPY(g_wm_ios_shader_cmd.move_name, node_name);
  g_wm_ios_shader_cmd.move_x = locx;
  g_wm_ios_shader_cmd.move_y = locy;
  g_wm_ios_shader_cmd.pending_move = true;
}

extern "C" void WM_IOS_immersive_shader_select_node(const char *node_name)
{
  std::lock_guard lock(g_wm_ios_shader_cmd.mutex);
  if (node_name != nullptr) {
    STRNCPY(g_wm_ios_shader_cmd.select_name, node_name);
  }
  else {
    g_wm_ios_shader_cmd.select_name[0] = '\0';
  }
  g_wm_ios_shader_cmd.pending_select = true;
}

extern "C" void WM_IOS_immersive_shader_add_node(const char *idname,
                                                   const float locx,
                                                   const float locy)
{
  if (idname == nullptr || idname[0] == '\0') {
    return;
  }
  std::lock_guard lock(g_wm_ios_shader_cmd.mutex);
  STRNCPY(g_wm_ios_shader_cmd.add_idname, idname);
  g_wm_ios_shader_cmd.add_x = locx;
  g_wm_ios_shader_cmd.add_y = locy;
  g_wm_ios_shader_cmd.pending_add = true;
}

extern "C" void WM_IOS_immersive_shader_delete_node(const char *node_name)
{
  if (node_name == nullptr || node_name[0] == '\0') {
    return;
  }
  std::lock_guard lock(g_wm_ios_shader_cmd.mutex);
  STRNCPY(g_wm_ios_shader_cmd.delete_name, node_name);
  g_wm_ios_shader_cmd.pending_delete = true;
}

extern "C" void WM_IOS_immersive_shader_connect(const char *from_node,
                                                  const char *from_sock,
                                                  const char *to_node,
                                                  const char *to_sock)
{
  if (from_node == nullptr || from_sock == nullptr || to_node == nullptr || to_sock == nullptr) {
    return;
  }
  if (from_node[0] == '\0' || from_sock[0] == '\0' || to_node[0] == '\0' || to_sock[0] == '\0') {
    return;
  }
  std::lock_guard lock(g_wm_ios_shader_cmd.mutex);
  STRNCPY(g_wm_ios_shader_cmd.conn_from_node, from_node);
  STRNCPY(g_wm_ios_shader_cmd.conn_from_sock, from_sock);
  STRNCPY(g_wm_ios_shader_cmd.conn_to_node, to_node);
  STRNCPY(g_wm_ios_shader_cmd.conn_to_sock, to_sock);
  g_wm_ios_shader_cmd.pending_connect = true;
}

/**
 * Connect the first compatible output→input sockets between two nodes.
 * Used by spatial board drop-connect (no socket entities).
 */
extern "C" void WM_IOS_immersive_shader_auto_connect(const char *from_node, const char *to_node)
{
  if (from_node == nullptr || to_node == nullptr || from_node[0] == '\0' || to_node[0] == '\0') {
    return;
  }
  if (STREQ(from_node, to_node)) {
    return;
  }
  /* Prefer common shader/color pairs; fill pending_connect with resolved ids. */
  std::lock_guard lock(g_wm_ios_shader_cmd.mutex);
  STRNCPY(g_wm_ios_shader_cmd.conn_from_node, from_node);
  STRNCPY(g_wm_ios_shader_cmd.conn_to_node, to_node);
  /* Empty sockets → resolve in apply with auto-pick. */
  g_wm_ios_shader_cmd.conn_from_sock[0] = '\0';
  g_wm_ios_shader_cmd.conn_to_sock[0] = '\0';
  g_wm_ios_shader_cmd.pending_connect = true;
}

extern "C" void WM_IOS_immersive_shader_disconnect(const char *to_node, const char *to_sock)
{
  if (to_node == nullptr || to_sock == nullptr || to_node[0] == '\0' || to_sock[0] == '\0') {
    return;
  }
  std::lock_guard lock(g_wm_ios_shader_cmd.mutex);
  STRNCPY(g_wm_ios_shader_cmd.disc_to_node, to_node);
  STRNCPY(g_wm_ios_shader_cmd.disc_to_sock, to_sock);
  g_wm_ios_shader_cmd.pending_disconnect = true;
}

extern "C" void WM_IOS_immersive_shader_set_socket_float(const char *node_name,
                                                          const char *sock_id,
                                                          const float value)
{
  if (node_name == nullptr || sock_id == nullptr || node_name[0] == '\0' || sock_id[0] == '\0') {
    return;
  }
  std::lock_guard lock(g_wm_ios_shader_cmd.mutex);
  STRNCPY(g_wm_ios_shader_cmd.sockf_node, node_name);
  STRNCPY(g_wm_ios_shader_cmd.sockf_id, sock_id);
  g_wm_ios_shader_cmd.sockf_value = value;
  g_wm_ios_shader_cmd.pending_sock_float = true;
}

extern "C" void WM_IOS_immersive_shader_set_socket_rgba(const char *node_name,
                                                         const char *sock_id,
                                                         const float r,
                                                         const float g,
                                                         const float b,
                                                         const float a)
{
  if (node_name == nullptr || sock_id == nullptr || node_name[0] == '\0' || sock_id[0] == '\0') {
    return;
  }
  std::lock_guard lock(g_wm_ios_shader_cmd.mutex);
  STRNCPY(g_wm_ios_shader_cmd.sockc_node, node_name);
  STRNCPY(g_wm_ios_shader_cmd.sockc_id, sock_id);
  g_wm_ios_shader_cmd.sockc_rgba[0] = r;
  g_wm_ios_shader_cmd.sockc_rgba[1] = g;
  g_wm_ios_shader_cmd.sockc_rgba[2] = b;
  g_wm_ios_shader_cmd.sockc_rgba[3] = a;
  g_wm_ios_shader_cmd.pending_sock_rgba = true;
}

extern "C" void WM_IOS_immersive_shader_repair_materials(const int force_all)
{
  std::lock_guard lock(g_wm_ios_shader_cmd.mutex);
  g_wm_ios_shader_cmd.pending_repair = true;
  g_wm_ios_shader_cmd.repair_force = force_all != 0;
}

extern "C" void WM_IOS_immersive_anim_insert_key()
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.pending_anim_key = true;
}

extern "C" void WM_IOS_immersive_anim_delete_key()
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.pending_anim_key_delete = true;
}

extern "C" void WM_IOS_immersive_anim_play()
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.pending_anim_play = true;
}

extern "C" void WM_IOS_immersive_anim_stop()
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.pending_anim_stop = true;
}

extern "C" void WM_IOS_immersive_anim_frame_delta(const int delta)
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.anim_frame_delta = delta;
  g_wm_ios_hand_menu_cmd.pending_anim_frame = true;
}

extern "C" void WM_IOS_immersive_anim_set_frame(const int frame)
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.anim_set_frame = frame;
  g_wm_ios_hand_menu_cmd.pending_anim_set_frame = true;
}

extern "C" void WM_IOS_immersive_anim_set_pose_xform(const int mode)
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.pose_xform_mode = std::clamp(mode, 0, 2);
  g_wm_ios_hand_menu_cmd.pending_pose_xform = true;
}

extern "C" void WM_IOS_immersive_anim_set_target(const int target)
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.anim_target = std::clamp(target, 0, 1);
  g_wm_ios_hand_menu_cmd.pending_anim_target = true;
}

struct WMIOSImmersiveViewerPose {
  std::mutex mutex;
  float mat[4][4] = {
      {1, 0, 0, 0},
      {0, 1, 0, 0},
      {0, 0, 1, 0},
      {0, 0, 0, 1},
  };
  bool valid = false;
};

static WMIOSImmersiveViewerPose g_wm_ios_viewer_pose;

/**
 * Latest Immersive viewer (head) pose as a Blender-space 4x4 world matrix
 * (column-major, matching Blender float[4][4]).
 */
extern "C" void WM_IOS_immersive_viewer_pose_sample(const float *mat16)
{
  if (mat16 == nullptr) {
    return;
  }
  std::lock_guard lock(g_wm_ios_viewer_pose.mutex);
  for (int c = 0; c < 4; c++) {
    for (int r = 0; r < 4; r++) {
      g_wm_ios_viewer_pose.mat[c][r] = mat16[c * 4 + r];
    }
  }
  g_wm_ios_viewer_pose.valid = true;
}

extern "C" void WM_IOS_immersive_camera_key_from_viewer()
{
  std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
  g_wm_ios_hand_menu_cmd.pending_camera_key = true;
}

static void wm_ios_immersive_muse_apply_dyntopo(bContext *C, Object *ob, const bool wanted)
{
  if (ob == nullptr || ob->type != OB_MESH || (ob->mode & OB_MODE_SCULPT) == 0) {
    if (ob != nullptr && ob->type == OB_MESH) {
      if (Mesh *mesh = static_cast<Mesh *>(ob->data)) {
        if (wanted) {
          mesh->flag |= ME_SCULPT_DYNAMIC_TOPOLOGY;
        }
        else {
          mesh->flag &= ~ME_SCULPT_DYNAMIC_TOPOLOGY;
        }
      }
    }
    return;
  }
  const bool active = BKE_object_sculpt_use_dyntopo(ob);
  if (wanted == active) {
    if (Mesh *mesh = static_cast<Mesh *>(ob->data)) {
      if (wanted) {
        mesh->flag |= ME_SCULPT_DYNAMIC_TOPOLOGY;
      }
      else {
        mesh->flag &= ~ME_SCULPT_DYNAMIC_TOPOLOGY;
      }
    }
    return;
  }
  WM_operator_name_call(
      C, "SCULPT_OT_dynamic_topology_toggle", blender::wm::OpCallContext::ExecDefault, nullptr, nullptr);
  if (Mesh *mesh = static_cast<Mesh *>(ob->data)) {
    if (wanted) {
      mesh->flag |= ME_SCULPT_DYNAMIC_TOPOLOGY;
    }
    else {
      mesh->flag &= ~ME_SCULPT_DYNAMIC_TOPOLOGY;
    }
  }
  char buf[64];
  SNPRINTF(buf, "dyntopo: %s", wanted ? "ON" : "OFF");
  GHOST_IOS_diag_log(buf);
}

#if defined(WITH_APPLE_CROSSPLATFORM) && defined(WITH_MOD_REMESH)
struct WMIOSDualConOutput {
  Mesh *mesh;
  int curvert;
  int curface;
};

static void *wm_ios_dualcon_alloc_output(int totvert, int totquad)
{
  WMIOSDualConOutput *output = MEM_callocN<WMIOSDualConOutput>(__func__);
  output->mesh = BKE_mesh_new_nomain(totvert, 0, totquad, totquad * 4);
  return output;
}

static void wm_ios_dualcon_add_vert(void *output_v, const float co[3])
{
  WMIOSDualConOutput *output = static_cast<WMIOSDualConOutput *>(output_v);
  copy_v3_v3(&output->mesh->vert_positions_for_write()[output->curvert].x, co);
  output->curvert++;
}

static void wm_ios_dualcon_add_quad(void *output_v, const int vert_indices[4])
{
  WMIOSDualConOutput *output = static_cast<WMIOSDualConOutput *>(output_v);
  Mesh *mesh = output->mesh;
  mesh->face_offsets_for_write()[output->curface] = output->curface * 4;
  for (int i = 0; i < 4; i++) {
    mesh->corner_verts_for_write()[output->curface * 4 + i] = vert_indices[i];
  }
  output->curface++;
}

/** OpenVDB-free remesh (same engine as Remesh modifier Smooth / Mass Point). */
static Mesh *wm_ios_immersive_dualcon_remesh(Mesh *mesh)
{
  if (mesh == nullptr || mesh->verts_num <= 0 || mesh->faces_num <= 0) {
    return nullptr;
  }
  /* Force triangulation cache — DualCon needs valid corner_tris. */
  const blender::Span<blender::int3> tris = mesh->corner_tris();
  if (tris.is_empty()) {
    fprintf(stderr, "[immersive] dualcon: no corner_tris\n");
    fflush(stderr);
    return nullptr;
  }

  DualConInput input;
  memset(&input, 0, sizeof(input));
  input.co = (DualConCo)mesh->vert_positions().data();
  input.co_stride = sizeof(blender::float3);
  input.totco = mesh->verts_num;
  input.corner_verts = (DualConCornerVerts)mesh->corner_verts().data();
  input.corner_verts_stride = sizeof(int);
  input.corner_tris = (DualConTri)tris.data();
  input.tri_stride = sizeof(blender::int3);
  input.tottri = int(tris.size());
  const std::optional<blender::Bounds<blender::float3>> bounds = mesh->bounds_min_max();
  if (!bounds) {
    return nullptr;
  }
  copy_v3_v3(input.min, bounds->min);
  copy_v3_v3(input.max, bounds->max);

  /* Defaults match Remesh modifier: smooth mass-point, depth 5. */
  const float threshold = 1.0f;
  const float hermite_num = 1.0f;
  const float scale = 0.9f;
  const int depth = 5;
  DualConFlags flags = DualConFlags(DUALCON_FLOOD_FILL);
  DualConMode mode = DUALCON_MASS_POINT;

  static blender::Mutex dualcon_mutex;
  WMIOSDualConOutput *output = nullptr;
  {
    std::scoped_lock lock(dualcon_mutex);
    output = static_cast<WMIOSDualConOutput *>(dualcon(&input,
                                                       wm_ios_dualcon_alloc_output,
                                                       wm_ios_dualcon_add_vert,
                                                       wm_ios_dualcon_add_quad,
                                                       flags,
                                                       mode,
                                                       threshold,
                                                       hermite_num,
                                                       scale,
                                                       depth));
  }
  if (output == nullptr || output->mesh == nullptr) {
    if (output) {
      MEM_freeN(output);
    }
    return nullptr;
  }
  Mesh *result = output->mesh;
  MEM_freeN(output);
  /* Ensure the face-offset sentinel after DualCon filled faces 0..N-1. */
  if (result->faces_num > 0) {
    result->face_offsets_for_write()[result->faces_num] = result->corners_num;
  }
  blender::bke::mesh_smooth_set(*result, true);
  BKE_mesh_copy_parameters(result, mesh);
  blender::bke::mesh_calc_edges(*result, true, false);
  return result;
}
#endif /* WITH_APPLE_CROSSPLATFORM && WITH_MOD_REMESH */

static ScrArea *wm_ios_immersive_find_view3d_area(bContext *C)
{
  wmWindow *win = CTX_wm_window(C);
  if (win == nullptr) {
    return nullptr;
  }
  bScreen *screen = WM_window_get_active_screen(win);
  if (screen == nullptr) {
    return nullptr;
  }
  LISTBASE_FOREACH (ScrArea *, area, &screen->areabase) {
    if (area->spacetype == SPACE_VIEW3D) {
      return area;
    }
  }
  return nullptr;
}

static ARegion *wm_ios_immersive_find_view3d_window_region(ScrArea *area)
{
  if (area == nullptr) {
    return nullptr;
  }
  LISTBASE_FOREACH (ARegion *, region, &area->regionbase) {
    if (region->regiontype == RGN_TYPE_WINDOW && region->regiondata != nullptr) {
      return region;
    }
  }
  return nullptr;
}

static void wm_ios_immersive_muse_end_stroke(const int ghost_x,
                                             const int ghost_y,
                                             const float pressure)
{
  if (!g_wm_ios_muse_stroke_active) {
    return;
  }
  GHOST_IOS_push_tablet_cursor(ghost_x, ghost_y, pressure);
  GHOST_IOS_push_tablet_button(false, pressure);
  g_wm_ios_muse_stroke_active = false;
}

static float g_wm_ios_muse_edit_last_local[3] = {0.0f, 0.0f, 0.0f};
static bool g_wm_ios_muse_edit_dragging = false;

static float g_wm_ios_muse_sculpt_last_local[3] = {0.0f, 0.0f, 0.0f};
static bool g_wm_ios_muse_sculpt_dragging = false;
static bool g_wm_ios_muse_vpaint_dragging = false;
static int g_wm_ios_muse_last_mode = 0;
/** Immersive Pose/Anim: grabbed pose channel (object-local tip tracking). */
static Object *g_wm_ios_pose_arm_ob = nullptr;
static bPoseChannel *g_wm_ios_pose_pchan = nullptr;
static float g_wm_ios_pose_last_world[3] = {0.0f, 0.0f, 0.0f};
static float g_wm_ios_pose_grab_mid_world[3] = {0.0f, 0.0f, 0.0f};
static bool g_wm_ios_pose_dragging = false;
enum {
  WMIOS_POSE_XFORM_ROTATE = 0,
  WMIOS_POSE_XFORM_MOVE = 1,
  WMIOS_POSE_XFORM_SCALE = 2,
};
static int g_wm_ios_pose_xform_mode = WMIOS_POSE_XFORM_ROTATE;
enum {
  WMIOS_ANIM_TARGET_BONE = 0,
  WMIOS_ANIM_TARGET_OBJECT = 1,
};
static int g_wm_ios_anim_target = WMIOS_ANIM_TARGET_BONE;
static Object *g_wm_ios_obj_grab_ob = nullptr;
static float g_wm_ios_obj_grab_last_world[3] = {0.0f, 0.0f, 0.0f};
static bool g_wm_ios_obj_grab_dragging = false;

static void wm_ios_immersive_muse_cancel_interaction()
{
  g_wm_ios_muse_edit_dragging = false;
  g_wm_ios_muse_sculpt_dragging = false;
  g_wm_ios_muse_vpaint_dragging = false;
  g_wm_ios_muse_sculpt_verts.clear();
  g_wm_ios_muse_sculpt_bm_verts.clear();
  g_wm_ios_muse_stroke_active = false;
  g_wm_ios_pose_dragging = false;
  g_wm_ios_pose_arm_ob = nullptr;
  g_wm_ios_pose_pchan = nullptr;
  g_wm_ios_obj_grab_dragging = false;
  g_wm_ios_obj_grab_ob = nullptr;
}

static bool wm_ios_immersive_muse_interaction_active()
{
  return g_wm_ios_muse_edit_dragging || g_wm_ios_muse_sculpt_dragging ||
         g_wm_ios_muse_vpaint_dragging || g_wm_ios_pose_dragging || g_wm_ios_obj_grab_dragging;
}

/** True while Immersive hand/Muse sculpt is actively deforming geometry (for tip visual). */
extern "C" int WM_IOS_immersive_muse_sculpt_engaged(void)
{
  return (g_wm_ios_muse_sculpt_dragging || g_wm_ios_muse_stroke_active) ? 1 : 0;
}

static void wm_ios_immersive_publish_hand_menu_state(bContext *C, Object *ob)
{
  /* Prefer the Immersive UI sticky mode. Deriving only from the active object
   * snapped Anim → Obj whenever Pose entry failed or no armature was active.
   * Conversely, syncing derived Pose back onto sticky Sculpt/Edit trapped users
   * in Anim after they tapped Sculpt — only follow Blender when sticky is Obj. */
  int mode = g_wm_ios_immersive_ui_mode;
  if (ob != nullptr) {
    int derived = 0;
    if (ob->mode & OB_MODE_VERTEX_PAINT) {
      derived = 3;
    }
    else if (ob->mode & OB_MODE_SCULPT) {
      derived = 2;
    }
    else if ((ob->mode & OB_MODE_EDIT) && ob->type == OB_MESH) {
      derived = 1;
    }
    else if ((ob->mode & OB_MODE_POSE) && ob->type == OB_ARMATURE) {
      derived = 4;
    }
    if (mode == 0 && derived != 0) {
      mode = derived;
      g_wm_ios_immersive_ui_mode = derived;
    }
  }
  float strength = std::clamp(g_wm_ios_muse_strength, 0.05f, 1.0f);
  float radius = std::clamp(g_wm_ios_muse_radius_m, 0.02f, 1.5f);
  const char *brush_base = "Inflate+";
  if (mode == 3) {
    brush_base = g_wm_ios_muse_vpaint_erase ? "VPaint Erase" : "VPaint";
  }
  else {
    switch (g_wm_ios_muse_brush_kind) {
      case WMIOS_MUSE_BRUSH_INFLATE_ADD:
        brush_base = "Inflate+";
        break;
      case WMIOS_MUSE_BRUSH_INFLATE_SUB:
        brush_base = "Inflate-";
        break;
      case WMIOS_MUSE_BRUSH_SMOOTH:
        brush_base = "Smooth";
        break;
      case WMIOS_MUSE_BRUSH_GRAB:
        brush_base = "Grab";
        break;
      case WMIOS_MUSE_BRUSH_CLAY:
        brush_base = "Clay";
        break;
      default:
        brush_base = "Draw";
        break;
    }
  }

  bool has_brush = false;
  if (mode == 2 || mode == 3) {
    if (Scene *scene = CTX_data_scene(C)) {
      const PaintMode paint_mode = (mode == 3) ? PaintMode::Vertex : PaintMode::Sculpt;
      if (Paint *paint = BKE_paint_get_active_from_paintmode(scene, paint_mode)) {
        if (Brush *brush = BKE_paint_brush(paint)) {
          has_brush = true;
          g_wm_ios_paint_brush_ok = true;
          const float alpha = BKE_brush_alpha_get(paint, brush);
          if (alpha > 0.05f && alpha <= 1.0f) {
            strength = alpha;
          }
          const float unprojected = BKE_brush_unprojected_radius_get(paint, brush);
          if (unprojected > 0.02f && unprojected < 1.5f) {
            radius = unprojected;
          }
        }
        else {
          g_wm_ios_paint_brush_ok = false;
        }
      }
    }
  }
  else {
    has_brush = true;
  }

  char brush_label[72];
  if (mode == 0) {
    STRNCPY(brush_label, "閲覧専用");
  }
  else if (mode == 2 || mode == 3) {
    SNPRINTF(brush_label, "%s%s", brush_base, has_brush ? "" : " !NO BRUSH");
  }
  else {
    STRNCPY(brush_label, brush_base);
  }
  /* Encode extra hand-menu state in brush_kind bits for Swift:
   * bit8 = DynTopo wanted, bit9 = proximity sculpt (no pinch). */
  const int kind_pub = g_wm_ios_muse_brush_kind | (g_wm_ios_muse_dyntopo_wanted ? 0x100 : 0) |
                       (g_wm_ios_hand_proximity_sculpt ? 0x200 : 0);
  GHOST_IOS_immersive_update_hand_menu(mode, strength, radius, brush_label, kind_pub);
}

static bool wm_ios_immersive_reload_usdz(bContext *C, Object *ob, const char *reason);

#if defined(WITH_APPLE_CROSSPLATFORM)
static Object *wm_ios_immersive_find_armature(bContext *C, Object *ob)
{
  if (ob != nullptr && ob->type == OB_ARMATURE) {
    return ob;
  }
  if (ob != nullptr && ob->type == OB_MESH) {
    LISTBASE_FOREACH (ModifierData *, md, &ob->modifiers) {
      if (md->type == eModifierType_Armature) {
        ArmatureModifierData *amd = reinterpret_cast<ArmatureModifierData *>(md);
        if (amd->object != nullptr && amd->object->type == OB_ARMATURE) {
          return amd->object;
        }
      }
    }
    if (ob->parent != nullptr && ob->parent->type == OB_ARMATURE) {
      return ob->parent;
    }
  }
  Scene *scene = CTX_data_scene(C);
  ViewLayer *view_layer = CTX_data_view_layer(C);
  if (scene == nullptr || view_layer == nullptr) {
    return nullptr;
  }
  BKE_view_layer_synced_ensure(scene, view_layer);
  LISTBASE_FOREACH (Base *, base, BKE_view_layer_object_bases_get(view_layer)) {
    Object *cand = base->object;
    if (cand != nullptr && cand->type == OB_ARMATURE) {
      return cand;
    }
  }
  return nullptr;
}

/** Activate armature and enter Pose mode (Anim). Returns true if Pose is active. */
static bool wm_ios_immersive_enter_anim_pose(bContext *C, Object *hint_ob)
{
  Object *arm = wm_ios_immersive_find_armature(C, hint_ob);
  if (arm == nullptr) {
    return false;
  }

  ViewLayer *view_layer = CTX_data_view_layer(C);
  Main *bmain = CTX_data_main(C);
  Scene *scene = CTX_data_scene(C);
  Depsgraph *depsgraph = CTX_data_ensure_evaluated_depsgraph(C);

  /* Leave sculpt/edit/paint on the current object before switching active. */
  Object *cur = CTX_data_active_object(C);
  if (cur != nullptr && cur != arm && cur->mode != OB_MODE_OBJECT && bmain && scene && depsgraph) {
    blender::ed::object::mode_generic_exit(bmain, depsgraph, scene, cur);
  }

  if (view_layer != nullptr) {
    if (Base *base = BKE_view_layer_base_find(view_layer, arm)) {
      blender::ed::object::base_activate_with_mode_exit_if_needed(C, base);
      /* Ensure the armature is selected so Pose tools see it. */
      base->flag |= BASE_SELECTED;
    }
  }

  arm = CTX_data_active_object(C);
  if (arm == nullptr || arm->type != OB_ARMATURE) {
    arm = wm_ios_immersive_find_armature(C, nullptr);
  }
  if (arm == nullptr || arm->type != OB_ARMATURE) {
    return false;
  }

  if ((arm->mode & OB_MODE_POSE) == 0) {
    /* Prefer direct enter over OBJECT_OT_posemode_toggle (mode_set) — toggle +
     * toolsystem updates are fragile in Immersive / background-ish context. */
    if (!ED_object_posemode_enter(C, arm)) {
      fprintf(stderr, "[immersive] Anim: posemode_enter failed on %s\n", arm->id.name + 2);
      fflush(stderr);
      GHOST_IOS_diag_log("Anim: pose enter failed");
      return false;
    }
  }

  fprintf(stderr, "[immersive] mode -> Pose (Anim) on %s\n", arm->id.name + 2);
  fflush(stderr);
  GHOST_IOS_diag_log("mode: Pose/Anim");
  return (arm->mode & OB_MODE_POSE) != 0;
}

/**
 * Publish pose bones (Blender world space) + timeline/keyframes to Immersive Swift UI.
 * Packed bone floats: [hx,hy,hz, tx,ty,tz, selected] * count
 */
static void wm_ios_immersive_publish_anim_overlay(bContext *C)
{
  if (g_wm_ios_immersive_ui_mode != 4) {
    GHOST_IOS_immersive_update_bones(0, nullptr);
    GHOST_IOS_immersive_update_anim_timeline(
        1, 1, 250, 0, nullptr, g_wm_ios_pose_xform_mode, g_wm_ios_anim_target, "");
    return;
  }

  Object *ob = CTX_data_active_object(C);
  if (ob == nullptr || ob->type != OB_ARMATURE || (ob->mode & OB_MODE_POSE) == 0 ||
      ob->pose == nullptr)
  {
    ob = wm_ios_immersive_find_armature(C, ob);
  }

  constexpr int kMaxBones = 48;
  float packed[kMaxBones * 7];
  int bone_count = 0;
  const char *active_bone = "";
  if (ob != nullptr && ob->type == OB_ARMATURE && ob->pose != nullptr) {
    /* Avoid re-solving the whole pose every overlay tick — use current channels. */
    LISTBASE_FOREACH (bPoseChannel *, pchan, &ob->pose->chanbase) {
      if (pchan->bone == nullptr) {
        continue;
      }
      bArmature *arm = static_cast<bArmature *>(ob->data);
      if (arm == nullptr || !blender::animrig::bone_is_visible(arm, pchan)) {
        continue;
      }
      /* Skip non-deforming / tip fluff when possible. */
      if (pchan->bone->flag & BONE_NO_DEFORM) {
        continue;
      }
      if (bone_count >= kMaxBones) {
        break;
      }
      float head_world[3], tail_world[3];
      mul_v3_m4v3(head_world, ob->object_to_world().ptr(), pchan->pose_head);
      mul_v3_m4v3(tail_world, ob->object_to_world().ptr(), pchan->pose_tail);
      const float len = len_v3v3(head_world, tail_world);
      if (!(len >= 0.01f && len <= 2.5f)) {
        continue;
      }
      const int i = bone_count * 7;
      packed[i + 0] = head_world[0];
      packed[i + 1] = head_world[1];
      packed[i + 2] = head_world[2];
      packed[i + 3] = tail_world[0];
      packed[i + 4] = tail_world[1];
      packed[i + 5] = tail_world[2];
      const bool selected = (pchan->bone->flag & BONE_SELECTED) != 0;
      packed[i + 6] = selected ? 1.0f : 0.0f;
      if (selected) {
        active_bone = pchan->name;
      }
      bone_count++;
    }
  }
  GHOST_IOS_immersive_update_bones(bone_count, bone_count > 0 ? packed : nullptr);

  Scene *scene = CTX_data_scene(C);
  int cfra = scene ? scene->r.cfra : 1;
  int sfra = scene ? scene->r.sfra : 1;
  int efra = scene ? scene->r.efra : 250;
  if (efra < sfra) {
    std::swap(efra, sfra);
  }

  constexpr int kMaxKeys = 128;
  int keys[kMaxKeys];
  int key_count = 0;
  if (ob != nullptr) {
    if (AnimData *adt = BKE_animdata_from_id(&ob->id)) {
      blender::Vector<FCurve *> fcurves = blender::animrig::legacy::fcurves_for_assigned_action(adt);
      blender::Set<int> unique;
      for (FCurve *fcu : fcurves) {
        if (fcu == nullptr || fcu->bezt == nullptr) {
          continue;
        }
        for (int i = 0; i < fcu->totvert; i++) {
          unique.add(int(roundf(fcu->bezt[i].vec[1][0])));
        }
      }
      blender::Vector<int> sorted;
      for (const int f : unique) {
        sorted.append(f);
      }
      std::sort(sorted.begin(), sorted.end());
      for (const int f : sorted) {
        if (key_count >= kMaxKeys) {
          break;
        }
        keys[key_count++] = f;
      }
    }
  }
  GHOST_IOS_immersive_update_anim_timeline(cfra,
                                             sfra,
                                             efra,
                                             key_count,
                                             key_count > 0 ? keys : nullptr,
                                             g_wm_ios_pose_xform_mode,
                                             g_wm_ios_anim_target,
                                             active_bone);
}

static int wm_ios_shader_node_kind(const bNode &node)
{
  const blender::StringRef id = node.idname;
  if (id.startswith("ShaderNodeOutput")) {
    return 1;
  }
  if (id.find("Bsdf") != blender::StringRef::not_found ||
      id.find("Principled") != blender::StringRef::not_found ||
      id.find("Emission") != blender::StringRef::not_found ||
      id.find("Volume") != blender::StringRef::not_found ||
      id.find("MixShader") != blender::StringRef::not_found ||
      id.find("AddShader") != blender::StringRef::not_found)
  {
    return 2;
  }
  if (id.startswith("ShaderNodeTex")) {
    return 3;
  }
  if (id.find("Math") != blender::StringRef::not_found ||
      id.find("Mix") != blender::StringRef::not_found ||
      id.find("Value") != blender::StringRef::not_found ||
      id.find("RGB") != blender::StringRef::not_found ||
      id.find("MapRange") != blender::StringRef::not_found ||
      id.find("ColorRamp") != blender::StringRef::not_found ||
      id.find("ValToRGB") != blender::StringRef::not_found ||
      id.find("Invert") != blender::StringRef::not_found ||
      id.find("Mapping") != blender::StringRef::not_found ||
      id.find("Bump") != blender::StringRef::not_found ||
      id.find("Normal") != blender::StringRef::not_found ||
      id.find("Separate") != blender::StringRef::not_found ||
      id.find("Combine") != blender::StringRef::not_found ||
      id.find("HueSat") != blender::StringRef::not_found)
  {
    return 4;
  }
  return 0;
}

static int wm_ios_shader_sock_type_code(const int type)
{
  switch (type) {
    case SOCK_FLOAT:
      return 1;
    case SOCK_RGBA:
      return 2;
    case SOCK_VECTOR:
      return 3;
    case SOCK_SHADER:
      return 4;
    case SOCK_INT:
      return 5;
    case SOCK_BOOLEAN:
      return 6;
    default:
      return 0;
  }
}

static bool wm_ios_shader_sock_visible(const bNodeSocket *sock)
{
  return sock != nullptr && (sock->flag & (SOCK_HIDDEN | SOCK_UNAVAIL)) == 0;
}

static int wm_ios_shader_count_socks(const ListBase *lb)
{
  int n = 0;
  LISTBASE_FOREACH (const bNodeSocket *, sock, lb) {
    if (wm_ios_shader_sock_visible(sock)) {
      n++;
    }
  }
  return n;
}

static bNodeSocket *wm_ios_shader_nth_sock(ListBase *lb, const int index)
{
  int i = 0;
  LISTBASE_FOREACH (bNodeSocket *, sock, lb) {
    if (!wm_ios_shader_sock_visible(sock)) {
      continue;
    }
    if (i == index) {
      return sock;
    }
    i++;
  }
  return nullptr;
}

static int wm_ios_shader_sock_index(ListBase *lb, const bNodeSocket *target)
{
  int i = 0;
  LISTBASE_FOREACH (bNodeSocket *, sock, lb) {
    if (!wm_ios_shader_sock_visible(sock)) {
      continue;
    }
    if (sock == target) {
      return i;
    }
    i++;
  }
  return -1;
}

static Material *wm_ios_shader_active_material(bContext *C, Object **r_ob)
{
  Object *ob = CTX_data_active_object(C);
  if (r_ob != nullptr) {
    *r_ob = ob;
  }
  if (ob == nullptr) {
    return nullptr;
  }
  const short act = std::max<short>(ob->actcol, short(1));
  return BKE_object_material_get(ob, act);
}

/** True if Material Output Surface has a usable incoming link. */
static bool wm_ios_shader_surface_connected(bNodeTree *ntree)
{
  if (ntree == nullptr) {
    return false;
  }
  LISTBASE_FOREACH (bNode *, node, &ntree->nodes) {
    if (node == nullptr) {
      continue;
    }
    const bool is_output = (node->idname != nullptr &&
                            STREQ(node->idname, "ShaderNodeOutputMaterial"));
    if (!is_output) {
      continue;
    }
    bNodeSocket *surf = blender::bke::node_find_socket(*node, SOCK_IN, "Surface");
    if (surf == nullptr) {
      return false;
    }
    LISTBASE_FOREACH (const bNodeLink *, link, &ntree->links) {
      if (link == nullptr || link->tosock != surf || link->fromnode == nullptr ||
          link->fromsock == nullptr)
      {
        continue;
      }
      if ((link->flag & NODE_LINK_MUTED) != 0) {
        continue;
      }
      if (link->fromnode->typeinfo == nullptr) {
        continue;
      }
      if ((link->fromnode->flag & NODE_MUTED) != 0) {
        continue;
      }
      return true;
    }
    return false;
  }
  return false;
}

static bool wm_ios_shader_tree_looks_corrupt(bNodeTree *ntree)
{
  if (ntree == nullptr) {
    return true;
  }
  int node_count = 0;
  LISTBASE_FOREACH (bNode *, node, &ntree->nodes) {
    if (node == nullptr) {
      continue;
    }
    node_count++;
    if (node->typeinfo == nullptr) {
      return true;
    }
  }
  /* Empty tree or Output-only with no shader feed. */
  if (node_count == 0) {
    return true;
  }
  return !wm_ios_shader_surface_connected(ntree);
}

/**
 * Repair pink/error materials caused by earlier Immersive Mat builds.
 * Returns true if the material was modified.
 */
static bool wm_ios_shader_repair_material(bContext *C, Material *ma, const bool force_reset)
{
  if (C == nullptr || ma == nullptr) {
    return false;
  }
  Main *bmain = CTX_data_main(C);
  if (bmain == nullptr) {
    return false;
  }

  const bool has_tree = ma->nodetree != nullptr;
  const bool corrupt = has_tree && wm_ios_shader_tree_looks_corrupt(ma->nodetree);

  /* Pure solid material — never touch, even on force. */
  if (!ma->use_nodes && !has_tree) {
    return false;
  }

  /* Healthy node material. */
  if (!force_reset && ma->use_nodes && has_tree && !corrupt) {
    return false;
  }

  /* Orphan / corrupt tree while use_nodes is off — free it. */
  if (!force_reset && !ma->use_nodes && has_tree) {
    blender::bke::node_tree_free_embedded_tree(ma->nodetree);
    ma->nodetree = nullptr;
    DEG_id_tag_update(&ma->id, ID_RECALC_SHADING);
    fprintf(stderr, "[immersive] repaired material '%s': freed orphan nodetree\n", ma->id.name + 2);
    fflush(stderr);
    return true;
  }

  /* Broken / forced node material: replace with default Principled→Surface. */
  if (force_reset || (ma->use_nodes && corrupt) || (ma->use_nodes && !has_tree)) {
    if (ma->nodetree != nullptr) {
      blender::bke::node_tree_free_embedded_tree(ma->nodetree);
      ma->nodetree = nullptr;
    }
    ED_node_shader_default(C, &ma->id);
    ma->use_nodes = true;
    if (ma->nodetree != nullptr) {
      BKE_ntree_update_after_single_tree_change(*bmain, *ma->nodetree);
    }
    DEG_id_tag_update(&ma->id, ID_RECALC_SHADING);
    fprintf(stderr,
            "[immersive] repaired material '%s': %s default Surface\n",
            ma->id.name + 2,
            force_reset ? "forced" : "restored");
    fflush(stderr);
    return true;
  }

  return false;
}

/** Repair every material in Main (not just the active object). */
static int wm_ios_shader_repair_all_materials(bContext *C, const bool force_reset)
{
  Main *bmain = CTX_data_main(C);
  if (bmain == nullptr) {
    return 0;
  }
  int repaired = 0;
  LISTBASE_FOREACH (Material *, ma, &bmain->materials) {
    if (wm_ios_shader_repair_material(C, ma, force_reset)) {
      repaired++;
    }
  }
  if (repaired > 0) {
    char buf[96];
    SNPRINTF(buf, "shader: repaired %d materials", repaired);
    GHOST_IOS_diag_log(buf);
    fprintf(stderr, "[immersive] repaired %d material(s)%s\n",
            repaired,
            force_reset ? " (forced)" : "");
    fflush(stderr);
  }
  return repaired;
}

static void wm_ios_shader_repair_active_object_materials(bContext *C)
{
  /* Keep name for call sites — now repairs the whole Main datablock list. */
  wm_ios_shader_repair_all_materials(C, false);
}

static bNode *wm_ios_shader_find_node(bNodeTree *ntree, const char *name)
{
  if (ntree == nullptr || name == nullptr || name[0] == '\0') {
    return nullptr;
  }
  LISTBASE_FOREACH (bNode *, node, &ntree->nodes) {
    if (node != nullptr && STREQ(node->name, name)) {
      return node;
    }
  }
  return nullptr;
}

static bNodeSocket *wm_ios_shader_find_sock(bNode *node,
                                             const eNodeSocketInOut in_out,
                                             const char *identifier)
{
  if (node == nullptr || identifier == nullptr || identifier[0] == '\0') {
    return nullptr;
  }
  return blender::bke::node_find_socket(*node, in_out, identifier);
}

static void wm_ios_shader_tag_material(Main *bmain, Material *ma, bNodeTree *ntree, bNode *node)
{
  if (ntree != nullptr && node != nullptr) {
    BKE_ntree_update_tag_node_property(ntree, node);
  }
  if (bmain != nullptr && ntree != nullptr) {
    BKE_ntree_update_after_single_tree_change(*bmain, *ntree);
  }
  if (ma != nullptr) {
    DEG_id_tag_update(&ma->id, ID_RECALC_SHADING);
  }
}

static void wm_ios_shader_select_only(bNodeTree *ntree, bNode *target)
{
  LISTBASE_FOREACH (bNode *, node, &ntree->nodes) {
    if (node == nullptr) {
      continue;
    }
    if (node == target) {
      node->flag |= NODE_SELECT;
      STRNCPY(g_wm_ios_shader_selected, node->name);
    }
    else {
      node->flag &= ~NODE_SELECT;
    }
  }
  if (target == nullptr) {
    g_wm_ios_shader_selected[0] = '\0';
  }
}

static void wm_ios_immersive_apply_shader_cmds(bContext *C)
{
  bool pending_move = false;
  bool pending_select = false;
  bool pending_add = false;
  bool pending_delete = false;
  bool pending_connect = false;
  bool pending_disconnect = false;
  bool pending_sock_float = false;
  bool pending_sock_rgba = false;
  bool pending_repair = false;
  bool repair_force = false;
  char move_name[64];
  char select_name[64];
  char add_idname[64];
  char delete_name[64];
  char conn_from_node[64];
  char conn_from_sock[64];
  char conn_to_node[64];
  char conn_to_sock[64];
  char disc_to_node[64];
  char disc_to_sock[64];
  char sockf_node[64];
  char sockf_id[64];
  char sockc_node[64];
  char sockc_id[64];
  float move_x = 0.0f;
  float move_y = 0.0f;
  float add_x = 0.0f;
  float add_y = 0.0f;
  float sockf_value = 0.0f;
  float sockc_rgba[4] = {0.8f, 0.8f, 0.8f, 1.0f};
  {
    std::lock_guard lock(g_wm_ios_shader_cmd.mutex);
    pending_move = g_wm_ios_shader_cmd.pending_move;
    pending_select = g_wm_ios_shader_cmd.pending_select;
    pending_add = g_wm_ios_shader_cmd.pending_add;
    pending_delete = g_wm_ios_shader_cmd.pending_delete;
    pending_connect = g_wm_ios_shader_cmd.pending_connect;
    pending_disconnect = g_wm_ios_shader_cmd.pending_disconnect;
    pending_sock_float = g_wm_ios_shader_cmd.pending_sock_float;
    pending_sock_rgba = g_wm_ios_shader_cmd.pending_sock_rgba;
    pending_repair = g_wm_ios_shader_cmd.pending_repair;
    repair_force = g_wm_ios_shader_cmd.repair_force;
    STRNCPY(move_name, g_wm_ios_shader_cmd.move_name);
    STRNCPY(select_name, g_wm_ios_shader_cmd.select_name);
    STRNCPY(add_idname, g_wm_ios_shader_cmd.add_idname);
    STRNCPY(delete_name, g_wm_ios_shader_cmd.delete_name);
    STRNCPY(conn_from_node, g_wm_ios_shader_cmd.conn_from_node);
    STRNCPY(conn_from_sock, g_wm_ios_shader_cmd.conn_from_sock);
    STRNCPY(conn_to_node, g_wm_ios_shader_cmd.conn_to_node);
    STRNCPY(conn_to_sock, g_wm_ios_shader_cmd.conn_to_sock);
    STRNCPY(disc_to_node, g_wm_ios_shader_cmd.disc_to_node);
    STRNCPY(disc_to_sock, g_wm_ios_shader_cmd.disc_to_sock);
    STRNCPY(sockf_node, g_wm_ios_shader_cmd.sockf_node);
    STRNCPY(sockf_id, g_wm_ios_shader_cmd.sockf_id);
    STRNCPY(sockc_node, g_wm_ios_shader_cmd.sockc_node);
    STRNCPY(sockc_id, g_wm_ios_shader_cmd.sockc_id);
    move_x = g_wm_ios_shader_cmd.move_x;
    move_y = g_wm_ios_shader_cmd.move_y;
    add_x = g_wm_ios_shader_cmd.add_x;
    add_y = g_wm_ios_shader_cmd.add_y;
    sockf_value = g_wm_ios_shader_cmd.sockf_value;
    copy_v4_v4(sockc_rgba, g_wm_ios_shader_cmd.sockc_rgba);
    g_wm_ios_shader_cmd.pending_move = false;
    g_wm_ios_shader_cmd.pending_select = false;
    g_wm_ios_shader_cmd.pending_add = false;
    g_wm_ios_shader_cmd.pending_delete = false;
    g_wm_ios_shader_cmd.pending_connect = false;
    g_wm_ios_shader_cmd.pending_disconnect = false;
    g_wm_ios_shader_cmd.pending_sock_float = false;
    g_wm_ios_shader_cmd.pending_sock_rgba = false;
    g_wm_ios_shader_cmd.pending_repair = false;
    g_wm_ios_shader_cmd.repair_force = false;
  }
  if (pending_repair) {
    wm_ios_shader_repair_all_materials(C, repair_force);
    /* Continue if other cmds are queued; otherwise done. */
  }
  if (!(pending_move || pending_select || pending_add || pending_delete || pending_connect ||
        pending_disconnect || pending_sock_float || pending_sock_rgba))
  {
    return;
  }

  Main *bmain = CTX_data_main(C);
  Material *ma = wm_ios_shader_active_material(C, nullptr);
  if (ma == nullptr) {
    return;
  }
  /* Never flip use_nodes on existing solid materials — that turns them purple.
   * Only initialize a default node tree when the user explicitly adds a node. */
  if (!ma->use_nodes || ma->nodetree == nullptr) {
    if (pending_add) {
      if (ma->nodetree != nullptr && !ma->use_nodes) {
        blender::bke::node_tree_free_embedded_tree(ma->nodetree);
        ma->nodetree = nullptr;
      }
      ED_node_shader_default(C, &ma->id);
      ma->use_nodes = true;
    }
    if (!ma->use_nodes || ma->nodetree == nullptr) {
      return;
    }
  }
  else {
    /* Heal pink/error materials before applying edits. */
    wm_ios_shader_repair_material(C, ma, false);
    if (ma->nodetree == nullptr || !ma->use_nodes) {
      return;
    }
  }
  bNodeTree *ntree = ma->nodetree;

  if (pending_select) {
    if (select_name[0] == '\0') {
      wm_ios_shader_select_only(ntree, nullptr);
    }
    else if (bNode *node = wm_ios_shader_find_node(ntree, select_name)) {
      wm_ios_shader_select_only(ntree, node);
    }
  }

  if (pending_move) {
    if (bNode *node = wm_ios_shader_find_node(ntree, move_name)) {
      node->location[0] = move_x;
      node->location[1] = move_y;
      node->locx_legacy = move_x;
      node->locy_legacy = move_y;
      /* Location-only: avoid full shading rebuild. */
      BKE_ntree_update_tag_node_property(ntree, node);
    }
  }

  if (pending_add) {
    if (blender::bke::node_type_find(add_idname) == nullptr) {
      /* Unknown type — ignore. */
    }
    else if (bNode *node = blender::bke::node_add_node(C, *ntree, add_idname)) {
      node->location[0] = add_x;
      node->location[1] = add_y;
      node->locx_legacy = add_x;
      node->locy_legacy = add_y;
      wm_ios_shader_select_only(ntree, node);
      wm_ios_shader_tag_material(bmain, ma, ntree, node);
    }
  }

  if (pending_delete) {
    if (bNode *node = wm_ios_shader_find_node(ntree, delete_name)) {
      /* Keep Material Output — removing it breaks shading. */
      if (!blender::StringRef(node->idname).startswith("ShaderNodeOutput")) {
        /* Don't delete the last shader feeding Surface — that turns materials pink. */
        bool feeds_surface = false;
        LISTBASE_FOREACH (const bNodeLink *, link, &ntree->links) {
          if (link == nullptr || link->fromnode != node || link->tonode == nullptr) {
            continue;
          }
          if (STREQ(link->tonode->idname, "ShaderNodeOutputMaterial") && link->tosock != nullptr &&
              STREQ(link->tosock->identifier, "Surface"))
          {
            feeds_surface = true;
            break;
          }
        }
        int other_surface_feeds = 0;
        if (feeds_surface) {
          LISTBASE_FOREACH (const bNodeLink *, link, &ntree->links) {
            if (link == nullptr || link->fromnode == node || link->tonode == nullptr ||
                link->tosock == nullptr)
            {
              continue;
            }
            if (STREQ(link->tonode->idname, "ShaderNodeOutputMaterial") &&
                STREQ(link->tosock->identifier, "Surface"))
            {
              other_surface_feeds++;
            }
          }
        }
        if (feeds_surface && other_surface_feeds == 0) {
          fprintf(stderr,
                  "[immersive] refuse delete '%s' — last Surface shader\n",
                  delete_name);
          fflush(stderr);
        }
        else {
          if (STREQ(g_wm_ios_shader_selected, node->name)) {
            g_wm_ios_shader_selected[0] = '\0';
          }
          blender::bke::node_remove_node(bmain, *ntree, *node, true);
          if (bmain != nullptr) {
            BKE_ntree_update_after_single_tree_change(*bmain, *ntree);
          }
          DEG_id_tag_update(&ma->id, ID_RECALC_SHADING);
        }
      }
    }
  }

  if (pending_disconnect) {
    if (bNode *tonode = wm_ios_shader_find_node(ntree, disc_to_node)) {
      if (bNodeSocket *tosock = wm_ios_shader_find_sock(tonode, SOCK_IN, disc_to_sock)) {
        LISTBASE_FOREACH_MUTABLE (bNodeLink *, link, &ntree->links) {
          if (link != nullptr && link->tonode == tonode && link->tosock == tosock) {
            blender::bke::node_remove_link(ntree, *link);
          }
        }
        if (bmain != nullptr) {
          BKE_ntree_update_after_single_tree_change(*bmain, *ntree);
        }
        DEG_id_tag_update(&ma->id, ID_RECALC_SHADING);
      }
    }
  }

  if (pending_connect) {
    bNode *fromnode = wm_ios_shader_find_node(ntree, conn_from_node);
    bNode *tonode = wm_ios_shader_find_node(ntree, conn_to_node);
    bNodeSocket *fromsock = nullptr;
    bNodeSocket *tosock = nullptr;
    if (conn_from_sock[0] != '\0' && conn_to_sock[0] != '\0') {
      fromsock = wm_ios_shader_find_sock(fromnode, SOCK_OUT, conn_from_sock);
      tosock = wm_ios_shader_find_sock(tonode, SOCK_IN, conn_to_sock);
    }
    else if (fromnode != nullptr && tonode != nullptr && fromnode != tonode) {
      /* Auto-pick first compatible output→input pair. Prefer common names. */
      const char *pref_out[] = {"BSDF", "Shader", "Color", "Fac", "Value", "Emission", nullptr};
      const char *pref_in[] = {"Surface", "Shader", "Color", "Fac", "Value", "Base Color", nullptr};
      auto try_pair = [&](const char *oid, const char *iid) -> bool {
        bNodeSocket *fo = wm_ios_shader_find_sock(fromnode, SOCK_OUT, oid);
        bNodeSocket *ti = wm_ios_shader_find_sock(tonode, SOCK_IN, iid);
        if (fo == nullptr || ti == nullptr) {
          return false;
        }
        if (ntree->typeinfo != nullptr && ntree->typeinfo->validate_link != nullptr) {
          if (!ntree->typeinfo->validate_link(eNodeSocketDatatype(fo->type),
                                              eNodeSocketDatatype(ti->type)))
          {
            return false;
          }
        }
        fromsock = fo;
        tosock = ti;
        return true;
      };
      for (int oi = 0; pref_out[oi] != nullptr && fromsock == nullptr; oi++) {
        for (int ii = 0; pref_in[ii] != nullptr; ii++) {
          if (try_pair(pref_out[oi], pref_in[ii])) {
            break;
          }
        }
      }
      if (fromsock == nullptr) {
        LISTBASE_FOREACH (bNodeSocket *, fo, &fromnode->outputs) {
          if (!wm_ios_shader_sock_visible(fo)) {
            continue;
          }
          LISTBASE_FOREACH (bNodeSocket *, ti, &tonode->inputs) {
            if (!wm_ios_shader_sock_visible(ti)) {
              continue;
            }
            bool ok = true;
            if (ntree->typeinfo != nullptr && ntree->typeinfo->validate_link != nullptr) {
              ok = ntree->typeinfo->validate_link(eNodeSocketDatatype(fo->type),
                                                  eNodeSocketDatatype(ti->type));
            }
            if (ok) {
              fromsock = fo;
              tosock = ti;
              break;
            }
          }
          if (fromsock != nullptr) {
            break;
          }
        }
      }
    }
    const bool sockets_ok = fromnode != nullptr && tonode != nullptr && fromsock != nullptr &&
                            tosock != nullptr && fromnode != tonode &&
                            eNodeSocketInOut(fromsock->in_out) == SOCK_OUT &&
                            eNodeSocketInOut(tosock->in_out) == SOCK_IN;
    bool types_ok = sockets_ok;
    if (sockets_ok && ntree->typeinfo != nullptr && ntree->typeinfo->validate_link != nullptr) {
      types_ok = ntree->typeinfo->validate_link(eNodeSocketDatatype(fromsock->type),
                                                eNodeSocketDatatype(tosock->type));
    }
    /* Validate before removing any existing link — a failed connect must not
     * leave the material disconnected (purple error shader). */
    if (sockets_ok && types_ok) {
      LISTBASE_FOREACH_MUTABLE (bNodeLink *, link, &ntree->links) {
        if (link != nullptr && link->tonode == tonode && link->tosock == tosock) {
          blender::bke::node_remove_link(ntree, *link);
        }
      }
      blender::bke::node_add_link(*ntree, *fromnode, *fromsock, *tonode, *tosock);
      if (bmain != nullptr) {
        BKE_ntree_update_after_single_tree_change(*bmain, *ntree);
      }
      DEG_id_tag_update(&ma->id, ID_RECALC_SHADING);
      fprintf(stderr,
              "[immersive] connected %s.%s → %s.%s\n",
              fromnode->name,
              fromsock->identifier,
              tonode->name,
              tosock->identifier);
      fflush(stderr);
    }
  }

  if (pending_sock_float) {
    if (bNode *node = wm_ios_shader_find_node(ntree, sockf_node)) {
      bNodeSocket *sock = wm_ios_shader_find_sock(node, SOCK_IN, sockf_id);
      if (sock == nullptr) {
        sock = wm_ios_shader_find_sock(node, SOCK_OUT, sockf_id);
      }
      if (sock != nullptr && sock->type == SOCK_FLOAT && sock->default_value != nullptr) {
        bool linked = false;
        LISTBASE_FOREACH (const bNodeLink *, link, &ntree->links) {
          if (link != nullptr && link->tosock == sock) {
            linked = true;
            break;
          }
        }
        if (!linked) {
          auto *val = static_cast<bNodeSocketValueFloat *>(sock->default_value);
          val->value = sockf_value;
          BKE_ntree_update_tag_socket_property(ntree, sock);
          wm_ios_shader_tag_material(bmain, ma, ntree, node);
        }
      }
    }
  }

  if (pending_sock_rgba) {
    if (bNode *node = wm_ios_shader_find_node(ntree, sockc_node)) {
      bNodeSocket *sock = wm_ios_shader_find_sock(node, SOCK_IN, sockc_id);
      if (sock == nullptr) {
        sock = wm_ios_shader_find_sock(node, SOCK_OUT, sockc_id);
      }
      if (sock != nullptr && sock->type == SOCK_RGBA && sock->default_value != nullptr) {
        bool linked = false;
        LISTBASE_FOREACH (const bNodeLink *, link, &ntree->links) {
          if (link != nullptr && link->tosock == sock) {
            linked = true;
            break;
          }
        }
        if (!linked) {
          auto *val = static_cast<bNodeSocketValueRGBA *>(sock->default_value);
          copy_v4_v4(val->value, sockc_rgba);
          BKE_ntree_update_tag_socket_property(ntree, sock);
          wm_ios_shader_tag_material(bmain, ma, ntree, node);
        }
      }
    }
  }
}

/**
 * Publish active object's material node tree for Immersive Shading editor.
 * node_packed: [x, y, kind, selected, in_count, out_count] * N
 * link_packed: [from_node, from_out_idx, to_node, to_in_idx] * M
 * sock_types: type codes in node order (inputs then outputs)
 */
static void wm_ios_immersive_publish_shader_graph(bContext *C)
{
  if (!g_wm_ios_shader_space) {
    GHOST_IOS_immersive_update_shader_graph(
        "", 0, nullptr, "", "", 0, nullptr, 0, nullptr, "");
    GHOST_IOS_immersive_update_shader_props("", "", 0, nullptr, "");
    return;
  }

  wm_ios_shader_repair_active_object_materials(C);

  Material *ma = wm_ios_shader_active_material(C, nullptr);
  if (ma == nullptr || ma->nodetree == nullptr || !ma->use_nodes) {
    GHOST_IOS_immersive_update_shader_graph(ma != nullptr ? (ma->id.name + 2) : "",
                                            0,
                                            nullptr,
                                            "",
                                            "",
                                            0,
                                            nullptr,
                                            0,
                                            nullptr,
                                            "");
    GHOST_IOS_immersive_update_shader_props("", "", 0, nullptr, "");
    return;
  }

  bNodeTree *ntree = ma->nodetree;

  constexpr int kMaxNodes = 8;
  constexpr int kMaxLinks = 24;
  constexpr int kMaxSocks = 64;
  constexpr int kStride = 6;
  constexpr int kLinkStride = 4;
  float node_packed[kMaxNodes * kStride];
  int link_packed[kMaxLinks * kLinkStride];
  int sock_types[kMaxSocks];
  int node_count = 0;
  int link_count = 0;
  int sock_count = 0;
  std::string names;
  std::string type_names;
  std::string sock_names;
  blender::Map<const bNode *, int> index_of;

  LISTBASE_FOREACH (bNode *, node, &ntree->nodes) {
    if (node == nullptr || node->typeinfo == nullptr) {
      continue;
    }
    if (STREQ(node->idname, "NodeFrame") || STREQ(node->idname, "NodeReroute")) {
      continue;
    }
    if (node_count >= kMaxNodes) {
      break;
    }
    index_of.add_overwrite(node, node_count);
    const int in_full = wm_ios_shader_count_socks(&node->inputs);
    const int out_full = wm_ios_shader_count_socks(&node->outputs);
    /* Cap spatial sockets — too many RealityKit entities crash Mat entry. */
    constexpr int kMaxInShow = 4;
    constexpr int kMaxOutShow = 2;
    const int in_count = std::min(in_full, kMaxInShow);
    const int out_count = std::min(out_full, kMaxOutShow);
    const int o = node_count * kStride;
    node_packed[o + 0] = node->location[0];
    node_packed[o + 1] = node->location[1];
    node_packed[o + 2] = float(wm_ios_shader_node_kind(*node));
    /* Immersive selection only — ignore desktop NODE_SELECT (avoids Mat-entry
     * prop editors opening immediately with potentially bad slider ranges). */
    const bool selected = (g_wm_ios_shader_selected[0] != '\0' &&
                           STREQ(node->name, g_wm_ios_shader_selected));
    node_packed[o + 3] = selected ? 1.0f : 0.0f;
    node_packed[o + 4] = float(in_count);
    node_packed[o + 5] = float(out_count);
    if (!names.empty()) {
      names.push_back('|');
      type_names.push_back('|');
    }
    names.append(node->name);
    type_names.append(node->idname);

    auto append_socks = [&](ListBase *lb, const int limit) {
      int added = 0;
      LISTBASE_FOREACH (bNodeSocket *, sock, lb) {
        if (!wm_ios_shader_sock_visible(sock) || sock_count >= kMaxSocks || added >= limit) {
          continue;
        }
        sock_types[sock_count] = wm_ios_shader_sock_type_code(sock->type);
        if (!sock_names.empty()) {
          sock_names.push_back('|');
        }
        sock_names.append(sock->identifier[0] != '\0' ? sock->identifier : sock->name);
        sock_count++;
        added++;
      }
    };
    append_socks(&node->inputs, in_count);
    append_socks(&node->outputs, out_count);
    node_count++;
  }

  LISTBASE_FOREACH (bNodeLink *, link, &ntree->links) {
    if (link == nullptr || link->fromnode == nullptr || link->tonode == nullptr ||
        link->fromsock == nullptr || link->tosock == nullptr)
    {
      continue;
    }
    const int *from_i = index_of.lookup_ptr(link->fromnode);
    const int *to_i = index_of.lookup_ptr(link->tonode);
    if (from_i == nullptr || to_i == nullptr) {
      continue;
    }
    const int from_out = wm_ios_shader_sock_index(&link->fromnode->outputs, link->fromsock);
    const int to_in = wm_ios_shader_sock_index(&link->tonode->inputs, link->tosock);
    /* Skip links to sockets we didn't publish (capped). */
    if (from_out < 0 || to_in < 0) {
      continue;
    }
    const int from_o = (*from_i) * kStride;
    const int to_o = (*to_i) * kStride;
    if (from_out >= int(node_packed[from_o + 5]) || to_in >= int(node_packed[to_o + 4])) {
      continue;
    }
    if (link_count >= kMaxLinks) {
      break;
    }
    const int lo = link_count * kLinkStride;
    link_packed[lo + 0] = *from_i;
    link_packed[lo + 1] = from_out;
    link_packed[lo + 2] = *to_i;
    link_packed[lo + 3] = to_in;
    link_count++;
  }

  GHOST_IOS_immersive_update_shader_graph(ma->id.name + 2,
                                          node_count,
                                          node_count > 0 ? node_packed : nullptr,
                                          names.c_str(),
                                          type_names.c_str(),
                                          link_count,
                                          link_count > 0 ? link_packed : nullptr,
                                          sock_count,
                                          sock_count > 0 ? sock_types : nullptr,
                                          sock_names.c_str());

  /* Selected node typed properties (socket defaults). */
  constexpr int kMaxProps = 16;
  constexpr int kPropStride = 8;
  float prop_packed[kMaxProps * kPropStride];
  int prop_count = 0;
  std::string prop_names;
  std::string type_id;
  if (bNode *sel = wm_ios_shader_find_node(ntree, g_wm_ios_shader_selected)) {
    type_id = sel->idname;
    auto publish_sock = [&](bNodeSocket *sock) {
      if (sock == nullptr || sock->typeinfo == nullptr || sock->default_value == nullptr ||
          prop_count >= kMaxProps)
      {
        return;
      }
      if (sock->type != SOCK_FLOAT && sock->type != SOCK_RGBA && sock->type != SOCK_VECTOR) {
        return;
      }
      /* Prefer link-list over sock->link — dangling link pointers crash after bad edits. */
      bool is_linked = false;
      LISTBASE_FOREACH (const bNodeLink *, link, &ntree->links) {
        if (link != nullptr && link->tosock == sock) {
          is_linked = true;
          break;
        }
      }
      const int o = prop_count * kPropStride;
      prop_packed[o + 0] = float(wm_ios_shader_sock_type_code(sock->type));
      prop_packed[o + 1] = is_linked ? 1.0f : 0.0f;
      prop_packed[o + 2] = 0.0f;
      prop_packed[o + 3] = 0.0f;
      prop_packed[o + 4] = 0.0f;
      prop_packed[o + 5] = 1.0f;
      prop_packed[o + 6] = 0.0f;
      prop_packed[o + 7] = 1.0f;
      if (sock->type == SOCK_FLOAT) {
        const auto *val = static_cast<const bNodeSocketValueFloat *>(sock->default_value);
        prop_packed[o + 2] = std::isfinite(val->value) ? val->value : 0.0f;
        const float mn = val->min;
        const float mx = val->max;
        prop_packed[o + 6] = std::isfinite(mn) ? mn : 0.0f;
        prop_packed[o + 7] = (std::isfinite(mx) && mx > prop_packed[o + 6]) ?
                                 mx :
                                 (prop_packed[o + 6] + 1.0f);
      }
      else if (sock->type == SOCK_RGBA) {
        const auto *val = static_cast<const bNodeSocketValueRGBA *>(sock->default_value);
        for (int c = 0; c < 4; c++) {
          const float v = val->value[c];
          prop_packed[o + 2 + c] = std::isfinite(v) ? std::clamp(v, 0.0f, 1.0f) : (c == 3 ? 1.0f : 0.8f);
        }
      }
      else if (sock->type == SOCK_VECTOR) {
        const auto *val = static_cast<const bNodeSocketValueVector *>(sock->default_value);
        for (int c = 0; c < 3; c++) {
          const float v = val->value[c];
          prop_packed[o + 2 + c] = std::isfinite(v) ? v : 0.0f;
        }
        const float mn = val->min;
        const float mx = val->max;
        prop_packed[o + 6] = std::isfinite(mn) ? mn : 0.0f;
        prop_packed[o + 7] = (std::isfinite(mx) && mx > prop_packed[o + 6]) ?
                                 mx :
                                 (prop_packed[o + 6] + 1.0f);
      }
      if (!prop_names.empty()) {
        prop_names.push_back('|');
      }
      prop_names.append(sock->identifier[0] != '\0' ? sock->identifier : sock->name);
      prop_count++;
    };

    LISTBASE_FOREACH (bNodeSocket *, sock, &sel->inputs) {
      if (!wm_ios_shader_sock_visible(sock)) {
        continue;
      }
      publish_sock(sock);
    }
    /* RGB / Value nodes expose defaults on outputs. */
    if (prop_count == 0) {
      LISTBASE_FOREACH (bNodeSocket *, sock, &sel->outputs) {
        if (!wm_ios_shader_sock_visible(sock)) {
          continue;
        }
        if (STREQ(sock->identifier, "Color") || STREQ(sock->identifier, "Value") ||
            STREQ(sock->name, "Color") || STREQ(sock->name, "Value"))
        {
          publish_sock(sock);
        }
      }
    }
  }

  GHOST_IOS_immersive_update_shader_props(g_wm_ios_shader_selected,
                                          type_id.c_str(),
                                          prop_count,
                                          prop_count > 0 ? prop_packed : nullptr,
                                          prop_names.c_str());
}
#endif

static void wm_ios_immersive_apply_hand_menu(bContext *C)
{
  bool pending_mode = false;
  int mode = 0;
  bool pending_brush = false;
  int brush_kind = WMIOS_MUSE_BRUSH_DRAW;
  char brush_tool_id[64] = "";
  bool pending_strength = false;
  float strength = 0.5f;
  bool pending_radius = false;
  float radius = 0.25f;
  bool pending_dismiss = false;
  bool pending_remesh = false;
  bool pending_dyntopo = false;
  int dyntopo = 1;
  bool pending_anim_key = false;
  bool pending_anim_key_delete = false;
  bool pending_anim_play = false;
  bool pending_anim_stop = false;
  bool pending_anim_frame = false;
  int anim_frame_delta = 0;
  bool pending_anim_set_frame = false;
  int anim_set_frame = 1;
  bool pending_pose_xform = false;
  int pose_xform_mode = WMIOS_POSE_XFORM_ROTATE;
  bool pending_anim_target = false;
  int anim_target = WMIOS_ANIM_TARGET_BONE;
  bool pending_camera_key = false;
  {
    std::lock_guard lock(g_wm_ios_hand_menu_cmd.mutex);
    pending_mode = g_wm_ios_hand_menu_cmd.pending_mode;
    mode = g_wm_ios_hand_menu_cmd.mode;
    pending_brush = g_wm_ios_hand_menu_cmd.pending_brush;
    brush_kind = g_wm_ios_hand_menu_cmd.brush_kind;
    STRNCPY(brush_tool_id, g_wm_ios_hand_menu_cmd.brush_tool_id);
    pending_strength = g_wm_ios_hand_menu_cmd.pending_strength;
    strength = g_wm_ios_hand_menu_cmd.strength;
    pending_radius = g_wm_ios_hand_menu_cmd.pending_radius;
    radius = g_wm_ios_hand_menu_cmd.radius;
    pending_dismiss = g_wm_ios_hand_menu_cmd.pending_dismiss;
    pending_remesh = g_wm_ios_hand_menu_cmd.pending_remesh;
    pending_dyntopo = g_wm_ios_hand_menu_cmd.pending_dyntopo;
    dyntopo = g_wm_ios_hand_menu_cmd.dyntopo;
    pending_anim_key = g_wm_ios_hand_menu_cmd.pending_anim_key;
    pending_anim_key_delete = g_wm_ios_hand_menu_cmd.pending_anim_key_delete;
    pending_anim_play = g_wm_ios_hand_menu_cmd.pending_anim_play;
    pending_anim_stop = g_wm_ios_hand_menu_cmd.pending_anim_stop;
    pending_anim_frame = g_wm_ios_hand_menu_cmd.pending_anim_frame;
    anim_frame_delta = g_wm_ios_hand_menu_cmd.anim_frame_delta;
    pending_anim_set_frame = g_wm_ios_hand_menu_cmd.pending_anim_set_frame;
    anim_set_frame = g_wm_ios_hand_menu_cmd.anim_set_frame;
    pending_pose_xform = g_wm_ios_hand_menu_cmd.pending_pose_xform;
    pose_xform_mode = g_wm_ios_hand_menu_cmd.pose_xform_mode;
    pending_anim_target = g_wm_ios_hand_menu_cmd.pending_anim_target;
    anim_target = g_wm_ios_hand_menu_cmd.anim_target;
    pending_camera_key = g_wm_ios_hand_menu_cmd.pending_camera_key;
    g_wm_ios_hand_menu_cmd.pending_mode = false;
    g_wm_ios_hand_menu_cmd.pending_brush = false;
    g_wm_ios_hand_menu_cmd.pending_strength = false;
    g_wm_ios_hand_menu_cmd.pending_radius = false;
    g_wm_ios_hand_menu_cmd.pending_dismiss = false;
    g_wm_ios_hand_menu_cmd.pending_remesh = false;
    g_wm_ios_hand_menu_cmd.pending_dyntopo = false;
    g_wm_ios_hand_menu_cmd.pending_anim_key = false;
    g_wm_ios_hand_menu_cmd.pending_anim_key_delete = false;
    g_wm_ios_hand_menu_cmd.pending_anim_play = false;
    g_wm_ios_hand_menu_cmd.pending_anim_stop = false;
    g_wm_ios_hand_menu_cmd.pending_anim_frame = false;
    g_wm_ios_hand_menu_cmd.pending_anim_set_frame = false;
    g_wm_ios_hand_menu_cmd.pending_pose_xform = false;
    g_wm_ios_hand_menu_cmd.pending_anim_target = false;
    g_wm_ios_hand_menu_cmd.pending_camera_key = false;
  }

  if (pending_pose_xform) {
    g_wm_ios_pose_xform_mode = std::clamp(pose_xform_mode, 0, 2);
  }
  if (pending_anim_target) {
    g_wm_ios_anim_target = std::clamp(anim_target, 0, 1);
    wm_ios_immersive_muse_cancel_interaction();
  }

  if (g_wm_ios_shader_space) {
    /* Apply pending Mat cmds every sync so move/connect feel responsive.
     * Publish stays throttled below to limit RealityKit rebuilds. */
    wm_ios_immersive_apply_shader_cmds(C);
  }

  if (!(pending_mode || pending_brush || pending_strength || pending_radius || pending_dismiss ||
        pending_remesh || pending_dyntopo || pending_anim_key || pending_anim_key_delete ||
        pending_anim_play || pending_anim_stop || pending_anim_frame || pending_anim_set_frame ||
        pending_pose_xform || pending_anim_target || pending_camera_key))
  {
    static double last_publish = 0.0;
    static double last_anim_retry = 0.0;
    const double now = BLI_time_now_seconds();
    /* Anim sticky: keep retrying Pose entry until an armature is available. */
    if (g_wm_ios_immersive_ui_mode == 4 && now - last_anim_retry >= 1.0) {
      last_anim_retry = now;
      Object *ob_try = CTX_data_active_object(C);
      const bool in_pose = (ob_try != nullptr) && (ob_try->type == OB_ARMATURE) &&
                           ((ob_try->mode & OB_MODE_POSE) != 0);
      if (!in_pose) {
        ScrArea *area = wm_ios_immersive_find_view3d_area(C);
        ARegion *region = wm_ios_immersive_find_view3d_window_region(area);
        ScrArea *area_prev = CTX_wm_area(C);
        ARegion *region_prev = CTX_wm_region(C);
        if (area != nullptr) {
          CTX_wm_area_set(C, area);
        }
        if (region != nullptr) {
          CTX_wm_region_set(C, region);
        }
        wm_ios_immersive_enter_anim_pose(C, ob_try);
        CTX_wm_area_set(C, area_prev);
        CTX_wm_region_set(C, region_prev);
      }
    }
    if (now - last_publish >= 1.0) {
      last_publish = now;
      Object *ob_pub = CTX_data_active_object(C);
      /* Keep DynTopo in sync with Immersive default/wanted while sculpting. */
      if (ob_pub != nullptr && (ob_pub->mode & OB_MODE_SCULPT) != 0) {
        wm_ios_immersive_muse_apply_dyntopo(C, ob_pub, g_wm_ios_muse_dyntopo_wanted);
      }
      wm_ios_immersive_publish_hand_menu_state(C, ob_pub);
    }
    /* Bones + timeline refresh while Anim is sticky (keep light). */
    static double last_anim_overlay = 0.0;
    if (g_wm_ios_immersive_ui_mode == 4 && now - last_anim_overlay >= 0.5) {
      last_anim_overlay = now;
      wm_ios_immersive_publish_anim_overlay(C);
    }
    static double last_shader_overlay = 0.0;
    if (g_wm_ios_shader_space && now - last_shader_overlay >= 0.45) {
      last_shader_overlay = now;
      wm_ios_immersive_publish_shader_graph(C);
    }
    return;
  }

  if (pending_dismiss) {
    GHOST_IOS_set_immersive_mode_enabled(false, nullptr);
    return;
  }

  ScrArea *area = wm_ios_immersive_find_view3d_area(C);
  ARegion *region = wm_ios_immersive_find_view3d_window_region(area);
  ScrArea *area_prev = CTX_wm_area(C);
  ARegion *region_prev = CTX_wm_region(C);
  if (area != nullptr) {
    CTX_wm_area_set(C, area);
  }
  if (region != nullptr) {
    CTX_wm_region_set(C, region);
  }

  Object *ob = CTX_data_active_object(C);
  if (pending_mode) {
    wm_ios_immersive_muse_cancel_interaction();
    g_wm_ios_muse_vpaint_erase = false;
    g_wm_ios_immersive_ui_mode = mode;
    if (mode == 4) {
      if (!wm_ios_immersive_enter_anim_pose(C, ob)) {
        fprintf(stderr, "[immersive] Anim mode: no armature found (UI stays Anim)\n");
        fflush(stderr);
        GHOST_IOS_diag_log("Anim mode: no armature (sticky)");
      }
    }
    else if (ob != nullptr && ob->type == OB_MESH) {
      const eObjectMode target = (mode == 3) ? OB_MODE_VERTEX_PAINT :
                                 (mode == 2) ? OB_MODE_SCULPT :
                                 (mode == 1) ? OB_MODE_EDIT :
                                               OB_MODE_OBJECT;
      /* DynTopo: stamp mesh flag before sculpt enter so Blender auto-enables BM session. */
      if (mode == 2 && g_wm_ios_muse_dyntopo_wanted) {
        if (Mesh *mesh = static_cast<Mesh *>(ob->data)) {
          mesh->flag |= ME_SCULPT_DYNAMIC_TOPOLOGY;
        }
      }
      blender::ed::object::mode_set(C, target);
    }
    else if (ob != nullptr && ob->type == OB_ARMATURE) {
      /* Leaving Anim back to Object, or try activate a related mesh for sculpt. */
      if (mode == 0) {
        blender::ed::object::mode_set(C, OB_MODE_OBJECT);
      }
      else if (mode == 1 || mode == 2 || mode == 3) {
        /* Leave Pose first so sticky Sculpt/Edit can stick on the mesh. */
        if (ob->mode & OB_MODE_POSE) {
          blender::ed::object::mode_set(C, OB_MODE_OBJECT);
        }
        ViewLayer *view_layer = CTX_data_view_layer(C);
        Scene *scene = CTX_data_scene(C);
        Object *mesh_ob = nullptr;
        if (scene && view_layer) {
          BKE_view_layer_synced_ensure(scene, view_layer);
          LISTBASE_FOREACH (Base *, base, BKE_view_layer_object_bases_get(view_layer)) {
            Object *cand = base->object;
            if (cand == nullptr || cand->type != OB_MESH) {
              continue;
            }
            bool related = (cand->parent == ob);
            if (!related) {
              LISTBASE_FOREACH (ModifierData *, md, &cand->modifiers) {
                if (md->type == eModifierType_Armature) {
                  ArmatureModifierData *amd = reinterpret_cast<ArmatureModifierData *>(md);
                  if (amd->object == ob) {
                    related = true;
                    break;
                  }
                }
              }
            }
            if (related) {
              blender::ed::object::base_activate(C, base);
              mesh_ob = cand;
              break;
            }
          }
        }
        if (mesh_ob != nullptr) {
          const eObjectMode target = (mode == 3) ? OB_MODE_VERTEX_PAINT :
                                     (mode == 2) ? OB_MODE_SCULPT :
                                                   OB_MODE_EDIT;
          if (mode == 2 && g_wm_ios_muse_dyntopo_wanted) {
            if (Mesh *mesh = static_cast<Mesh *>(mesh_ob->data)) {
              mesh->flag |= ME_SCULPT_DYNAMIC_TOPOLOGY;
            }
          }
          blender::ed::object::mode_set(C, target);
        }
      }
    }
    ob = CTX_data_active_object(C);
    /* Entering Sculpt / VPaint: bind brush assets (or local fallback) immediately. */
    if (mode == 2 || mode == 3) {
      const PaintMode paint_mode = (mode == 3) ? PaintMode::Vertex : PaintMode::Sculpt;
      wm_ios_ensure_paint_brush(C, paint_mode, g_wm_ios_muse_brush_kind, true);
    }
    /* Entering Sculpt from VPaint/Object must re-bind the Muse brush tool, otherwise
     * the previous Vertex Paint session can leave sculpt looking inert. */
    if (mode == 2) {
      pending_brush = true;
      brush_kind = g_wm_ios_muse_brush_kind;
      STRNCPY(brush_tool_id, wm_ios_muse_tool_id_for_kind(brush_kind));
      wm_ios_immersive_muse_apply_dyntopo(C, ob, g_wm_ios_muse_dyntopo_wanted);
    }
  }

  if (pending_dyntopo) {
    g_wm_ios_muse_dyntopo_wanted = dyntopo != 0;
    wm_ios_immersive_muse_cancel_interaction();
    wm_ios_immersive_muse_apply_dyntopo(C, CTX_data_active_object(C), g_wm_ios_muse_dyntopo_wanted);
  }

  if (pending_brush) {
    g_wm_ios_muse_brush_kind = brush_kind;
    g_wm_ios_muse_sculpt_verts.clear();
    g_wm_ios_muse_sculpt_bm_verts.clear();
    g_wm_ios_muse_sculpt_dragging = false;
    Object *ob_brush = CTX_data_active_object(C);
    if (ob_brush != nullptr && (ob_brush->mode & OB_MODE_SCULPT) != 0) {
      /* Muse Immersive deforms in 3D and does not need the toolbar tool.
       * Calling WM_toolsystem / builtin_brush.* only produced Info warnings and
       * stalled the main loop while assets linked — skip it. */
      Brush *brush = wm_ios_ensure_paint_brush(C, PaintMode::Sculpt, brush_kind, true);
      if (Scene *scene_brush = CTX_data_scene(C)) {
        if (Paint *paint = BKE_paint_get_active_from_paintmode(scene_brush, PaintMode::Sculpt)) {
          if (brush != nullptr) {
            if (brush_kind == WMIOS_MUSE_BRUSH_INFLATE_SUB) {
              brush->flag |= BRUSH_DIR_IN;
            }
            else if (brush_kind == WMIOS_MUSE_BRUSH_INFLATE_ADD) {
              brush->flag &= ~BRUSH_DIR_IN;
            }
            brush->sculpt_brush_type = wm_ios_muse_sculpt_brush_type(brush_kind);
            BKE_paint_brush_set(paint, brush);
            BKE_brush_tag_unsaved_changes(brush);
            GHOST_IOS_diag_log("brush: muse kind set (no toolsystem)");
          }
        }
      }
      (void)brush_tool_id;
    }
    else if (ob_brush != nullptr && (ob_brush->mode & OB_MODE_VERTEX_PAINT) != 0) {
      Brush *brush = wm_ios_ensure_paint_brush(C, PaintMode::Vertex, brush_kind, true);
      if (Scene *scene_brush = CTX_data_scene(C)) {
        if (Paint *paint = BKE_paint_get_active_from_paintmode(scene_brush, PaintMode::Vertex)) {
          if (brush != nullptr) {
            BKE_paint_brush_set(paint, brush);
          }
        }
      }
    }
  }

  if (pending_strength) {
    g_wm_ios_muse_strength = strength;
  }
  if (pending_radius) {
    g_wm_ios_muse_radius_m = radius;
  }

  Scene *scene = CTX_data_scene(C);
  if (scene != nullptr) {
    Object *ob_paint = CTX_data_active_object(C);
    const PaintMode paint_mode = (ob_paint && (ob_paint->mode & OB_MODE_VERTEX_PAINT)) ?
                                     PaintMode::Vertex :
                                     PaintMode::Sculpt;
    if (ob_paint != nullptr &&
        ((ob_paint->mode & OB_MODE_SCULPT) != 0 || (ob_paint->mode & OB_MODE_VERTEX_PAINT) != 0))
    {
      Brush *brush = wm_ios_ensure_paint_brush(C, paint_mode, g_wm_ios_muse_brush_kind);
      if (Paint *paint = BKE_paint_get_active_from_paintmode(scene, paint_mode)) {
        if (brush != nullptr) {
          if (pending_strength) {
            BKE_brush_alpha_set(paint, brush, strength);
          }
          if (pending_radius) {
            BKE_brush_unprojected_size_set(paint, brush, radius * 2.0f);
          }
        }
      }
    }
  }

  if (pending_remesh) {
    Object *ob_remesh = CTX_data_active_object(C);
    if (ob_remesh != nullptr && ob_remesh->type == OB_MESH) {
      Mesh *mesh = static_cast<Mesh *>(ob_remesh->data);
      if (mesh != nullptr && mesh->faces_num > 0) {
        wm_ios_immersive_muse_cancel_interaction();
        /* Edit-mode remesh must leave Edit first — otherwise USD reload's
         * EDBM_mesh_load overwrites DualCon with the old BMesh. */
        const bool was_edit = (ob_remesh->mode & OB_MODE_EDIT) != 0;
        const bool was_sculpt = (ob_remesh->mode & OB_MODE_SCULPT) != 0;
        if (was_edit) {
          blender::ed::object::mode_set(C, OB_MODE_OBJECT);
          ob_remesh = CTX_data_active_object(C);
          mesh = (ob_remesh && ob_remesh->type == OB_MESH) ?
                     static_cast<Mesh *>(ob_remesh->data) :
                     nullptr;
        }
        const bool restore_dyntopo = g_wm_ios_muse_dyntopo_wanted && was_sculpt;
        if (ob_remesh != nullptr && BKE_object_sculpt_use_dyntopo(ob_remesh)) {
          wm_ios_immersive_muse_apply_dyntopo(C, ob_remesh, false);
          mesh = static_cast<Mesh *>(ob_remesh->data);
        }
        if (mesh == nullptr || mesh->faces_num <= 0) {
          fprintf(stderr, "[immersive] remesh aborted: empty mesh\n");
          fflush(stderr);
          GHOST_IOS_diag_log("remesh: aborted empty mesh");
        }
        else {
          Mesh *new_mesh = nullptr;
          const char *method = "none";
#ifdef WITH_OPENVDB
          if (const std::optional<blender::Bounds<blender::float3>> bounds = mesh->bounds_min_max())
          {
            const float diag = len_v3v3(&bounds->min.x, &bounds->max.x);
            if (mesh->remesh_voxel_size <= 0.0f || mesh->remesh_voxel_size > diag * 0.5f) {
              mesh->remesh_voxel_size = std::clamp(diag / 48.0f, 0.008f, 0.12f);
            }
          }
          else if (mesh->remesh_voxel_size <= 0.0f) {
            mesh->remesh_voxel_size = 0.05f;
          }
          new_mesh = BKE_mesh_remesh_voxel(
              mesh, mesh->remesh_voxel_size, mesh->remesh_voxel_adaptivity, 0.0f, nullptr);
          if (new_mesh) {
            method = "voxel";
          }
#endif
#if defined(WITH_MOD_REMESH)
          if (new_mesh == nullptr) {
            new_mesh = wm_ios_immersive_dualcon_remesh(mesh);
            if (new_mesh) {
              method = "dualcon";
            }
          }
#endif
#ifdef WITH_QUADRIFLOW
          if (new_mesh == nullptr) {
            const int target = std::max(mesh->faces_num, 500);
            new_mesh = BKE_mesh_remesh_quadriflow(
                mesh, target, 1, false, true, false, nullptr, nullptr);
            if (new_mesh) {
              method = "quadriflow";
            }
          }
#endif
          if (new_mesh != nullptr) {
            blender::bke::mesh_remesh_reproject_attributes(*mesh, *new_mesh);
            BKE_mesh_nomain_to_mesh(new_mesh, mesh, ob_remesh);
            if (ob_remesh->mode == OB_MODE_SCULPT) {
              BKE_sculptsession_free_pbvh(*ob_remesh);
            }
            BKE_mesh_batch_cache_dirty_tag(mesh, BKE_MESH_BATCH_DIRTY_ALL);
            DEG_id_tag_update(&mesh->id, ID_RECALC_GEOMETRY);
            DEG_id_tag_update(&ob_remesh->id, ID_RECALC_GEOMETRY);
            WM_event_add_notifier(C, NC_GEOM | ND_DATA, mesh);
            WM_event_add_notifier(C, NC_OBJECT | ND_DRAW, ob_remesh);
            if (restore_dyntopo) {
              mesh->flag |= ME_SCULPT_DYNAMIC_TOPOLOGY;
              wm_ios_immersive_muse_apply_dyntopo(C, ob_remesh, true);
            }
            g_wm_ios_muse_geometry_dirty = true;
            ED_undo_push(C, "Muse Remesh");
            /* Force Immersive USD refresh in Object/Sculpt (not Edit) so BM load
             * cannot overwrite DualCon result. */
            wm_ios_immersive_reload_usdz(C, CTX_data_active_object(C), "remesh");
            if (was_edit) {
              blender::ed::object::mode_set(C, OB_MODE_EDIT);
            }
            char buf[96];
            SNPRINTF(buf, "remesh: OK (%s) faces=%d", method, mesh->faces_num);
            fprintf(stderr, "[immersive] %s\n", buf);
            fflush(stderr);
            GHOST_IOS_diag_log(buf);
          }
          else {
            fprintf(stderr, "[immersive] remesh FAILED (no OpenVDB/DualCon/Quadriflow result)\n");
            fflush(stderr);
            GHOST_IOS_diag_log("remesh: FAILED");
          }
        }
      }
    }
  }

  if (pending_anim_key || pending_anim_key_delete || pending_anim_play || pending_anim_stop ||
      pending_anim_frame || pending_anim_set_frame)
  {
    Scene *scene = CTX_data_scene(C);
    if (pending_anim_stop) {
      if (ED_screen_animation_playing(CTX_wm_manager(C))) {
        ED_screen_animation_play(C, 0, 0);
      }
      GHOST_IOS_diag_log("anim: stop");
    }
    if (pending_anim_play && scene != nullptr) {
      if (!ED_screen_animation_playing(CTX_wm_manager(C))) {
        ED_screen_animation_play(C, 1, 1);
      }
      GHOST_IOS_diag_log("anim: play");
    }
    if (pending_anim_set_frame && scene != nullptr) {
      BKE_scene_frame_set(scene, float(anim_set_frame));
      DEG_id_tag_update(&scene->id, ID_RECALC_FRAME_CHANGE);
      WM_event_add_notifier(C, NC_SCENE | ND_FRAME, scene);
      char buf[64];
      SNPRINTF(buf, "anim: set frame=%d", scene->r.cfra);
      GHOST_IOS_diag_log(buf);
    }
    if (pending_anim_frame && scene != nullptr) {
      const int next = scene->r.cfra + anim_frame_delta;
      BKE_scene_frame_set(scene, float(next));
      DEG_id_tag_update(&scene->id, ID_RECALC_FRAME_CHANGE);
      WM_event_add_notifier(C, NC_SCENE | ND_FRAME, scene);
      char buf[64];
      SNPRINTF(buf, "anim: frame=%d", scene->r.cfra);
      GHOST_IOS_diag_log(buf);
    }
    if (pending_anim_key) {
      PointerRNA props;
      WM_operator_properties_create(&props, "ANIM_OT_keyframe_insert_by_name");
      RNA_string_set(&props, "type", "LocRotScale");
      WM_operator_name_call(
          C, "ANIM_OT_keyframe_insert_by_name", blender::wm::OpCallContext::ExecDefault, &props, nullptr);
      WM_operator_properties_free(&props);
      ED_undo_push(C, "Immersive Insert Key");
      GHOST_IOS_diag_log("anim: keyframe LocRotScale");
      g_wm_ios_muse_geometry_dirty = true;
    }
    if (pending_anim_key_delete) {
      PointerRNA props;
      WM_operator_properties_create(&props, "ANIM_OT_keyframe_delete_by_name");
      RNA_string_set(&props, "type", "LocRotScale");
      WM_operator_name_call(
          C, "ANIM_OT_keyframe_delete_by_name", blender::wm::OpCallContext::ExecDefault, &props, nullptr);
      WM_operator_properties_free(&props);
      ED_undo_push(C, "Immersive Delete Key");
      GHOST_IOS_diag_log("anim: delete keyframe LocRotScale");
      g_wm_ios_muse_geometry_dirty = true;
    }
    if (pending_camera_key) {
      float view_mat[4][4];
      bool have_pose = false;
      {
        std::lock_guard lock(g_wm_ios_viewer_pose.mutex);
        if (g_wm_ios_viewer_pose.valid) {
          copy_m4_m4(view_mat, g_wm_ios_viewer_pose.mat);
          have_pose = true;
        }
      }
      if (!have_pose) {
        GHOST_IOS_diag_log("anim: camera key skipped (no viewer pose)");
      }
      else if (scene != nullptr) {
        Main *bmain = CTX_data_main(C);
        ViewLayer *view_layer = CTX_data_view_layer(C);
        Object *cam = scene->camera;
        if (cam == nullptr || cam->type != OB_CAMERA) {
          cam = BKE_object_add(bmain, scene, view_layer, OB_CAMERA, "ImmersiveCam");
          scene->camera = cam;
        }
        /* Leave pose/sculpt so LocRotScale keys land on the camera object. */
        Object *prev = CTX_data_active_object(C);
        if (prev != nullptr &&
            (prev->mode & (OB_MODE_POSE | OB_MODE_EDIT | OB_MODE_SCULPT | OB_MODE_VERTEX_PAINT |
                           OB_MODE_WEIGHT_PAINT | OB_MODE_TEXTURE_PAINT)))
        {
          blender::ed::object::mode_set(C, OB_MODE_OBJECT);
        }
        BKE_object_apply_mat4(cam, view_mat, true, true);
        DEG_id_tag_update(&cam->id, ID_RECALC_TRANSFORM);
        if (Base *base = BKE_view_layer_base_find(view_layer, cam)) {
          blender::ed::object::base_activate(C, base);
        }
        PointerRNA props;
        WM_operator_properties_create(&props, "ANIM_OT_keyframe_insert_by_name");
        RNA_string_set(&props, "type", "LocRotScale");
        WM_operator_name_call(C,
                              "ANIM_OT_keyframe_insert_by_name",
                              blender::wm::OpCallContext::ExecDefault,
                              &props,
                              nullptr);
        WM_operator_properties_free(&props);
        ED_undo_push(C, "Immersive Camera Key from Viewer");
        GHOST_IOS_diag_log("anim: camera key from viewer pose");
        g_wm_ios_muse_geometry_dirty = true;
        /* Keep Anim sticky UI even though we briefly entered Object for the camera. */
        g_wm_ios_immersive_ui_mode = 4;
      }
    }
  }

  CTX_wm_area_set(C, area_prev);
  CTX_wm_region_set(C, region_prev);

  wm_ios_immersive_publish_hand_menu_state(C, CTX_data_active_object(C));
  wm_ios_immersive_publish_anim_overlay(C);
}

/**
 * DynTopo path: deform the sculpt BMesh, refine topology near the tip, sync to Mesh.
 * Grab skips topology refine (same as desktop).
 */

/** Brush radius in object space (meters) for Immersive Muse / hand sculpt. */
static float wm_ios_immersive_muse_brush_radius_object(bContext *C)
{
  float radius = std::clamp(g_wm_ios_muse_radius_m, 0.02f, 1.5f);
  if (Scene *scene = CTX_data_scene(C)) {
    if (Paint *paint = BKE_paint_get_active_from_paintmode(scene, PaintMode::Sculpt)) {
      if (Brush *brush = BKE_paint_brush(paint)) {
        const float unprojected = BKE_brush_unprojected_radius_get(paint, brush);
        if (unprojected > 0.02f && unprojected < 1.5f && g_wm_ios_muse_radius_m <= 0.26f &&
            g_wm_ios_muse_radius_m >= 0.24f)
        {
          radius = unprojected;
        }
      }
    }
  }
  return radius;
}

/** Distance from muse/hand tip to the nearest mesh vertex (object space, meters). */
static float wm_ios_immersive_muse_nearest_vert_dist_object(Object *ob,
                                                            const float muse_world[3])
{
  if (ob == nullptr || ob->type != OB_MESH) {
    return FLT_MAX;
  }

  float muse_local[3];
  mul_v3_m4v3(muse_local, ob->world_to_object().ptr(), muse_world);

  if (BKE_object_sculpt_use_dyntopo(ob)) {
    SculptSession *ss = ob->sculpt;
    BMesh *bm = (ss != nullptr) ? ss->bm : nullptr;
    if (bm == nullptr) {
      return FLT_MAX;
    }
    float nearest_dist_sq = FLT_MAX;
    BMVert *v;
    BMIter iter;
    BM_ITER_MESH (v, &iter, bm, BM_VERTS_OF_MESH) {
      const float dist_sq = len_squared_v3v3(v->co, muse_local);
      if (dist_sq < nearest_dist_sq) {
        nearest_dist_sq = dist_sq;
      }
    }
    return (nearest_dist_sq < FLT_MAX) ? sqrtf(nearest_dist_sq) : FLT_MAX;
  }

  Mesh *mesh = static_cast<Mesh *>(ob->data);
  if (mesh == nullptr || mesh->verts_num <= 0) {
    return FLT_MAX;
  }
  const blender::Span<blender::float3> positions = mesh->vert_positions();
  float nearest_dist_sq = FLT_MAX;
  for (int i = 0; i < int(positions.size()); i++) {
    const float dist_sq = len_squared_v3v3(&positions[i].x, muse_local);
    if (dist_sq < nearest_dist_sq) {
      nearest_dist_sq = dist_sq;
    }
  }
  return (nearest_dist_sq < FLT_MAX) ? sqrtf(nearest_dist_sq) : FLT_MAX;
}

/**
 * Hand proximity sculpt: only engage when the nearest vertex is within brush radius.
 * \a r_pressure_scale: smooth 0 (brush edge) .. 1 (on/near surface).
 */
static bool wm_ios_immersive_muse_proximity_gate(Object *ob,
                                                 bContext *C,
                                                 const float muse_world[3],
                                                 float *r_pressure_scale)
{
  if (r_pressure_scale != nullptr) {
    *r_pressure_scale = 0.0f;
  }
  const float radius = wm_ios_immersive_muse_brush_radius_object(C);
  const float nearest = wm_ios_immersive_muse_nearest_vert_dist_object(ob, muse_world);
  if (nearest > radius || nearest == FLT_MAX) {
    return false;
  }
  if (r_pressure_scale != nullptr) {
    const float t = 1.0f - std::clamp(nearest / radius, 0.0f, 1.0f);
    *r_pressure_scale = t * t * (3.0f - 2.0f * t);
  }
  return true;
}

static void wm_ios_immersive_muse_sculpt_grab_dyntopo(bContext *C,
                                                     Object *ob,
                                                     const float muse_world[3],
                                                     const bool tip_down,
                                                     const float pressure)
{
  SculptSession *ss = ob->sculpt;
  BMesh *bm = (ss != nullptr) ? ss->bm : nullptr;
  if (bm == nullptr) {
    return;
  }

  float muse_local[3];
  mul_v3_m4v3(muse_local, ob->world_to_object().ptr(), muse_world);

  if (!tip_down) {
    if (g_wm_ios_muse_sculpt_dragging) {
      g_wm_ios_muse_sculpt_dragging = false;
      g_wm_ios_muse_stroke_active = false;
      g_wm_ios_muse_sculpt_bm_verts.clear();
      BKE_sculptsession_bm_to_me(ob);
      Mesh *mesh = static_cast<Mesh *>(ob->data);
      if (mesh != nullptr) {
        mesh->tag_positions_changed();
        DEG_id_tag_update(&mesh->id, ID_RECALC_GEOMETRY);
      }
      DEG_id_tag_update(&ob->id, ID_RECALC_GEOMETRY);
      WM_event_add_notifier(C, NC_OBJECT | ND_DRAW, ob);
      ED_undo_push(C, "Muse Sculpt DynTopo");
    }
    return;
  }

  float radius = std::clamp(g_wm_ios_muse_radius_m, 0.02f, 1.5f);
  float brush_strength = std::clamp(g_wm_ios_muse_strength, 0.05f, 1.0f);
  const float tip_force = std::clamp(pressure, 0.0f, 1.0f);
  constexpr float k_muse_sculpt_power = 0.1f;
  const float strength = std::max(tip_force, 0.25f) * std::max(brush_strength, 0.5f) *
                         k_muse_sculpt_power;

  BMVert *v;
  BMIter iter;
  float nearest_dist = FLT_MAX;
  BM_ITER_MESH (v, &iter, bm, BM_VERTS_OF_MESH) {
    const float dist_sq = len_squared_v3v3(v->co, muse_local);
    if (dist_sq < nearest_dist) {
      nearest_dist = dist_sq;
    }
  }
  nearest_dist = (nearest_dist < FLT_MAX) ? sqrtf(nearest_dist) : FLT_MAX;
  if (!g_wm_ios_hand_proximity_sculpt) {
    if (nearest_dist > radius && nearest_dist < std::max(radius * 8.0f, 1.2f)) {
      radius = nearest_dist * 1.35f;
    }
    if (nearest_dist > radius) {
      radius = std::max(nearest_dist * 1.1f, 0.05f);
    }
  }
  else if (nearest_dist > radius) {
    if (g_wm_ios_muse_sculpt_dragging) {
      g_wm_ios_muse_sculpt_dragging = false;
      g_wm_ios_muse_stroke_active = false;
      g_wm_ios_muse_sculpt_bm_verts.clear();
      BKE_sculptsession_bm_to_me(ob);
      Mesh *mesh = static_cast<Mesh *>(ob->data);
      if (mesh != nullptr) {
        mesh->tag_positions_changed();
        DEG_id_tag_update(&mesh->id, ID_RECALC_GEOMETRY);
      }
      DEG_id_tag_update(&ob->id, ID_RECALC_GEOMETRY);
      WM_event_add_notifier(C, NC_OBJECT | ND_DRAW, ob);
      ED_undo_push(C, "Muse Sculpt DynTopo");
    }
    return;
  }
  const float radius_sq = radius * radius;

  const bool is_grab = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_GRAB);
  const bool is_inflate = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_INFLATE_ADD ||
                           g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_INFLATE_SUB);
  const bool is_smooth = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_SMOOTH);

  if (!g_wm_ios_muse_sculpt_dragging) {
    copy_v3_v3(g_wm_ios_muse_sculpt_last_local, muse_local);
    g_wm_ios_muse_sculpt_dragging = true;
    g_wm_ios_muse_stroke_active = true;
    if (is_grab) {
      g_wm_ios_muse_sculpt_bm_verts.clear();
      g_wm_ios_muse_sculpt_bm_verts.reserve(256);
      BM_ITER_MESH (v, &iter, bm, BM_VERTS_OF_MESH) {
        const float dist_sq = len_squared_v3v3(v->co, muse_local);
        if (dist_sq > radius_sq) {
          continue;
        }
        const float t = 1.0f - (sqrtf(dist_sq) / radius);
        const float w = t * t * (3.0f - 2.0f * t) * strength;
        g_wm_ios_muse_sculpt_bm_verts.push_back({v, w});
      }
      if (g_wm_ios_muse_sculpt_bm_verts.empty()) {
        g_wm_ios_muse_sculpt_dragging = false;
        g_wm_ios_muse_stroke_active = false;
      }
      return;
    }
  }

  float delta[3];
  sub_v3_v3v3(delta, muse_local, g_wm_ios_muse_sculpt_last_local);
  copy_v3_v3(g_wm_ios_muse_sculpt_last_local, muse_local);

  bool any = false;
  int hit_count = 0;

  if (is_grab) {
    if (len_squared_v3(delta) < 1e-12f) {
      return;
    }
    for (const WMIOSMuseSculptBMVert &entry : g_wm_ios_muse_sculpt_bm_verts) {
      if (entry.v == nullptr) {
        continue;
      }
      madd_v3_v3fl(entry.v->co, delta, entry.weight);
      any = true;
      hit_count++;
    }
  }
  else if (is_smooth) {
    std::vector<blender::float3> src;
    src.reserve(size_t(bm->totvert));
    BM_ITER_MESH (v, &iter, bm, BM_VERTS_OF_MESH) {
      src.push_back(blender::float3(v->co));
      BM_elem_index_set(v, int(src.size()) - 1);
    }
    bm->elem_index_dirty &= ~BM_VERT;
    std::vector<blender::float3> neighbor_sum(src.size(), blender::float3(0.0f));
    std::vector<int> neighbor_count(src.size(), 0);
    BMEdge *e;
    BM_ITER_MESH (e, &iter, bm, BM_EDGES_OF_MESH) {
      const int i0 = BM_elem_index_get(e->v1);
      const int i1 = BM_elem_index_get(e->v2);
      if (i0 < 0 || i1 < 0 || i0 >= int(src.size()) || i1 >= int(src.size())) {
        continue;
      }
      neighbor_sum[size_t(i0)] += src[size_t(i1)];
      neighbor_sum[size_t(i1)] += src[size_t(i0)];
      neighbor_count[size_t(i0)]++;
      neighbor_count[size_t(i1)]++;
    }
    const float base_blend = 0.10f * strength;
    BM_ITER_MESH (v, &iter, bm, BM_VERTS_OF_MESH) {
      const int i = BM_elem_index_get(v);
      if (i < 0 || i >= int(src.size()) || neighbor_count[size_t(i)] <= 0) {
        continue;
      }
      const float dist_sq = len_squared_v3v3(&src[size_t(i)].x, muse_local);
      if (dist_sq > radius_sq) {
        continue;
      }
      const float t = 1.0f - (sqrtf(dist_sq) / radius);
      const float falloff = t * t * (3.0f - 2.0f * t);
      const float blend = std::clamp(base_blend * falloff, 0.0f, 0.35f);
      const blender::float3 target = neighbor_sum[size_t(i)] / float(neighbor_count[size_t(i)]);
      const blender::float3 out = src[size_t(i)] + (target - src[size_t(i)]) * blend;
      copy_v3_v3(v->co, &out.x);
      any = true;
      hit_count++;
    }
  }
  else if (is_inflate) {
    BM_mesh_normals_update(bm);
    const float dir = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_INFLATE_SUB) ? -1.0f : 1.0f;
    const float amount = strength * radius * 0.55f * dir;
    BM_ITER_MESH (v, &iter, bm, BM_VERTS_OF_MESH) {
      const float dist_sq = len_squared_v3v3(v->co, muse_local);
      if (dist_sq > radius_sq) {
        continue;
      }
      const float t = 1.0f - (sqrtf(dist_sq) / radius);
      const float w = t * t * (3.0f - 2.0f * t) * amount;
      madd_v3_v3fl(v->co, v->no, w);
      any = true;
      hit_count++;
    }
  }
  else {
    BM_mesh_normals_update(bm);
    const float clay_scale = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_CLAY) ? 1.25f : 1.0f;
    const float drag_scale = clay_scale * strength;
    const float pressure_push = strength * radius * 0.35f;
    const bool has_delta = len_squared_v3(delta) >= 1e-12f;
    BM_ITER_MESH (v, &iter, bm, BM_VERTS_OF_MESH) {
      const float dist_sq = len_squared_v3v3(v->co, muse_local);
      if (dist_sq > radius_sq) {
        continue;
      }
      const float t = 1.0f - (sqrtf(dist_sq) / radius);
      const float falloff = t * t * (3.0f - 2.0f * t);
      if (has_delta) {
        madd_v3_v3fl(v->co, delta, falloff * drag_scale);
      }
      madd_v3_v3fl(v->co, v->no, falloff * pressure_push);
      any = true;
      hit_count++;
    }
  }

  if (!any) {
    return;
  }

  /* Topology refine (not for Grab / Smooth — matches desktop DynTopo brush rules). */
  if (!is_grab && !is_smooth && ss->bm_log != nullptr) {
    if (Depsgraph *depsgraph = CTX_data_ensure_evaluated_depsgraph(C)) {
      BKE_sculpt_update_object_for_edit(depsgraph, ob, true);
      if (blender::bke::pbvh::Tree *pbvh = blender::bke::object::pbvh_get(*ob)) {
        float max_edge = std::clamp(radius * 0.35f, 0.002f, 0.08f);
        if (Scene *scene = CTX_data_scene(C)) {
          if (Sculpt *sd = scene->toolsettings ? scene->toolsettings->sculpt : nullptr) {
            if (sd->flags & (SCULPT_DYNTOPO_DETAIL_CONSTANT | SCULPT_DYNTOPO_DETAIL_MANUAL)) {
              if (sd->constant_detail > 1e-6f) {
                max_edge = std::clamp(1.0f / sd->constant_detail, 0.001f, 0.15f);
              }
            }
            else if (sd->flags & SCULPT_DYNTOPO_DETAIL_BRUSH) {
              max_edge = std::clamp(radius * (sd->detail_percent * 0.01f), 0.001f, 0.15f);
            }
            else if (sd->detail_size > 0.0f) {
              max_edge = std::clamp(radius * (sd->detail_size * 0.01f), 0.001f, 0.15f);
            }
          }
        }
        const float min_edge = max_edge * 0.4f;
        const PBVHTopologyUpdateMode topo_mode = PBVH_Subdivide | PBVH_Collapse;
        blender::bke::pbvh::bmesh_update_topology(*bm,
                                                  *pbvh,
                                                  *ss->bm_log,
                                                  topo_mode,
                                                  min_edge,
                                                  max_edge,
                                                  blender::float3(muse_local),
                                                  std::nullopt,
                                                  radius,
                                                  false,
                                                  false);
      }
    }
  }

  BKE_sculptsession_bm_to_me(ob);
  g_wm_ios_muse_geometry_dirty = true;
  if (Mesh *mesh = static_cast<Mesh *>(ob->data)) {
    mesh->tag_positions_changed();
    DEG_id_tag_update(&mesh->id, ID_RECALC_GEOMETRY);
  }
  DEG_id_tag_update(&ob->id, ID_RECALC_GEOMETRY);
  WM_event_add_notifier(C, NC_GEOM | ND_DATA, ob->data);

  {
    static double last_log = 0.0;
    const double now = BLI_time_now_seconds();
    if (now - last_log > 0.75) {
      last_log = now;
      fprintf(stderr,
              "[immersive] dyntopo deform kind=%d hits=%d near=%.3f r=%.3f p=%.2f\n",
              g_wm_ios_muse_brush_kind,
              hit_count,
              nearest_dist,
              radius,
              tip_force);
      fflush(stderr);
      GHOST_IOS_diag_log("sculpt dyntopo deform");
    }
  }
}

/**
 * Sculpt Mode: continuous soft deform along the Muse tip.
 * Brush kind (hand menu): Draw/Clay = tip follow, Grab = locked cluster,
 * Smooth = Laplacian relax toward edge neighbors (not brush centroid). Pressure × Strength every frame.
 *
 * Robustness notes:
 * - Prefer hand-menu radius/strength (brush assets may be missing / wrong scale).
 * - If tip misses the mesh, expand radius to the nearest vertex so strokes "catch".
 * - Inflate/Smooth apply on the first tip-down frame (no early return) so noisy tip
 *   pressure cannot skip deformation forever.
 */
static void wm_ios_immersive_muse_sculpt_grab(bContext *C,
                                              Object *ob,
                                              const float muse_world[3],
                                              const bool tip_down,
                                              const float pressure)
{
  if (ob == nullptr || ob->type != OB_MESH || (ob->mode & OB_MODE_SCULPT) == 0) {
    if (g_wm_ios_muse_sculpt_dragging) {
      g_wm_ios_muse_sculpt_dragging = false;
      g_wm_ios_muse_sculpt_verts.clear();
      g_wm_ios_muse_sculpt_bm_verts.clear();
      g_wm_ios_muse_stroke_active = false;
    }
    return;
  }

  /* Keep Paint.brush non-null even if essentials never loaded — but never on the
   * hot path every frame (asset linking stalls Muse samples). */
  if (!g_wm_ios_paint_brush_ok) {
    static double last_ensure = 0.0;
    const double now_ensure = BLI_time_now_seconds();
    if (now_ensure - last_ensure > 1.0) {
      last_ensure = now_ensure;
      wm_ios_ensure_paint_brush(C, PaintMode::Sculpt, g_wm_ios_muse_brush_kind);
    }
  }

  /* DynTopo wanted but not yet active — enable once before deform. */
  if (g_wm_ios_muse_dyntopo_wanted && !BKE_object_sculpt_use_dyntopo(ob)) {
    static double last_dyntopo_try = 0.0;
    const double now_dt = BLI_time_now_seconds();
    if (now_dt - last_dyntopo_try > 0.5) {
      last_dyntopo_try = now_dt;
      wm_ios_immersive_muse_apply_dyntopo(C, ob, true);
    }
  }

  if (BKE_object_sculpt_use_dyntopo(ob)) {
    wm_ios_immersive_muse_sculpt_grab_dyntopo(C, ob, muse_world, tip_down, pressure);
    return;
  }

  Mesh *mesh = static_cast<Mesh *>(ob->data);
  if (mesh == nullptr || mesh->verts_num <= 0) {
    return;
  }

  float muse_local[3];
  mul_v3_m4v3(muse_local, ob->world_to_object().ptr(), muse_world);

  if (!tip_down) {
    if (g_wm_ios_muse_sculpt_dragging) {
      g_wm_ios_muse_sculpt_dragging = false;
      g_wm_ios_muse_stroke_active = false;
      g_wm_ios_muse_sculpt_verts.clear();
      g_wm_ios_muse_sculpt_bm_verts.clear();
      BKE_sculptsession_free_pbvh(*ob);
      mesh->tag_positions_changed();
      DEG_id_tag_update(&mesh->id, ID_RECALC_GEOMETRY);
      DEG_id_tag_update(&ob->id, ID_RECALC_GEOMETRY);
      WM_event_add_notifier(C, NC_OBJECT | ND_DRAW, ob);
      ED_undo_push(C, "Muse Sculpt");
    }
    return;
  }

  /* Hand-menu radius is authoritative for Immersive Muse. Brush unprojected size
   * is only a fallback when the menu has never been touched. */
  float radius = std::clamp(g_wm_ios_muse_radius_m, 0.02f, 1.5f);
  float brush_strength = std::clamp(g_wm_ios_muse_strength, 0.05f, 1.0f);
  if (Scene *scene = CTX_data_scene(C)) {
    if (Paint *paint = BKE_paint_get_active_from_paintmode(scene, PaintMode::Sculpt)) {
      if (Brush *brush = BKE_paint_brush(paint)) {
        const float unprojected = BKE_brush_unprojected_radius_get(paint, brush);
        /* Ignore absurd brush sizes (often means assets failed / wrong units). */
        if (unprojected > 0.02f && unprojected < 1.5f && g_wm_ios_muse_radius_m <= 0.26f &&
            g_wm_ios_muse_radius_m >= 0.24f)
        {
          /* Still on default menu radius — allow brush to refine once. */
          radius = unprojected;
        }
        const float alpha = BKE_brush_alpha_get(paint, brush);
        if (alpha > 0.05f && alpha <= 1.0f && g_wm_ios_muse_strength <= 0.51f &&
            g_wm_ios_muse_strength >= 0.49f)
        {
          brush_strength = alpha;
        }
      }
    }
  }

  const float tip_force = std::clamp(pressure, 0.0f, 1.0f);
  /* Pressure alone must move verts — do not let a low brush alpha kill the stroke.
   * Global Immersive power is intentionally mild (~1/10 desktop sculpt feel). */
  constexpr float k_muse_sculpt_power = 0.1f;
  const float strength = std::max(tip_force, 0.25f) * std::max(brush_strength, 0.5f) *
                         k_muse_sculpt_power;

  /* Snap / expand radius to nearest vertex when tip is near but outside brush. */
  const blender::Span<blender::float3> positions_read = mesh->vert_positions();
  float nearest_dist = FLT_MAX;
  int nearest_i = -1;
  for (int i = 0; i < int(positions_read.size()); i++) {
    const float dist_sq = len_squared_v3v3(&positions_read[i].x, muse_local);
    if (dist_sq < nearest_dist) {
      nearest_dist = dist_sq;
      nearest_i = i;
    }
  }
  nearest_dist = (nearest_i >= 0) ? sqrtf(nearest_dist) : FLT_MAX;
  if (!g_wm_ios_hand_proximity_sculpt) {
    /* Generous catch radius — Immersive tip/mesh scale often mismatches. */
    if (nearest_i >= 0 && nearest_dist > radius && nearest_dist < std::max(radius * 8.0f, 1.2f)) {
      radius = nearest_dist * 1.35f;
    }
    /* If still far, pin radius to nearest so a tip press always affects something. */
    if (nearest_i >= 0 && nearest_dist > radius) {
      radius = std::max(nearest_dist * 1.1f, 0.05f);
    }
  }
  else if (nearest_dist > radius) {
    if (g_wm_ios_muse_sculpt_dragging) {
      g_wm_ios_muse_sculpt_dragging = false;
      g_wm_ios_muse_stroke_active = false;
      g_wm_ios_muse_sculpt_verts.clear();
      g_wm_ios_muse_sculpt_bm_verts.clear();
      BKE_sculptsession_free_pbvh(*ob);
      mesh->tag_positions_changed();
      DEG_id_tag_update(&mesh->id, ID_RECALC_GEOMETRY);
      DEG_id_tag_update(&ob->id, ID_RECALC_GEOMETRY);
      WM_event_add_notifier(C, NC_OBJECT | ND_DRAW, ob);
      ED_undo_push(C, "Muse Sculpt");
    }
    return;
  }

  const float radius_sq = radius * radius;
  const bool is_grab = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_GRAB);
  const bool is_inflate = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_INFLATE_ADD ||
                           g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_INFLATE_SUB);
  const bool is_smooth = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_SMOOTH);

  if (!g_wm_ios_muse_sculpt_dragging) {
    copy_v3_v3(g_wm_ios_muse_sculpt_last_local, muse_local);
    g_wm_ios_muse_sculpt_dragging = true;
    g_wm_ios_muse_stroke_active = true;
    if (ob->sculpt != nullptr) {
      BKE_sculptsession_free_pbvh(*ob);
    }
    if (is_grab) {
      blender::MutableSpan<blender::float3> positions = mesh->vert_positions_for_write();
      g_wm_ios_muse_sculpt_verts.clear();
      g_wm_ios_muse_sculpt_verts.reserve(256);
      for (int i = 0; i < int(positions.size()); i++) {
        const float dist_sq = len_squared_v3v3(&positions[i].x, muse_local);
        if (dist_sq > radius_sq) {
          continue;
        }
        const float t = 1.0f - (sqrtf(dist_sq) / radius);
        const float w = t * t * (3.0f - 2.0f * t) * strength;
        g_wm_ios_muse_sculpt_verts.push_back({i, w});
      }
      if (g_wm_ios_muse_sculpt_verts.empty()) {
        g_wm_ios_muse_sculpt_dragging = false;
        g_wm_ios_muse_stroke_active = false;
      }
      {
        static double last_log = 0.0;
        const double now = BLI_time_now_seconds();
        if (now - last_log > 0.5) {
          last_log = now;
          fprintf(stderr,
                  "[immersive] sculpt grab start hits=%zu nearest=%.3f radius=%.3f "
                  "tip=(%.3f,%.3f,%.3f)\n",
                  g_wm_ios_muse_sculpt_verts.size(),
                  nearest_dist,
                  radius,
                  muse_local[0],
                  muse_local[1],
                  muse_local[2]);
          fflush(stderr);
        }
      }
      return;
    }
    /* Inflate / Smooth / Draw: fall through and deform on this same frame. */
  }

  float delta[3];
  sub_v3_v3v3(delta, muse_local, g_wm_ios_muse_sculpt_last_local);
  copy_v3_v3(g_wm_ios_muse_sculpt_last_local, muse_local);

  blender::MutableSpan<blender::float3> positions = mesh->vert_positions_for_write();
  bool any = false;
  int hit_count = 0;

  if (is_grab) {
    if (len_squared_v3(delta) < 1e-12f) {
      return;
    }
    for (const WMIOSMuseSculptVert &entry : g_wm_ios_muse_sculpt_verts) {
      madd_v3_v3fl(&positions[entry.index].x, delta, entry.weight);
      any = true;
      hit_count++;
    }
  }
  else if (is_smooth) {
    /* True Laplacian relax toward edge-neighbors — NOT brush-region centroid
     * (centroid collapse looks like shrink/deflate). */
    const blender::Span<blender::int2> edges = mesh->edges();
    std::vector<blender::float3> src(positions.begin(), positions.end());
    std::vector<blender::float3> neighbor_sum(size_t(src.size()), blender::float3(0.0f));
    std::vector<int> neighbor_count(size_t(src.size()), 0);
    for (const blender::int2 &e : edges) {
      if (e[0] < 0 || e[1] < 0 || e[0] >= int(src.size()) || e[1] >= int(src.size())) {
        continue;
      }
      neighbor_sum[size_t(e[0])] += src[size_t(e[1])];
      neighbor_sum[size_t(e[1])] += src[size_t(e[0])];
      neighbor_count[size_t(e[0])]++;
      neighbor_count[size_t(e[1])]++;
    }
    /* Mild per-frame factor (~90 Hz). Old 0.45*strength → centroid shrank fast. */
    const float base_blend = 0.10f * strength;
    for (int i = 0; i < int(src.size()); i++) {
      if (neighbor_count[size_t(i)] <= 0) {
        continue;
      }
      const float dist_sq = len_squared_v3v3(&src[size_t(i)].x, muse_local);
      if (dist_sq > radius_sq) {
        continue;
      }
      const float t = 1.0f - (sqrtf(dist_sq) / radius);
      const float falloff = t * t * (3.0f - 2.0f * t);
      const float blend = std::clamp(base_blend * falloff, 0.0f, 0.35f);
      const blender::float3 target = neighbor_sum[size_t(i)] /
                                     float(neighbor_count[size_t(i)]);
      positions[i] = src[size_t(i)] + (target - src[size_t(i)]) * blend;
      any = true;
      hit_count++;
    }
  }
  else if (is_inflate) {
    /* Snapshot normals before mutating positions. */
    const blender::Span<blender::float3> normals_span = mesh->vert_normals();
    std::vector<blender::float3> normals(normals_span.begin(), normals_span.end());
    const float dir = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_INFLATE_SUB) ? -1.0f : 1.0f;
    /* Pressure-driven displace — must be visible at ~90 Hz Immersive refresh. */
    const float amount = strength * radius * 0.55f * dir;
    for (int i = 0; i < int(positions.size()); i++) {
      const float dist_sq = len_squared_v3v3(&positions[i].x, muse_local);
      if (dist_sq > radius_sq) {
        continue;
      }
      const float t = 1.0f - (sqrtf(dist_sq) / radius);
      const float w = t * t * (3.0f - 2.0f * t) * amount;
      madd_v3_v3fl(&positions[i].x, &normals[i].x, w);
      any = true;
      hit_count++;
    }
  }
  else {
    /* Draw / Clay: tip-follow + pressure normal push (stationary tip still deforms). */
    const blender::Span<blender::float3> normals_span = mesh->vert_normals();
    std::vector<blender::float3> normals(normals_span.begin(), normals_span.end());
    const float clay_scale = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_CLAY) ? 1.25f : 1.0f;
    const float drag_scale = clay_scale * strength;
    const float pressure_push = strength * radius * 0.35f;
    const bool has_delta = len_squared_v3(delta) >= 1e-12f;
    for (int i = 0; i < int(positions.size()); i++) {
      const float dist_sq = len_squared_v3v3(&positions[i].x, muse_local);
      if (dist_sq > radius_sq) {
        continue;
      }
      const float t = 1.0f - (sqrtf(dist_sq) / radius);
      const float falloff = t * t * (3.0f - 2.0f * t);
      if (has_delta) {
        madd_v3_v3fl(&positions[i].x, delta, falloff * drag_scale);
      }
      /* Pen pressure moves verts along normals even when the tip is still. */
      madd_v3_v3fl(&positions[i].x, &normals[i].x, falloff * pressure_push);
      any = true;
      hit_count++;
    }
  }

  {
    static double last_log = 0.0;
    const double now = BLI_time_now_seconds();
    if (now - last_log > 0.75) {
      last_log = now;
      fprintf(stderr,
              "[immersive] sculpt deform kind=%d hits=%d nearest=%.3f radius=%.3f "
              "p=%.2f strength=%.2f any=%d\n",
              g_wm_ios_muse_brush_kind,
              hit_count,
              nearest_dist,
              radius,
              tip_force,
              strength,
              int(any));
      fflush(stderr);
      char buf[192];
      SNPRINTF(buf,
               "sculpt kind=%d hits=%d near=%.2f r=%.2f p=%.2f",
               g_wm_ios_muse_brush_kind,
               hit_count,
               nearest_dist,
               radius,
               tip_force);
      GHOST_IOS_diag_log(buf);
    }
  }

  if (!any) {
    return;
  }

  g_wm_ios_muse_geometry_dirty = true;
  mesh->tag_positions_changed();
  /* Keep sculpt PBVH from reusing stale positions mid-stroke. */
  if (ob->sculpt != nullptr) {
    BKE_sculptsession_free_pbvh(*ob);
  }
  DEG_id_tag_update(&mesh->id, ID_RECALC_GEOMETRY);
  DEG_id_tag_update(&ob->id, ID_RECALC_GEOMETRY);
  WM_event_add_notifier(C, NC_GEOM | ND_DATA, mesh);
}

#if 0 /* obsolete duplicate sculpt_grab body — disabled */
static void wm_ios_immersive_muse_sculpt_grab_OLD_DISABLED(bContext *C,
                                              Object *ob,
                                              const float muse_world[3],
                                              const bool tip_down,
                                              const float pressure)
{
  if (ob == nullptr || ob->type != OB_MESH || (ob->mode & OB_MODE_SCULPT) == 0) {
    if (g_wm_ios_muse_sculpt_dragging) {
      g_wm_ios_muse_sculpt_dragging = false;
      g_wm_ios_muse_sculpt_verts.clear();
      g_wm_ios_muse_stroke_active = false;
    }
    return;
  }

  /* Keep Paint.brush non-null even if essentials never loaded — but never on the
   * hot path every frame (asset linking stalls Muse samples). */
  if (!g_wm_ios_paint_brush_ok) {
    static double last_ensure = 0.0;
    const double now_ensure = BLI_time_now_seconds();
    if (now_ensure - last_ensure > 1.0) {
      last_ensure = now_ensure;
      wm_ios_ensure_paint_brush(C, PaintMode::Sculpt, g_wm_ios_muse_brush_kind);
    }
  }

  Mesh *mesh = static_cast<Mesh *>(ob->data);
  if (mesh == nullptr || mesh->verts_num <= 0) {
    return;
  }

  float muse_local[3];
  mul_v3_m4v3(muse_local, ob->world_to_object().ptr(), muse_world);

  if (!tip_down) {
    if (g_wm_ios_muse_sculpt_dragging) {
      g_wm_ios_muse_sculpt_dragging = false;
      g_wm_ios_muse_stroke_active = false;
      g_wm_ios_muse_sculpt_verts.clear();
      BKE_sculptsession_free_pbvh(*ob);
      mesh->tag_positions_changed();
      DEG_id_tag_update(&mesh->id, ID_RECALC_GEOMETRY);
      DEG_id_tag_update(&ob->id, ID_RECALC_GEOMETRY);
      WM_event_add_notifier(C, NC_OBJECT | ND_DRAW, ob);
      ED_undo_push(C, "Muse Sculpt");
    }
    return;
  }

  /* Hand-menu radius is authoritative for Immersive Muse. Brush unprojected size
   * is only a fallback when the menu has never been touched. */
  float radius = std::clamp(g_wm_ios_muse_radius_m, 0.02f, 1.5f);
  float brush_strength = std::clamp(g_wm_ios_muse_strength, 0.05f, 1.0f);
  if (Scene *scene = CTX_data_scene(C)) {
    if (Paint *paint = BKE_paint_get_active_from_paintmode(scene, PaintMode::Sculpt)) {
      if (Brush *brush = BKE_paint_brush(paint)) {
        const float unprojected = BKE_brush_unprojected_radius_get(paint, brush);
        /* Ignore absurd brush sizes (often means assets failed / wrong units). */
        if (unprojected > 0.02f && unprojected < 1.5f && g_wm_ios_muse_radius_m <= 0.26f &&
            g_wm_ios_muse_radius_m >= 0.24f)
        {
          /* Still on default menu radius — allow brush to refine once. */
          radius = unprojected;
        }
        const float alpha = BKE_brush_alpha_get(paint, brush);
        if (alpha > 0.05f && alpha <= 1.0f && g_wm_ios_muse_strength <= 0.51f &&
            g_wm_ios_muse_strength >= 0.49f)
        {
          brush_strength = alpha;
        }
      }
    }
  }

  const float tip_force = std::clamp(pressure, 0.0f, 1.0f);
  /* Pressure alone must move verts — do not let a low brush alpha kill the stroke.
   * Global Immersive power is intentionally mild (~1/10 desktop sculpt feel). */
  constexpr float k_muse_sculpt_power = 0.1f;
  const float strength = std::max(tip_force, 0.25f) * std::max(brush_strength, 0.5f) *
                         k_muse_sculpt_power;

  /* Snap / expand radius to nearest vertex when tip is near but outside brush. */
  const blender::Span<blender::float3> positions_read = mesh->vert_positions();
  float nearest_dist = FLT_MAX;
  int nearest_i = -1;
  for (int i = 0; i < int(positions_read.size()); i++) {
    const float dist_sq = len_squared_v3v3(&positions_read[i].x, muse_local);
    if (dist_sq < nearest_dist) {
      nearest_dist = dist_sq;
      nearest_i = i;
    }
  }
  nearest_dist = (nearest_i >= 0) ? sqrtf(nearest_dist) : FLT_MAX;
  /* Generous catch radius — Immersive tip/mesh scale often mismatches. */
  if (nearest_i >= 0 && nearest_dist > radius && nearest_dist < std::max(radius * 8.0f, 1.2f)) {
    radius = nearest_dist * 1.35f;
  }
  /* If still far, pin radius to nearest so a tip press always affects something. */
  if (nearest_i >= 0 && nearest_dist > radius) {
    radius = std::max(nearest_dist * 1.1f, 0.05f);
  }

  const float radius_sq = radius * radius;
  const bool is_grab = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_GRAB);
  const bool is_inflate = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_INFLATE_ADD ||
                           g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_INFLATE_SUB);
  const bool is_smooth = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_SMOOTH);

  if (!g_wm_ios_muse_sculpt_dragging) {
    copy_v3_v3(g_wm_ios_muse_sculpt_last_local, muse_local);
    g_wm_ios_muse_sculpt_dragging = true;
    g_wm_ios_muse_stroke_active = true;
    if (ob->sculpt != nullptr) {
      BKE_sculptsession_free_pbvh(*ob);
    }
    if (is_grab) {
      blender::MutableSpan<blender::float3> positions = mesh->vert_positions_for_write();
      g_wm_ios_muse_sculpt_verts.clear();
      g_wm_ios_muse_sculpt_verts.reserve(256);
      for (int i = 0; i < int(positions.size()); i++) {
        const float dist_sq = len_squared_v3v3(&positions[i].x, muse_local);
        if (dist_sq > radius_sq) {
          continue;
        }
        const float t = 1.0f - (sqrtf(dist_sq) / radius);
        const float w = t * t * (3.0f - 2.0f * t) * strength;
        g_wm_ios_muse_sculpt_verts.push_back({i, w});
      }
      if (g_wm_ios_muse_sculpt_verts.empty()) {
        g_wm_ios_muse_sculpt_dragging = false;
        g_wm_ios_muse_stroke_active = false;
      }
      {
        static double last_log = 0.0;
        const double now = BLI_time_now_seconds();
        if (now - last_log > 0.5) {
          last_log = now;
          fprintf(stderr,
                  "[immersive] sculpt grab start hits=%zu nearest=%.3f radius=%.3f "
                  "tip=(%.3f,%.3f,%.3f)\n",
                  g_wm_ios_muse_sculpt_verts.size(),
                  nearest_dist,
                  radius,
                  muse_local[0],
                  muse_local[1],
                  muse_local[2]);
          fflush(stderr);
        }
      }
      return;
    }
    /* Inflate / Smooth / Draw: fall through and deform on this same frame. */
  }

  float delta[3];
  sub_v3_v3v3(delta, muse_local, g_wm_ios_muse_sculpt_last_local);
  copy_v3_v3(g_wm_ios_muse_sculpt_last_local, muse_local);

  blender::MutableSpan<blender::float3> positions = mesh->vert_positions_for_write();
  bool any = false;
  int hit_count = 0;

  if (is_grab) {
    if (len_squared_v3(delta) < 1e-12f) {
      return;
    }
    for (const WMIOSMuseSculptVert &entry : g_wm_ios_muse_sculpt_verts) {
      madd_v3_v3fl(&positions[entry.index].x, delta, entry.weight);
      any = true;
      hit_count++;
    }
  }
  else if (is_smooth) {
    /* True Laplacian relax toward edge-neighbors — NOT brush-region centroid
     * (centroid collapse looks like shrink/deflate). */
    const blender::Span<blender::int2> edges = mesh->edges();
    std::vector<blender::float3> src(positions.begin(), positions.end());
    std::vector<blender::float3> neighbor_sum(size_t(src.size()), blender::float3(0.0f));
    std::vector<int> neighbor_count(size_t(src.size()), 0);
    for (const blender::int2 &e : edges) {
      if (e[0] < 0 || e[1] < 0 || e[0] >= int(src.size()) || e[1] >= int(src.size())) {
        continue;
      }
      neighbor_sum[size_t(e[0])] += src[size_t(e[1])];
      neighbor_sum[size_t(e[1])] += src[size_t(e[0])];
      neighbor_count[size_t(e[0])]++;
      neighbor_count[size_t(e[1])]++;
    }
    /* Mild per-frame factor (~90 Hz). Old 0.45*strength → centroid shrank fast. */
    const float base_blend = 0.10f * strength;
    for (int i = 0; i < int(src.size()); i++) {
      if (neighbor_count[size_t(i)] <= 0) {
        continue;
      }
      const float dist_sq = len_squared_v3v3(&src[size_t(i)].x, muse_local);
      if (dist_sq > radius_sq) {
        continue;
      }
      const float t = 1.0f - (sqrtf(dist_sq) / radius);
      const float falloff = t * t * (3.0f - 2.0f * t);
      const float blend = std::clamp(base_blend * falloff, 0.0f, 0.35f);
      const blender::float3 target = neighbor_sum[size_t(i)] /
                                     float(neighbor_count[size_t(i)]);
      positions[i] = src[size_t(i)] + (target - src[size_t(i)]) * blend;
      any = true;
      hit_count++;
    }
  }
  else if (is_inflate) {
    /* Snapshot normals before mutating positions. */
    const blender::Span<blender::float3> normals_span = mesh->vert_normals();
    std::vector<blender::float3> normals(normals_span.begin(), normals_span.end());
    const float dir = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_INFLATE_SUB) ? -1.0f : 1.0f;
    /* Pressure-driven displace — must be visible at ~90 Hz Immersive refresh. */
    const float amount = strength * radius * 0.55f * dir;
    for (int i = 0; i < int(positions.size()); i++) {
      const float dist_sq = len_squared_v3v3(&positions[i].x, muse_local);
      if (dist_sq > radius_sq) {
        continue;
      }
      const float t = 1.0f - (sqrtf(dist_sq) / radius);
      const float w = t * t * (3.0f - 2.0f * t) * amount;
      madd_v3_v3fl(&positions[i].x, &normals[i].x, w);
      any = true;
      hit_count++;
    }
  }
  else {
    /* Draw / Clay: tip-follow + pressure normal push (stationary tip still deforms). */
    const blender::Span<blender::float3> normals_span = mesh->vert_normals();
    std::vector<blender::float3> normals(normals_span.begin(), normals_span.end());
    const float clay_scale = (g_wm_ios_muse_brush_kind == WMIOS_MUSE_BRUSH_CLAY) ? 1.25f : 1.0f;
    const float drag_scale = clay_scale * strength;
    const float pressure_push = strength * radius * 0.35f;
    const bool has_delta = len_squared_v3(delta) >= 1e-12f;
    for (int i = 0; i < int(positions.size()); i++) {
      const float dist_sq = len_squared_v3v3(&positions[i].x, muse_local);
      if (dist_sq > radius_sq) {
        continue;
      }
      const float t = 1.0f - (sqrtf(dist_sq) / radius);
      const float falloff = t * t * (3.0f - 2.0f * t);
      if (has_delta) {
        madd_v3_v3fl(&positions[i].x, delta, falloff * drag_scale);
      }
      /* Pen pressure moves verts along normals even when the tip is still. */
      madd_v3_v3fl(&positions[i].x, &normals[i].x, falloff * pressure_push);
      any = true;
      hit_count++;
    }
  }

  {
    static double last_log = 0.0;
    const double now = BLI_time_now_seconds();
    if (now - last_log > 0.75) {
      last_log = now;
      fprintf(stderr,
              "[immersive] sculpt deform kind=%d hits=%d nearest=%.3f radius=%.3f "
              "p=%.2f strength=%.2f any=%d\n",
              g_wm_ios_muse_brush_kind,
              hit_count,
              nearest_dist,
              radius,
              tip_force,
              strength,
              int(any));
      fflush(stderr);
      char buf[192];
      SNPRINTF(buf,
               "sculpt kind=%d hits=%d near=%.2f r=%.2f p=%.2f",
               g_wm_ios_muse_brush_kind,
               hit_count,
               nearest_dist,
               radius,
               tip_force);
      GHOST_IOS_diag_log(buf);
    }
  }

  if (!any) {
    return;
  }

  g_wm_ios_muse_geometry_dirty = true;
  mesh->tag_positions_changed();
  /* Keep sculpt PBVH from reusing stale positions mid-stroke. */
  if (ob->sculpt != nullptr) {
    BKE_sculptsession_free_pbvh(*ob);
  }
  DEG_id_tag_update(&mesh->id, ID_RECALC_GEOMETRY);
  DEG_id_tag_update(&ob->id, ID_RECALC_GEOMETRY);
  WM_event_add_notifier(C, NC_GEOM | ND_DATA, mesh);
}
#endif /* obsolete duplicate sculpt_grab body */

/**
 * Edit Mode: move selected vertices by Muse tip delta in object space.
 * If nothing is selected, pick the nearest vertex on tip-down.
 */
static void wm_ios_immersive_muse_edit_verts(bContext *C,
                                             Object *ob,
                                             const float muse_world[3],
                                             const bool tip_down)
{
  if (ob == nullptr || ob->type != OB_MESH || (ob->mode & OB_MODE_EDIT) == 0) {
    if (g_wm_ios_muse_edit_dragging) {
      g_wm_ios_muse_edit_dragging = false;
      g_wm_ios_muse_stroke_active = false;
    }
    return;
  }

  BMEditMesh *em = BKE_editmesh_from_object(ob);
  if (em == nullptr || em->bm == nullptr) {
    if (g_wm_ios_muse_edit_dragging) {
      g_wm_ios_muse_edit_dragging = false;
      g_wm_ios_muse_stroke_active = false;
    }
    return;
  }

  float muse_local[3];
  mul_v3_m4v3(muse_local, ob->world_to_object().ptr(), muse_world);

  if (!tip_down) {
    if (g_wm_ios_muse_edit_dragging) {
      g_wm_ios_muse_edit_dragging = false;
      g_wm_ios_muse_stroke_active = false;
      ED_undo_push(C, "Muse Vertex Move");
    }
    return;
  }

  BMesh *bm = em->bm;
  if (!g_wm_ios_muse_edit_dragging) {
    /* Prefer existing selection; otherwise grab nearest vert to the tip. */
    int selected = 0;
    BMVert *v;
    BMIter iter;
    BM_ITER_MESH (v, &iter, bm, BM_VERTS_OF_MESH) {
      if (!BM_elem_flag_test(v, BM_ELEM_HIDDEN) && BM_elem_flag_test(v, BM_ELEM_SELECT)) {
        selected++;
      }
    }
    if (selected == 0) {
      BMVert *nearest = nullptr;
      float best_dist_sq = FLT_MAX;
      BM_ITER_MESH (v, &iter, bm, BM_VERTS_OF_MESH) {
        if (BM_elem_flag_test(v, BM_ELEM_HIDDEN)) {
          continue;
        }
        const float dist_sq = len_squared_v3v3(v->co, muse_local);
        if (dist_sq < best_dist_sq) {
          best_dist_sq = dist_sq;
          nearest = v;
        }
      }
      if (nearest == nullptr) {
        return;
      }
      BM_ITER_MESH (v, &iter, bm, BM_VERTS_OF_MESH) {
        BM_elem_flag_disable(v, BM_ELEM_SELECT);
      }
      BM_elem_flag_enable(nearest, BM_ELEM_SELECT);
      bm->selectmode = SCE_SELECT_VERTEX;
      EDBM_selectmode_flush(em);
    }

    copy_v3_v3(g_wm_ios_muse_edit_last_local, muse_local);
    g_wm_ios_muse_edit_dragging = true;
    g_wm_ios_muse_stroke_active = true;
    return;
  }

  float delta[3];
  sub_v3_v3v3(delta, muse_local, g_wm_ios_muse_edit_last_local);
  if (len_squared_v3(delta) < 1e-12f) {
    return;
  }
  copy_v3_v3(g_wm_ios_muse_edit_last_local, muse_local);

  BMVert *v;
  BMIter iter;
  BM_ITER_MESH (v, &iter, bm, BM_VERTS_OF_MESH) {
    if (BM_elem_flag_test(v, BM_ELEM_SELECT) && !BM_elem_flag_test(v, BM_ELEM_HIDDEN)) {
      add_v3_v3(v->co, delta);
    }
  }

  Mesh *mesh = static_cast<Mesh *>(ob->data);
  const EDBMUpdate_Params update_params = {
      .calc_looptris = true,
      .calc_normals = true,
      .is_destructive = false,
  };
  EDBM_update(mesh, &update_params);
  g_wm_ios_muse_geometry_dirty = true;
  DEG_id_tag_update(&mesh->id, ID_RECALC_GEOMETRY);
  WM_event_add_notifier(C, NC_GEOM | ND_DATA, mesh);
}

/**
 * Vertex Paint: blend brush color onto Point-domain Color attribute near Muse tip.
 */
static void wm_ios_immersive_muse_vertex_paint(bContext *C,
                                               Object *ob,
                                               const float muse_world[3],
                                               const bool tip_down,
                                               const float pressure)
{
  using namespace blender;

  if (ob == nullptr || ob->type != OB_MESH || (ob->mode & OB_MODE_VERTEX_PAINT) == 0) {
    if (g_wm_ios_muse_vpaint_dragging) {
      g_wm_ios_muse_vpaint_dragging = false;
      g_wm_ios_muse_stroke_active = false;
    }
    return;
  }

  Mesh *mesh = static_cast<Mesh *>(ob->data);
  if (mesh == nullptr || mesh->verts_num <= 0) {
    return;
  }

  if (!tip_down) {
    if (g_wm_ios_muse_vpaint_dragging) {
      g_wm_ios_muse_vpaint_dragging = false;
      g_wm_ios_muse_stroke_active = false;
      DEG_id_tag_update(&mesh->id, ID_RECALC_GEOMETRY);
      WM_event_add_notifier(C, NC_OBJECT | ND_DRAW, ob);
      ED_undo_push(C, "Muse Vertex Paint");
    }
    return;
  }

  float radius = 0.25f;
  float brush_strength = 1.0f;
  float paint_rgb[3] = {1.0f, 0.2f, 0.1f};
  if (Scene *scene = CTX_data_scene(C)) {
    if (Paint *paint = BKE_paint_get_active_from_paintmode(scene, PaintMode::Vertex)) {
      if (Brush *brush = BKE_paint_brush(paint)) {
        const float unprojected = BKE_brush_unprojected_radius_get(paint, brush);
        if (unprojected > 1.0e-4f) {
          radius = unprojected;
        }
        brush_strength = BKE_brush_alpha_get(paint, brush);
        if (const float *col = BKE_brush_color_get(paint, brush)) {
          copy_v3_v3(paint_rgb, col);
        }
      }
    }
  }

  bke::MutableAttributeAccessor attributes = mesh->attributes_for_write();
  /* Prefer a Point-domain float Color attribute for Muse painting. */
  bool need_create = true;
  if (mesh->active_color_attribute != nullptr && mesh->active_color_attribute[0] != '\0') {
    if (std::optional<bke::AttributeMetaData> meta = attributes.lookup_meta_data(
            mesh->active_color_attribute))
    {
      if (meta->domain == bke::AttrDomain::Point && meta->data_type == bke::AttrType::ColorFloat)
      {
        need_create = false;
      }
    }
  }
  if (need_create) {
    if (attributes.contains("Color")) {
      if (std::optional<bke::AttributeMetaData> meta = attributes.lookup_meta_data("Color")) {
        if (meta->domain != bke::AttrDomain::Point || meta->data_type != bke::AttrType::ColorFloat)
        {
          attributes.remove("Color");
        }
      }
    }
    if (!attributes.contains("Color")) {
      attributes.add<ColorGeometry4f>(
          "Color", bke::AttrDomain::Point, bke::AttributeInitDefaultValue());
    }
    BKE_id_attributes_active_color_set(&mesh->id, "Color");
  }

  const StringRef color_name = BKE_id_attributes_active_color_name(&mesh->id).value_or("Color");
  bke::SpanAttributeWriter<ColorGeometry4f> colors =
      attributes.lookup_or_add_for_write_span<ColorGeometry4f>(color_name, bke::AttrDomain::Point);
  if (!colors) {
    return;
  }

  const float tip_force = std::clamp(pressure, 0.0f, 1.0f);
  const float strength = std::max(tip_force, 0.05f) * std::max(brush_strength, 0.01f);
  float muse_local[3];
  mul_v3_m4v3(muse_local, ob->world_to_object().ptr(), muse_world);
  const float radius_sq = radius * radius;
  const Span<float3> positions = mesh->vert_positions();
  const ColorGeometry4f target = g_wm_ios_muse_vpaint_erase ?
                                     ColorGeometry4f(1.0f, 1.0f, 1.0f, 1.0f) :
                                     ColorGeometry4f(paint_rgb[0], paint_rgb[1], paint_rgb[2], 1.0f);

  bool any = false;
  for (const int i : positions.index_range()) {
    const float dist_sq = len_squared_v3v3(&positions[i].x, muse_local);
    if (dist_sq > radius_sq) {
      continue;
    }
    const float t = 1.0f - (sqrtf(dist_sq) / radius);
    const float fac = t * t * (3.0f - 2.0f * t) * strength;
    colors.span[i] = bke::attribute_math::mix2(fac, colors.span[i], target);
    any = true;
  }
  colors.finish();

  if (!any) {
    return;
  }

  if (!g_wm_ios_muse_vpaint_dragging) {
    g_wm_ios_muse_vpaint_dragging = true;
    g_wm_ios_muse_stroke_active = true;
  }

  g_wm_ios_muse_geometry_dirty = true;
  DEG_id_tag_update(&mesh->id, ID_RECALC_GEOMETRY);
  WM_event_add_notifier(C, NC_OBJECT | ND_DRAW, ob);
}

/**
 * Immersive Anim: pinch-grab nearest object origin and translate in world space.
 */
static void wm_ios_immersive_muse_object_grab(bContext *C,
                                              const float muse_world[3],
                                              const bool tip_down)
{
  if (!tip_down) {
    if (g_wm_ios_obj_grab_dragging) {
      Object *moved = g_wm_ios_obj_grab_ob;
      g_wm_ios_obj_grab_dragging = false;
      g_wm_ios_obj_grab_ob = nullptr;
      g_wm_ios_muse_stroke_active = false;
      if (moved != nullptr) {
        DEG_id_tag_update(&moved->id, ID_RECALC_TRANSFORM);
        WM_event_add_notifier(C, NC_OBJECT | ND_TRANSFORM, moved);
        ED_undo_push(C, "Immersive Object Move");
        g_wm_ios_muse_geometry_dirty = true;
      }
    }
    return;
  }

  const float grab_radius = std::max(g_wm_ios_muse_radius_m, 0.15f);
  const float grab_radius_sq = grab_radius * grab_radius;

  if (!g_wm_ios_obj_grab_dragging) {
    Scene *scene = CTX_data_scene(C);
    ViewLayer *view_layer = CTX_data_view_layer(C);
    if (scene == nullptr || view_layer == nullptr) {
      return;
    }
    BKE_view_layer_synced_ensure(scene, view_layer);

    Object *nearest = nullptr;
    float nearest_dist_sq = FLT_MAX;
    LISTBASE_FOREACH (Base *, base, BKE_view_layer_object_bases_get(view_layer)) {
      if (base == nullptr || base->object == nullptr) {
        continue;
      }
      if ((base->flag & BASE_ENABLED_AND_MAYBE_VISIBLE_IN_VIEWPORT) == 0) {
        continue;
      }
      Object *cand = base->object;
      /* Prefer movable scene objects. */
      if (!ELEM(cand->type,
                OB_MESH,
                OB_ARMATURE,
                OB_EMPTY,
                OB_CURVES_LEGACY,
                OB_SURF,
                OB_FONT,
                OB_MBALL,
                OB_LATTICE,
                OB_GREASE_PENCIL,
                OB_CURVES,
                OB_POINTCLOUD,
                OB_VOLUME))
      {
        continue;
      }
      float origin[3];
      copy_v3_v3(origin, cand->object_to_world().location());
      const float d = len_squared_v3v3(muse_world, origin);
      /* Selected objects get a soft priority (half distance). */
      const float score = (base->flag & BASE_SELECTED) ? d * 0.5f : d;
      if (score < nearest_dist_sq) {
        nearest_dist_sq = score;
        nearest = cand;
      }
    }
    if (nearest == nullptr || nearest_dist_sq > grab_radius_sq) {
      return;
    }
    g_wm_ios_obj_grab_ob = nearest;
    copy_v3_v3(g_wm_ios_obj_grab_last_world, muse_world);
    g_wm_ios_obj_grab_dragging = true;
    g_wm_ios_muse_stroke_active = true;
    return;
  }

  Object *ob = g_wm_ios_obj_grab_ob;
  if (ob == nullptr) {
    return;
  }

  float delta_world[3];
  sub_v3_v3v3(delta_world, muse_world, g_wm_ios_obj_grab_last_world);
  if (len_squared_v3(delta_world) < 1e-12f) {
    return;
  }

  /* Apply as Blender-world translation via full matrix so parent/rotation
   * cannot remap Immersive up (world Z) onto loc.y. */
  float mat[4][4];
  copy_m4_m4(mat, ob->object_to_world().ptr());
  add_v3_v3(mat[3], delta_world);
  BKE_object_apply_mat4(ob, mat, true, true);
  copy_v3_v3(g_wm_ios_obj_grab_last_world, muse_world);

  DEG_id_tag_update(&ob->id, ID_RECALC_TRANSFORM);
  WM_event_add_notifier(C, NC_OBJECT | ND_TRANSFORM, ob);
  g_wm_ios_muse_geometry_dirty = true;
}

/**
 * Immersive Pose/Anim: pinch-grab nearest bone.
 * Default = rotate; Move/Scale selected from hand menu.
 */
static void wm_ios_immersive_muse_pose_grab(bContext *C,
                                            Object *ob,
                                            const float muse_world[3],
                                            const bool tip_down)
{
  if (ob == nullptr || ob->type != OB_ARMATURE || (ob->mode & OB_MODE_POSE) == 0 ||
      ob->pose == nullptr)
  {
    if (g_wm_ios_pose_dragging) {
      g_wm_ios_pose_dragging = false;
      g_wm_ios_pose_pchan = nullptr;
      g_wm_ios_pose_arm_ob = nullptr;
      g_wm_ios_muse_stroke_active = false;
    }
    return;
  }

  if (!tip_down) {
    if (g_wm_ios_pose_dragging) {
      g_wm_ios_pose_dragging = false;
      g_wm_ios_pose_pchan = nullptr;
      g_wm_ios_pose_arm_ob = nullptr;
      g_wm_ios_muse_stroke_active = false;
      DEG_id_tag_update(&ob->id, ID_RECALC_GEOMETRY);
      WM_event_add_notifier(C, NC_OBJECT | ND_POSE, ob);
      ED_undo_push(C, "Immersive Pose Edit");
      g_wm_ios_muse_geometry_dirty = true;
    }
    return;
  }

  const float grab_radius = std::max(g_wm_ios_muse_radius_m, 0.08f);
  const float grab_radius_sq = grab_radius * grab_radius;

  if (!g_wm_ios_pose_dragging) {
    bPoseChannel *nearest = nullptr;
    float nearest_dist_sq = FLT_MAX;
    float nearest_mid[3] = {0.0f, 0.0f, 0.0f};
    bArmature *arm = static_cast<bArmature *>(ob->data);
    LISTBASE_FOREACH (bPoseChannel *, pchan, &ob->pose->chanbase) {
      if (pchan->bone == nullptr || arm == nullptr ||
          !blender::animrig::bone_is_visible(arm, pchan))
      {
        continue;
      }
      float head_world[3], mid_world[3], tail_world[3];
      mul_v3_m4v3(head_world, ob->object_to_world().ptr(), pchan->pose_head);
      mul_v3_m4v3(tail_world, ob->object_to_world().ptr(), pchan->pose_tail);
      mid_v3_v3v3(mid_world, head_world, tail_world);
      const float d0 = len_squared_v3v3(muse_world, head_world);
      const float d1 = len_squared_v3v3(muse_world, mid_world);
      const float d2 = len_squared_v3v3(muse_world, tail_world);
      const float d = std::min(d0, std::min(d1, d2));
      if (d < nearest_dist_sq) {
        nearest_dist_sq = d;
        nearest = pchan;
        copy_v3_v3(nearest_mid, mid_world);
      }
    }
    if (nearest == nullptr || nearest_dist_sq > grab_radius_sq) {
      return;
    }
    g_wm_ios_pose_pchan = nearest;
    g_wm_ios_pose_arm_ob = ob;
    copy_v3_v3(g_wm_ios_pose_last_world, muse_world);
    copy_v3_v3(g_wm_ios_pose_grab_mid_world, nearest_mid);
    g_wm_ios_pose_dragging = true;
    g_wm_ios_muse_stroke_active = true;
    LISTBASE_FOREACH (bPoseChannel *, pchan, &ob->pose->chanbase) {
      if (pchan->bone) {
        pchan->bone->flag &= ~BONE_SELECTED;
      }
    }
    if (nearest->bone) {
      nearest->bone->flag |= BONE_SELECTED;
    }
    return;
  }

  if (g_wm_ios_pose_pchan == nullptr || g_wm_ios_pose_arm_ob != ob) {
    return;
  }

  bPoseChannel *pchan = g_wm_ios_pose_pchan;
  float delta_world[3];
  sub_v3_v3v3(delta_world, muse_world, g_wm_ios_pose_last_world);
  if (len_squared_v3(delta_world) < 1e-12f) {
    return;
  }

  const int xform = g_wm_ios_pose_xform_mode;
  if (xform == WMIOS_POSE_XFORM_MOVE) {
    /* muse_world is Blender world (Z-up). pchan->loc is bone-local, NOT object
     * space — adding world_to_object(delta) directly made Immersive up (world Z)
     * land on bone local Z, which for upright bones reads as world Y in the
     * 2D viewport. Convert via pose location → bone loc like View3D snap. */
    float pose_loc[3];
    copy_v3_v3(pose_loc, pchan->pose_mat[3]);
    float delta_obj[3];
    copy_v3_v3(delta_obj, delta_world);
    mul_mat3_m4_v3(ob->world_to_object().ptr(), delta_obj);
    add_v3_v3(pose_loc, delta_obj);
    float bone_loc[3];
    BKE_armature_loc_pose_to_bone(pchan, pose_loc, bone_loc);
    copy_v3_v3(pchan->loc, bone_loc);
  }
  else if (xform == WMIOS_POSE_XFORM_SCALE) {
    const float d0 = len_v3v3(g_wm_ios_pose_last_world, g_wm_ios_pose_grab_mid_world);
    const float d1 = len_v3v3(muse_world, g_wm_ios_pose_grab_mid_world);
    if (d0 > 1.0e-4f) {
      float s = d1 / d0;
      s = std::clamp(s, 0.92f, 1.08f);
      pchan->scale[0] = std::clamp(pchan->scale[0] * s, 0.05f, 10.0f);
      pchan->scale[1] = std::clamp(pchan->scale[1] * s, 0.05f, 10.0f);
      pchan->scale[2] = std::clamp(pchan->scale[2] * s, 0.05f, 10.0f);
    }
  }
  else {
    /* Rotate (default): orbit hand around bone mid-point. */
    float v_prev[3], v_cur[3], axis_world[3];
    sub_v3_v3v3(v_prev, g_wm_ios_pose_last_world, g_wm_ios_pose_grab_mid_world);
    sub_v3_v3v3(v_cur, muse_world, g_wm_ios_pose_grab_mid_world);
    if (normalize_v3(v_prev) < 1.0e-5f || normalize_v3(v_cur) < 1.0e-5f) {
      copy_v3_v3(g_wm_ios_pose_last_world, muse_world);
      return;
    }
    cross_v3_v3v3(axis_world, v_prev, v_cur);
    const float angle = angle_normalized_v3v3(v_prev, v_cur);
    if (len_squared_v3(axis_world) < 1.0e-10f || fabsf(angle) < 1.0e-5f) {
      copy_v3_v3(g_wm_ios_pose_last_world, muse_world);
      return;
    }
    normalize_v3(axis_world);
    /* World → object → bone-local (pose_mat 3x3 maps bone-local → pose/object). */
    float axis_obj[3];
    copy_v3_v3(axis_obj, axis_world);
    mul_mat3_m4_v3(ob->world_to_object().ptr(), axis_obj);
    float rmat[3][3];
    copy_m3_m4(rmat, pchan->pose_mat);
    /* Orthogonal inverse = transpose. */
    transpose_m3(rmat);
    float axis_bone[3];
    mul_v3_m3v3(axis_bone, rmat, axis_obj);
    if (normalize_v3(axis_bone) < 1.0e-5f) {
      copy_v3_v3(g_wm_ios_pose_last_world, muse_world);
      return;
    }

    float qdelta[4];
    axis_angle_normalized_to_quat(qdelta, axis_bone, angle);

    if (pchan->rotmode > 0) {
      float quat[4];
      eulO_to_quat(quat, pchan->eul, pchan->rotmode);
      mul_qt_qtqt(quat, qdelta, quat);
      quat_to_eulO(pchan->eul, pchan->rotmode, quat);
    }
    else if (pchan->rotmode == ROT_MODE_AXISANGLE) {
      float quat[4];
      axis_angle_to_quat(quat, pchan->rotAxis, pchan->rotAngle);
      mul_qt_qtqt(quat, qdelta, quat);
      quat_to_axis_angle(pchan->rotAxis, &pchan->rotAngle, quat);
    }
    else {
      mul_qt_qtqt(pchan->quat, qdelta, pchan->quat);
      normalize_qt(pchan->quat);
    }
  }

  copy_v3_v3(g_wm_ios_pose_last_world, muse_world);

  BKE_pose_where_is(CTX_data_ensure_evaluated_depsgraph(C), CTX_data_scene(C), ob);
  {
    float head_world[3], tail_world[3];
    mul_v3_m4v3(head_world, ob->object_to_world().ptr(), pchan->pose_head);
    mul_v3_m4v3(tail_world, ob->object_to_world().ptr(), pchan->pose_tail);
    mid_v3_v3v3(g_wm_ios_pose_grab_mid_world, head_world, tail_world);
  }

  DEG_id_tag_update(&ob->id, ID_RECALC_GEOMETRY);
  WM_event_add_notifier(C, NC_OBJECT | ND_POSE, ob);
  g_wm_ios_muse_geometry_dirty = true;
}

/**
 * Project Muse Blender-space position into the active View3D and inject
 * GHOST tablet cursor/button events so SCULPT_OT_brush_stroke can run.
 * In Edit Mode, move selected vertices by Muse tip delta instead.
 */
static void wm_ios_immersive_consume_muse(bContext *C, Object *ob)
{
  float sample_x = 0.0f;
  float sample_y = 0.0f;
  float sample_z = 0.0f;
  float pressure = 0.0f;
  int tip_pressed = 0;
  bool has_sample = false;
  {
    std::lock_guard lock(g_wm_ios_immersive_muse_sample.mutex);
    if (g_wm_ios_immersive_muse_sample.pending) {
      sample_x = g_wm_ios_immersive_muse_sample.x;
      sample_y = g_wm_ios_immersive_muse_sample.y;
      sample_z = g_wm_ios_immersive_muse_sample.z;
      pressure = g_wm_ios_immersive_muse_sample.pressure;
      tip_pressed = g_wm_ios_immersive_muse_sample.tip_pressed;
      g_wm_ios_immersive_muse_sample.pending = false;
      has_sample = true;
    }
  }
  if (!has_sample) {
    return;
  }

  const bool tip_down = tip_pressed != 0;
  if (g_wm_ios_muse_tip_down && !tip_down) {
    g_wm_ios_muse_tip_just_released = true;
  }
  g_wm_ios_muse_tip_down = tip_down;

  wmWindow *win = CTX_wm_window(C);
  if (win == nullptr) {
    return;
  }

  ScrArea *area = wm_ios_immersive_find_view3d_area(C);
  ARegion *region = wm_ios_immersive_find_view3d_window_region(area);
  if (region == nullptr) {
    if (g_wm_ios_muse_stroke_active) {
      wm_ios_immersive_muse_end_stroke(0, 0, 0.0f);
    }
    wm_ios_immersive_muse_cancel_interaction();
    return;
  }

  ScrArea *area_prev = CTX_wm_area(C);
  ARegion *region_prev = CTX_wm_region(C);
  if (area != nullptr) {
    CTX_wm_area_set(C, area);
  }
  CTX_wm_region_set(C, region);

  /* Object Mode = Immersive view-only. Do NOT auto-enter Sculpt on tip press;
   * the hand menu / N-panel must switch to Edit / Sculpt / VPaint explicitly. */
  const bool sculpt_mode = (ob != nullptr) && (ob->mode & OB_MODE_SCULPT);
  const bool edit_mode = (ob != nullptr) && (ob->mode & OB_MODE_EDIT) && (ob->type == OB_MESH);
  const bool vpaint_mode = (ob != nullptr) && (ob->mode & OB_MODE_VERTEX_PAINT) &&
                           (ob->type == OB_MESH);
  const bool pose_mode = (ob != nullptr) && (ob->mode & OB_MODE_POSE) && (ob->type == OB_ARMATURE);
  const bool anim_ui = (g_wm_ios_immersive_ui_mode == 4);
  const int mode_now = pose_mode   ? 4 :
                       vpaint_mode ? 3 :
                       (sculpt_mode ? 2 : (edit_mode ? 1 : 0));
  if (mode_now != g_wm_ios_muse_last_mode) {
    /* Mode switch mid-stroke races USD reload and leaves broken drag state. */
    wm_ios_immersive_muse_cancel_interaction();
    g_wm_ios_muse_last_mode = mode_now;
  }

  if (!sculpt_mode && !edit_mode && !vpaint_mode && !pose_mode && !anim_ui) {
    CTX_wm_area_set(C, area_prev);
    CTX_wm_region_set(C, region_prev);
    if (g_wm_ios_muse_stroke_active) {
      wm_ios_immersive_muse_end_stroke(0, 0, 0.0f);
    }
    wm_ios_immersive_muse_cancel_interaction();
    return;
  }

  const float co[3] = {sample_x, sample_y, sample_z};

  bool effective_tip_down = tip_down;
  float effective_pressure = pressure;
  if (g_wm_ios_hand_proximity_sculpt && sculpt_mode) {
    float prox_scale = 0.0f;
    effective_tip_down = wm_ios_immersive_muse_proximity_gate(ob, C, co, &prox_scale);
    effective_pressure = std::max(pressure, 0.15f) * prox_scale;
  }

  /* Exclusive: never run edit/sculpt/vpaint/pose grabs in the same frame. */
  if (pose_mode || anim_ui) {
    g_wm_ios_muse_edit_dragging = false;
    g_wm_ios_muse_sculpt_dragging = false;
    g_wm_ios_muse_vpaint_dragging = false;
    if (g_wm_ios_anim_target == WMIOS_ANIM_TARGET_OBJECT) {
      if (g_wm_ios_pose_dragging) {
        g_wm_ios_pose_dragging = false;
        g_wm_ios_pose_pchan = nullptr;
        g_wm_ios_pose_arm_ob = nullptr;
      }
      wm_ios_immersive_muse_object_grab(C, co, tip_down);
    }
    else {
      if (g_wm_ios_obj_grab_dragging) {
        g_wm_ios_obj_grab_dragging = false;
        g_wm_ios_obj_grab_ob = nullptr;
      }
      Object *arm_ob = ob;
      if (arm_ob == nullptr || arm_ob->type != OB_ARMATURE || (arm_ob->mode & OB_MODE_POSE) == 0) {
        arm_ob = wm_ios_immersive_find_armature(C, ob);
      }
      wm_ios_immersive_muse_pose_grab(C, arm_ob, co, tip_down);
    }
  }
  else if (edit_mode) {
    g_wm_ios_muse_sculpt_dragging = false;
    g_wm_ios_muse_vpaint_dragging = false;
    g_wm_ios_pose_dragging = false;
    g_wm_ios_obj_grab_dragging = false;
    wm_ios_immersive_muse_edit_verts(C, ob, co, tip_down);
  }
  else if (sculpt_mode) {
    g_wm_ios_muse_edit_dragging = false;
    g_wm_ios_muse_vpaint_dragging = false;
    g_wm_ios_pose_dragging = false;
    g_wm_ios_obj_grab_dragging = false;
    wm_ios_immersive_muse_sculpt_grab(C, ob, co, effective_tip_down, effective_pressure);
  }
  else if (vpaint_mode) {
    g_wm_ios_muse_edit_dragging = false;
    g_wm_ios_muse_sculpt_dragging = false;
    g_wm_ios_obj_grab_dragging = false;
    wm_ios_immersive_muse_vertex_paint(C, ob, co, tip_down, pressure);
  }

  CTX_wm_area_set(C, area_prev);
  CTX_wm_region_set(C, region_prev);

  /* Do not require CLIP_WIN/BB: Immersive Muse points often project outside the
   * 2D View3D. #ED_view3d_project_float_global only writes r_co on OK, so a
   * strict clip left mval uninitialized and blocked all injection. */
  float mval[2] = {0.0f, 0.0f};
  const eV3DProjStatus proj = ED_view3d_project_float_global(
      region, co, mval, V3D_PROJ_TEST_NOP);
  const bool proj_ok = (proj == V3D_PROJ_RET_OK);
  const bool on_screen = proj_ok && (mval[0] >= 0.0f) && (mval[0] < float(region->winx)) &&
                         (mval[1] >= 0.0f) && (mval[1] < float(region->winy));

  int xy[2] = {
      region->winrct.xmin + int(mval[0]),
      region->winrct.ymin + int(mval[1]),
  };
  /* Clamp into the region so strokes can continue near the edges. */
  xy[0] = std::clamp(xy[0], region->winrct.xmin, region->winrct.xmax - 1);
  xy[1] = std::clamp(xy[1], region->winrct.ymin, region->winrct.ymax - 1);
  wm_cursor_position_to_ghost_screen_coords(win, &xy[0], &xy[1]);

  const float tablet_pressure = tip_down ? std::max(pressure, 0.05f) : 0.0f;

  {
    static double last_log_time = 0.0;
    const double now = BLI_time_now_seconds();
    if (now - last_log_time >= 0.5) {
      last_log_time = now;
      char buf[320];
      SNPRINTF(buf,
               "muse tip=%d p=%.2f dirty=%d mode=%s blender=(%.2f,%.2f,%.2f)",
               int(tip_down),
               tablet_pressure,
               int(g_wm_ios_muse_geometry_dirty),
               vpaint_mode ? "vpaint" :
                   (sculpt_mode ? "sculpt3d" : (edit_mode ? "edit" : "other")),
               sample_x,
               sample_y,
               sample_z);
      GHOST_IOS_diag_log(buf);
      fprintf(stderr, "[immersive] %s\n", buf);
      fflush(stderr);
    }
  }

  /* Hover cursor feedback in the 2D View3D only (no tablet LMB for sculpt —
   * deformation is applied in 3D above). */
  if (proj_ok) {
    GHOST_IOS_push_tablet_cursor(xy[0], xy[1], tablet_pressure);
  }
}

static bool wm_ios_immersive_export_scene(bContext *C,
                                          const char *usdz_path,
                                          const bool show_error)
{
  wmOperatorType *ot = WM_operatortype_find("WM_OT_usd_export", true);
  if (ot == nullptr) {
    if (show_error) {
      GHOST_IOS_show_native_alert(
          "Immersive Space",
          "USD export is not available in this build. Enable WITH_USD and rebuild.");
    }
    return false;
  }

  if (BLI_exists(usdz_path)) {
    BLI_delete(usdz_path, false, false);
  }

  PointerRNA props_ptr;
  WM_operator_properties_create_ptr(&props_ptr, ot);
  RNA_string_set(&props_ptr, "filepath", usdz_path);
  RNA_boolean_set(&props_ptr, "visible_objects_only", true);
  RNA_boolean_set(&props_ptr, "selected_objects_only", false);
  RNA_boolean_set(&props_ptr, "export_materials", true);
  RNA_boolean_set(&props_ptr, "export_meshes", true);
  RNA_boolean_set(&props_ptr, "generate_preview_surface", true);
  /* Preserve physical dimensions: USD is authored with one unit per meter. */
  RNA_float_set(&props_ptr, "meters_per_unit", 1.0f);
  /* Match Muse/RealityKit Y-up: Blender (x,y,z) → USD (x,z,-y).
   * Hand tip inverse: RK (x,y,z) → Blender (x,-z,y). */
  RNA_boolean_set(&props_ptr, "convert_orientation", true);
  RNA_enum_set(&props_ptr, "export_global_forward_selection", 5 /* IO_AXIS_NEGATIVE_Z */);
  RNA_enum_set(&props_ptr, "export_global_up_selection", 1 /* IO_AXIS_Y */);
  /* Viewport evaluation: the render depsgraph reads the original mesh datablock,
   * which does not include live edit-mode changes until leaving edit mode. */
  RNA_enum_set(&props_ptr, "evaluation_mode", DAG_EVAL_VIEWPORT);

  const wmOperatorStatus export_status = WM_operator_name_call_ptr(
      C, ot, blender::wm::OpCallContext::ExecDefault, &props_ptr, nullptr);
  WM_operator_properties_free(&props_ptr);

  const bool ok = (export_status & OPERATOR_FINISHED) && BLI_exists(usdz_path);
  if (!ok && show_error) {
    GHOST_IOS_show_native_alert(
        "Immersive Space", "Could not export the current scene to USDZ for Immersive Space.");
  }
  return ok;
}

/**
 * Fingerprint visible mesh objects so adding a UV Sphere (etc.) forces Immersive
 * USD reload even while still in Object Mode.
 */
static uint64_t wm_ios_immersive_scene_mesh_fingerprint(bContext *C)
{
  Scene *scene = CTX_data_scene(C);
  ViewLayer *view_layer = CTX_data_view_layer(C);
  if (scene == nullptr || view_layer == nullptr) {
    return 0;
  }
  BKE_view_layer_synced_ensure(scene, view_layer);

  uint64_t h = 14695981039346656037ull;
  auto mix = [&h](uint64_t v) {
    h ^= v + 0x9e3779b97f4a7c15ull + (h << 6) + (h >> 2);
  };
  auto mix_str = [&](const char *s) {
    if (s == nullptr) {
      return;
    }
    for (const unsigned char *p = reinterpret_cast<const unsigned char *>(s); *p; p++) {
      h ^= uint64_t(*p);
      h *= 1099511628211ull;
    }
  };

  ListBase *bases = BKE_view_layer_object_bases_get(view_layer);
  int mesh_count = 0;
  for (Base *base = static_cast<Base *>(bases->first); base != nullptr; base = base->next) {
    Object *ob = base->object;
    if (ob == nullptr || ob->type != OB_MESH) {
      continue;
    }
    if ((base->flag & BASE_ENABLED_AND_MAYBE_VISIBLE_IN_VIEWPORT) == 0) {
      continue;
    }
    mesh_count++;
    mix_str(ob->id.name);
    if (Mesh *me = static_cast<Mesh *>(ob->data)) {
      mix(uint64_t(me->verts_num));
      mix(uint64_t(me->faces_num));
    }
    /* Do NOT mix object location into the fingerprint.
     * Including loc caused Immersive USD reloads to fight live transform sync
     * whenever the user moved an object in the 2D/3D viewport (front/back drift). */
  }
  mix(uint64_t(mesh_count));
  if (Object *active = CTX_data_active_object(C)) {
    mix_str(active->id.name);
    mix(uint64_t(active->mode));
  }
  return h;
}

static bool wm_ios_immersive_reload_usdz(bContext *C, Object *ob, const char *reason)
{
  static uint64_t refresh_serial = 0;
  char filename[64];
  SNPRINTF(filename, "immersive_preview_%llu.usdz", (unsigned long long)++refresh_serial);
  char usdz_path[FILE_MAX];
  BLI_path_join(usdz_path, sizeof(usdz_path), BKE_tempdir_session(), filename);

  if (ob != nullptr && (ob->mode & OB_MODE_EDIT) && ob->type == OB_MESH) {
    if (Main *bmain = CTX_data_main(C)) {
      if (BKE_editmesh_from_object(ob) != nullptr) {
        EDBM_mesh_load_ex(bmain, ob, false);
      }
    }
  }
  if (ob != nullptr && (ob->mode & OB_MODE_SCULPT) && BKE_object_sculpt_use_dyntopo(ob)) {
    BKE_sculptsession_bm_to_me(ob);
  }

  if (!wm_ios_immersive_export_scene(C, usdz_path, false)) {
    GHOST_IOS_diag_log("geometry refresh FAILED");
    return false;
  }
  GHOST_IOS_immersive_reload_model(usdz_path);
  GHOST_IOS_multiuser_broadcast_usd(usdz_path);
  g_wm_ios_muse_geometry_dirty = false;
  fprintf(stderr, "[immersive] geometry refreshed (%s)\n", reason ? reason : "sync");
  fflush(stderr);
  char buf[96];
  SNPRINTF(buf, "geometry refreshed (%s)", reason ? reason : "sync");
  GHOST_IOS_diag_log(buf);
  return true;
}

static void wm_ios_immersive_sync_impl(bContext *C)
{
  /* Hand-menu commands from Swift (mode / brush / strength / radius / dismiss). */
  wm_ios_immersive_apply_hand_menu(C);

  Object *ob = CTX_data_active_object(C);

  /* Heal pink/error materials even before Mat is opened (leftover from earlier builds). */
  {
    static double last_repair = 0.0;
    const double now_repair = BLI_time_now_seconds();
    if (now_repair - last_repair >= 2.0) {
      last_repair = now_repair;
      wm_ios_shader_repair_active_object_materials(C);
    }
  }

  /* Heartbeat so the on-device log shows what the sync loop can see. */
  {
    static double last_log_time = 0.0;
    const double log_now = BLI_time_now_seconds();
    if (log_now - last_log_time >= 2.0) {
      last_log_time = log_now;
      fprintf(stderr,
              "[immersive] sync alive: ob=%s mode=%d\n",
              ob ? ob->id.name + 2 : "(none)",
              ob ? ob->mode : -1);
      fflush(stderr);
    }
  }

  if (ob == nullptr) {
    wm_ios_immersive_consume_muse(C, nullptr);
    return;
  }

  std::string pending_name;
  float pending_z = 0.0f;
  {
    std::lock_guard lock(g_wm_ios_immersive_pending_move.mutex);
    if (g_wm_ios_immersive_pending_move.pending) {
      pending_name = g_wm_ios_immersive_pending_move.object_name;
      pending_z = g_wm_ios_immersive_pending_move.z;
      g_wm_ios_immersive_pending_move.pending = false;
    }
  }

  const char *object_name = ob->id.name + 2;
  if (!pending_name.empty() && pending_name == object_name) {
    /* pending_z is Blender *world* Z (Immersive gravity-up). Writing ob->loc[2]
     * remaps under parents/rotation and made Immersive up diverge from View3D. */
    float mat[4][4];
    copy_m4_m4(mat, ob->object_to_world().ptr());
    if (mat[3][2] != pending_z) {
      mat[3][2] = pending_z;
      BKE_object_apply_mat4(ob, mat, true, true);
      DEG_id_tag_update(&ob->id, ID_RECALC_TRANSFORM);
      WM_event_add_notifier(C, NC_OBJECT | ND_TRANSFORM, ob);
    }
  }

  static std::string last_object_name;
  static float last_location[3] = {0.0f, 0.0f, 0.0f};
  bool active_object_changed = false;
  /* Push Blender *world* location (not parent-space loc) so RealityKit Y/Z
   * mapping stays aligned with Immersive gravity-up = Blender Z. */
  float world_loc[3];
  copy_v3_v3(world_loc, ob->object_to_world().location());
  /* Also require a meaningful location delta before publishing (C++ uses exact float). */
  if (last_object_name != object_name ||
      fabsf(last_location[0] - world_loc[0]) > 1e-4f ||
      fabsf(last_location[1] - world_loc[1]) > 1e-4f ||
      fabsf(last_location[2] - world_loc[2]) > 1e-4f)
  {
    active_object_changed = (last_object_name != object_name);
    last_object_name = object_name;
    copy_v3_v3(last_location, world_loc);
    GHOST_IOS_immersive_update_active_object(
        object_name, world_loc[0], world_loc[1], world_loc[2]);
  }

  wm_ios_immersive_consume_muse(C, ob);

  /* Detect newly added meshes (UV Sphere etc.) / active switches even in Object Mode.
   * Previously Immersive only re-exported during sculpt/edit, so new objects never appeared. */
  static uint64_t last_scene_fp = 0;
  static bool scene_fp_init = false;
  const uint64_t scene_fp = wm_ios_immersive_scene_mesh_fingerprint(C);
  bool scene_structure_changed = false;
  if (!scene_fp_init) {
    last_scene_fp = scene_fp;
    scene_fp_init = true;
  }
  else if (scene_fp != last_scene_fp) {
    scene_structure_changed = true;
    last_scene_fp = scene_fp;
    g_wm_ios_muse_geometry_dirty = true;
    fprintf(stderr, "[immersive] scene mesh fingerprint changed — schedule USD reload\n");
    fflush(stderr);
    GHOST_IOS_diag_log("scene changed → USD reload");
  }
  if (active_object_changed) {
    g_wm_ios_muse_geometry_dirty = true;
  }

  /* Lightweight Immersive transform bridge (no USD). When enabled, publish all
   * visible mesh world locations so RealityKit entities track Object Mode moves
   * without a full scene reload. Structure/geo changes still use USD. */
  if (g_wm_ios_sync_transforms_to_space) {
    constexpr int kMaxXforms = 96;
    char names_blob[kMaxXforms * 64];
    float xyz[kMaxXforms * 3];
    int names_len = 0;
    int count = 0;
    Scene *scene_xf = CTX_data_scene(C);
    ViewLayer *view_layer_xf = CTX_data_view_layer(C);
    if (scene_xf != nullptr && view_layer_xf != nullptr) {
      BKE_view_layer_synced_ensure(scene_xf, view_layer_xf);
      ListBase *bases = BKE_view_layer_object_bases_get(view_layer_xf);
      for (Base *base = static_cast<Base *>(bases->first);
           base != nullptr && count < kMaxXforms;
           base = base->next)
      {
        Object *mob = base->object;
        if (mob == nullptr || mob->type != OB_MESH) {
          continue;
        }
        if ((base->flag & BASE_ENABLED_AND_MAYBE_VISIBLE_IN_VIEWPORT) == 0) {
          continue;
        }
        const char *n = mob->id.name + 2;
        const int nlen = int(std::strlen(n));
        if (nlen <= 0 || names_len + nlen + 1 >= int(sizeof(names_blob))) {
          break;
        }
        std::memcpy(names_blob + names_len, n, size_t(nlen + 1));
        names_len += nlen + 1;
        const float *wl = mob->object_to_world().location();
        xyz[count * 3 + 0] = wl[0];
        xyz[count * 3 + 1] = wl[1];
        xyz[count * 3 + 2] = wl[2];
        count++;
      }
    }
    if (count > 0) {
      GHOST_IOS_immersive_update_object_transforms(count, names_blob, names_len, xyz);
    }
  }

  /* Edit/sculpt mesh changes cannot be represented by transform updates.
   * Re-export the USDZ after a short debounce and ask RealityKit to reload.
   * While a Muse tip stroke is active, skip export; reload soon after release.
   * Object-mode scene adds also use this path via g_wm_ios_muse_geometry_dirty. */
  const bool mesh_edit_mode =
      (ob->mode & (OB_MODE_EDIT | OB_MODE_SCULPT | OB_MODE_VERTEX_PAINT)) != 0;
  const bool need_visual_sync = mesh_edit_mode || scene_structure_changed ||
                                active_object_changed || g_wm_ios_muse_geometry_dirty;
  if (need_visual_sync) {
    Depsgraph *depsgraph = CTX_data_depsgraph_pointer(C);
    static uint64_t last_update_count = 0;
    static uint64_t pending_update_count = 0;
    static double last_export_time = 0.0;
    const uint64_t update_count = depsgraph ? DEG_get_update_count(depsgraph) : 0;

    const double now = BLI_time_now_seconds();
    const bool tip_just_released = g_wm_ios_muse_tip_just_released;
    if (tip_just_released) {
      g_wm_ios_muse_tip_just_released = false;
    }
    const bool interaction_active = wm_ios_immersive_muse_interaction_active();
    /* Only chase depsgraph updates during live tip/interaction.
     * Otherwise shading/UI tags (Mat publish etc.) caused USD reload storms and
     * made the 2D/3D viewport stutter while Immersive was open. */
    if (update_count != last_update_count) {
      last_update_count = update_count;
      if (g_wm_ios_muse_tip_down || interaction_active || tip_just_released) {
        pending_update_count = update_count;
      }
    }

    /* Geometry dirty is authoritative — do not depend on depsgraph counters. */
    if (g_wm_ios_muse_geometry_dirty || tip_just_released || scene_structure_changed ||
        active_object_changed)
    {
      pending_update_count = 1;
    }

    /* Heartbeat so the on-device log shows this branch is reached. */
    static double last_log_time = 0.0;
    if (now - last_log_time >= 2.0) {
      last_log_time = now;
      fprintf(stderr,
              "[immersive] mesh sync alive: mode=%d dirty=%d tip_down=%d pending=%d\n",
              ob->mode,
              int(g_wm_ios_muse_geometry_dirty),
              g_wm_ios_muse_tip_down,
              int(pending_update_count != 0));
      fflush(stderr);
      char buf[160];
      SNPRINTF(buf,
               "mesh sync dirty=%d tip=%d pending=%d",
               int(g_wm_ios_muse_geometry_dirty),
               g_wm_ios_muse_tip_down,
               int(pending_update_count != 0));
      GHOST_IOS_diag_log(buf);
    }

    /* Live Immersive refresh pacing — driven by Immersive sidebar
     * ``usd_refresh_interval`` (default 0.35s). Tip-up stays near-immediate. */
    const double interval = double(g_wm_ios_usd_refresh_interval);
    const double debounce = tip_just_released ? std::min(0.05, interval) :
                            (g_wm_ios_muse_tip_down || interaction_active) ?
                                std::max(0.10, interval * 0.65) :
                            (scene_structure_changed || active_object_changed) ? interval :
                                                                                std::max(interval, 0.20);
    if (pending_update_count != 0 && (now - last_export_time) >= debounce) {
      /* Avoid mid-stroke full-scene swap when only structure changed. */
      if (interaction_active && !tip_just_released && !g_wm_ios_muse_geometry_dirty &&
          (scene_structure_changed || active_object_changed))
      {
        /* Wait until tip up. */
      }
      else {
        const char *reason = tip_just_released ? "tip-up" :
                             scene_structure_changed ? "scene" :
                             active_object_changed   ? "active" :
                                                       "sculpt/edit";
        if (wm_ios_immersive_reload_usdz(C, ob, reason)) {
          last_export_time = now;
          last_update_count = depsgraph ? DEG_get_update_count(depsgraph) : last_update_count;
          pending_update_count = 0;
          last_scene_fp = wm_ios_immersive_scene_mesh_fingerprint(C);
        }
      }
    }
  }
}

/**
 * Runs from the regular Blender/Metal draw loop. Apply queued RealityKit input
 * on Blender's main loop, then publish active-object location changes back to Swift.
 */
void WM_ios_immersive_sync_active_object(bContext *C)
{
  if (C == nullptr) {
    return;
  }

  wmWindowManager *wm = CTX_wm_manager(C);
  if (wm == nullptr) {
    return;
  }

  /* The main loop clears the context window at the end of every iteration, so
   * this draw-loop callback usually starts with no window/screen in context. */
  wmWindow *win_prev = CTX_wm_window(C);
  if (win_prev == nullptr) {
    wmWindow *win = static_cast<wmWindow *>(wm->windows.first);
    if (win == nullptr) {
      return;
    }
    CTX_wm_window_set(C, win);
  }

  /* Pink-material heal must run even when Immersive Space is closed — the 2D/3D
   * viewport shows EEVEE error magenta from leftover broken nodetrees. */
  {
    static double last_repair = 0.0;
    static bool first_pass = true;
    bool pending_repair = false;
    bool repair_force = false;
    {
      std::lock_guard lock(g_wm_ios_shader_cmd.mutex);
      pending_repair = g_wm_ios_shader_cmd.pending_repair;
      repair_force = g_wm_ios_shader_cmd.repair_force;
      if (pending_repair) {
        g_wm_ios_shader_cmd.pending_repair = false;
        g_wm_ios_shader_cmd.repair_force = false;
      }
    }
    const double now = BLI_time_now_seconds();
    if (pending_repair || first_pass || (now - last_repair) >= 1.0) {
      last_repair = now;
      /* Build 78–81 left broken node trees. On first draw after launch (and when
       * the user taps 材質修復), force-reset every node material to Principled. */
      const bool force = first_pass || (pending_repair && repair_force);
      wm_ios_shader_repair_all_materials(C, force);
      first_pass = false;
    }
  }

  if (!GHOST_IOS_immersive_mode_is_active()) {
    if (win_prev == nullptr) {
      CTX_wm_window_set(C, nullptr);
    }
    return;
  }

  wm_ios_immersive_sync_impl(C);

  if (win_prev == nullptr) {
    CTX_wm_window_set(C, nullptr);
  }
}

static bool wm_ios_immersive_poll(bContext *C)
{
  return WM_operator_winactive(C);
}

static wmOperatorStatus wm_ios_immersive_toggle_exec(bContext *C, wmOperator * /*op*/)
{
  if (!GHOST_IOS_immersive_space_is_supported()) {
    GHOST_IOS_show_native_alert(
        "Immersive Space",
        "This build is not a native visionOS Immersive Space build.\n\n"
        "Reconfigure with:\n"
        "  -DAPPLE_TARGET_DEVICE=visionos\n"
        "  -DWITH_VISIONOS_IMMERSIVE_SPACE=ON\n\n"
        "Current iOS/iPad builds deploy to Vision Pro in compatibility mode "
        "and cannot open Immersive Space. Use branch immersive-space.");
    return OPERATOR_CANCELLED;
  }

  if (GHOST_IOS_immersive_mode_is_active()) {
    if (!GHOST_IOS_set_immersive_mode_enabled(false, nullptr)) {
      return OPERATOR_CANCELLED;
    }
    WM_event_add_notifier(C, NC_SPACE | ND_SPACE_VIEW3D, nullptr);
    return OPERATOR_FINISHED;
  }

  char usdz_path[FILE_MAX] = "";
  BLI_path_join(usdz_path, sizeof(usdz_path), BKE_tempdir_session(), "immersive_preview.usdz");
  if (!wm_ios_immersive_export_scene(C, usdz_path, true)) {
    return OPERATOR_CANCELLED;
  }

  if (!GHOST_IOS_set_immersive_mode_enabled(true, usdz_path)) {
    GHOST_IOS_show_native_alert(
        "Immersive Space",
        "Could not open Immersive Space. Confirm this is a visionOS build with "
        "RealityKit Immersive Space enabled.");
    return OPERATOR_CANCELLED;
  }

  /* If already hosting a multiuser session, push the opening snapshot. */
  GHOST_IOS_multiuser_broadcast_usd(usdz_path);

  WM_event_add_notifier(C, NC_SPACE | ND_SPACE_VIEW3D, nullptr);
  return OPERATOR_FINISHED;
}

static wmOperatorStatus wm_ios_multiuser_host_exec(bContext *C, wmOperator *op)
{
  char name[64];
  RNA_string_get(op->ptr, "display_name", name);
  if (!GHOST_IOS_multiuser_host(name[0] != '\0' ? name : nullptr)) {
    BKE_report(op->reports, RPT_ERROR, "Could not start Immersive multiuser host");
    return OPERATOR_CANCELLED;
  }
  /* Push current Immersive USD if already open. */
  char usdz_path[FILE_MAX] = "";
  BLI_path_join(usdz_path, sizeof(usdz_path), BKE_tempdir_session(), "immersive_preview.usdz");
  if (GHOST_IOS_immersive_mode_is_active()) {
    if (wm_ios_immersive_export_scene(C, usdz_path, false)) {
      GHOST_IOS_immersive_reload_model(usdz_path);
      GHOST_IOS_multiuser_broadcast_usd(usdz_path);
    }
  }
  WM_event_add_notifier(C, NC_SPACE | ND_SPACE_VIEW3D, nullptr);
  return OPERATOR_FINISHED;
}

static wmOperatorStatus wm_ios_multiuser_join_exec(bContext * /*C*/, wmOperator *op)
{
  char name[64];
  RNA_string_get(op->ptr, "display_name", name);
  if (!GHOST_IOS_multiuser_join(name[0] != '\0' ? name : nullptr)) {
    BKE_report(op->reports, RPT_ERROR, "Could not join Immersive multiuser session");
    return OPERATOR_CANCELLED;
  }
  return OPERATOR_FINISHED;
}

static wmOperatorStatus wm_ios_multiuser_leave_exec(bContext * /*C*/, wmOperator * /*op*/)
{
  GHOST_IOS_multiuser_leave();
  return OPERATOR_FINISHED;
}

static void WM_OT_ios_immersive_multiuser_host(wmOperatorType *ot)
{
  ot->name = "Immersive Multiuser Host";
  ot->idname = "WM_OT_ios_immersive_multiuser_host";
  ot->description =
      "Host a local-network Immersive share session for nearby Vision Pro devices";
  ot->exec = wm_ios_multiuser_host_exec;
  ot->poll = wm_ios_immersive_poll;
  /* RNA_def_string forbids "" as default; use nullptr for empty. */
  RNA_def_string(ot->srna,
                 "display_name",
                 nullptr,
                 64,
                 "Display Name",
                 "Name shown to guests");
}

static void WM_OT_ios_immersive_multiuser_join(wmOperatorType *ot)
{
  ot->name = "Immersive Multiuser Join";
  ot->idname = "WM_OT_ios_immersive_multiuser_join";
  ot->description = "Join a nearby Vision Pro Immersive share session";
  ot->exec = wm_ios_multiuser_join_exec;
  ot->poll = wm_ios_immersive_poll;
  RNA_def_string(ot->srna,
                 "display_name",
                 nullptr,
                 64,
                 "Display Name",
                 "Name shown to the host");
}

static void WM_OT_ios_immersive_multiuser_leave(wmOperatorType *ot)
{
  ot->name = "Immersive Multiuser Leave";
  ot->idname = "WM_OT_ios_immersive_multiuser_leave";
  ot->description = "Leave the Immersive multiuser share session";
  ot->exec = wm_ios_multiuser_leave_exec;
  ot->poll = wm_ios_immersive_poll;
}

static void WM_OT_ios_immersive_toggle(wmOperatorType *ot)
{
  ot->name = "Open Immersive Space";
  ot->idname = "WM_OT_ios_immersive_toggle";
  ot->description =
      "Export the visible scene to USDZ and open Apple Vision Pro Immersive Space (visionOS only)";

  ot->exec = wm_ios_immersive_toggle_exec;
  ot->poll = wm_ios_immersive_poll;
}

static wmOperatorStatus wm_ios_immersive_set_hand_as_pen_exec(bContext *C, wmOperator *op)
{
  const bool enable = RNA_boolean_get(op->ptr, "enable");
  WM_IOS_immersive_set_hand_as_pen(enable ? 1 : 0);
  WM_event_add_notifier(C, NC_SPACE | ND_SPACE_VIEW3D, nullptr);
  char buf[64];
  SNPRINTF(buf, "hand-as-pen: %s", enable ? "ON" : "OFF");
  GHOST_IOS_diag_log(buf);
  return OPERATOR_FINISHED;
}

static void WM_OT_ios_immersive_set_hand_as_pen(wmOperatorType *ot)
{
  ot->name = "Immersive Use Hand as Pen";
  ot->idname = "WM_OT_ios_immersive_set_hand_as_pen";
  ot->description = "Use right-hand pinch instead of Logitech Muse in Immersive Space";
  ot->exec = wm_ios_immersive_set_hand_as_pen_exec;
  ot->poll = wm_ios_immersive_poll;
  RNA_def_boolean(ot->srna, "enable", false, "Enable", "Use hand tip as pen");
}

static wmOperatorStatus wm_ios_immersive_set_hand_proximity_sculpt_exec(bContext *C, wmOperator *op)
{
  const bool enable = RNA_boolean_get(op->ptr, "enable");
  WM_IOS_immersive_set_hand_proximity_sculpt(enable ? 1 : 0);
  WM_event_add_notifier(C, NC_SPACE | ND_SPACE_VIEW3D, nullptr);
  char buf[80];
  SNPRINTF(buf, "hand proximity sculpt: %s", enable ? "ON" : "OFF");
  GHOST_IOS_diag_log(buf);
  return OPERATOR_FINISHED;
}

static void WM_OT_ios_immersive_set_hand_proximity_sculpt(wmOperatorType *ot)
{
  ot->name = "Immersive Hand Proximity Sculpt";
  ot->idname = "WM_OT_ios_immersive_set_hand_proximity_sculpt";
  ot->description = "When hand-as-pen is enabled, sculpt by bringing the hand close (no pinch)";
  ot->exec = wm_ios_immersive_set_hand_proximity_sculpt_exec;
  ot->poll = wm_ios_immersive_poll;
  RNA_def_boolean(ot->srna, "enable", false, "Enable", "Sculpt without pinch in hand mode");
}

static wmOperatorStatus wm_ios_immersive_set_strength_exec(bContext * /*C*/, wmOperator *op)
{
  WM_IOS_immersive_hand_menu_set_strength(RNA_float_get(op->ptr, "strength"));
  return OPERATOR_FINISHED;
}

static void WM_OT_ios_immersive_set_strength(wmOperatorType *ot)
{
  ot->name = "Immersive Set Strength";
  ot->idname = "WM_OT_ios_immersive_set_strength";
  ot->exec = wm_ios_immersive_set_strength_exec;
  ot->poll = wm_ios_immersive_poll;
  RNA_def_float(ot->srna, "strength", 0.5f, 0.05f, 1.0f, "Strength", "", 0.05f, 1.0f);
}

static wmOperatorStatus wm_ios_immersive_set_radius_exec(bContext * /*C*/, wmOperator *op)
{
  WM_IOS_immersive_hand_menu_set_radius(RNA_float_get(op->ptr, "radius"));
  return OPERATOR_FINISHED;
}

static void WM_OT_ios_immersive_set_radius(wmOperatorType *ot)
{
  ot->name = "Immersive Set Radius";
  ot->idname = "WM_OT_ios_immersive_set_radius";
  ot->exec = wm_ios_immersive_set_radius_exec;
  ot->poll = wm_ios_immersive_poll;
  RNA_def_float(ot->srna, "radius", 0.25f, 0.02f, 0.80f, "Radius", "", 0.02f, 0.80f);
}

static wmOperatorStatus wm_ios_immersive_set_dyntopo_exec(bContext * /*C*/, wmOperator *op)
{
  WM_IOS_immersive_hand_menu_set_dyntopo(RNA_boolean_get(op->ptr, "enable") ? 1 : 0);
  return OPERATOR_FINISHED;
}

static void WM_OT_ios_immersive_set_dyntopo(wmOperatorType *ot)
{
  ot->name = "Immersive Set Dyntopo";
  ot->idname = "WM_OT_ios_immersive_set_dyntopo";
  ot->exec = wm_ios_immersive_set_dyntopo_exec;
  ot->poll = wm_ios_immersive_poll;
  RNA_def_boolean(ot->srna, "enable", true, "Enable", "Dynamic Topology");
}

static wmOperatorStatus wm_ios_immersive_set_mode_exec(bContext * /*C*/, wmOperator *op)
{
  WM_IOS_immersive_hand_menu_set_mode(RNA_int_get(op->ptr, "mode"));
  return OPERATOR_FINISHED;
}

static void WM_OT_ios_immersive_set_mode(wmOperatorType *ot)
{
  ot->name = "Immersive Set Mode";
  ot->idname = "WM_OT_ios_immersive_set_mode";
  ot->exec = wm_ios_immersive_set_mode_exec;
  ot->poll = wm_ios_immersive_poll;
  RNA_def_int(ot->srna, "mode", 2, 0, 4, "Mode",
              "0 Object / 1 Edit / 2 Sculpt / 3 VPaint / 4 Anim(Pose)",
              0,
              4);
}

static wmOperatorStatus wm_ios_immersive_set_usd_refresh_interval_exec(bContext * /*C*/,
                                                                     wmOperator *op)
{
  WM_IOS_immersive_set_usd_refresh_interval(RNA_float_get(op->ptr, "seconds"));
  return OPERATOR_FINISHED;
}

static void WM_OT_ios_immersive_set_usd_refresh_interval(wmOperatorType *ot)
{
  ot->name = "Immersive Set USD Refresh Interval";
  ot->idname = "WM_OT_ios_immersive_set_usd_refresh_interval";
  ot->description =
      "Seconds between Immersive USDZ scene reloads when the spatial mesh is dirty";
  ot->exec = wm_ios_immersive_set_usd_refresh_interval_exec;
  ot->poll = wm_ios_immersive_poll;
  RNA_def_float(ot->srna, "seconds", 0.35f, 0.08f, 2.0f, "Seconds", "", 0.08f, 2.0f);
}

static wmOperatorStatus wm_ios_immersive_set_sync_transforms_exec(bContext * /*C*/, wmOperator *op)
{
  WM_IOS_immersive_set_sync_transforms_to_space(RNA_boolean_get(op->ptr, "enable") ? 1 : 0);
  return OPERATOR_FINISHED;
}

static void WM_OT_ios_immersive_set_sync_transforms(wmOperatorType *ot)
{
  ot->name = "Immersive Sync Object Transforms";
  ot->idname = "WM_OT_ios_immersive_set_sync_transforms";
  ot->description =
      "Also push Object Mode moves/scales into Immersive via USD (needed for multi-object demos)";
  ot->exec = wm_ios_immersive_set_sync_transforms_exec;
  ot->poll = wm_ios_immersive_poll;
  RNA_def_boolean(ot->srna, "enable", false, "Enable", "Sync transforms into Immersive Space");
}

static wmOperatorStatus wm_ios_immersive_remesh_exec(bContext * /*C*/, wmOperator * /*op*/)
{
  WM_IOS_immersive_hand_menu_remesh();
  return OPERATOR_FINISHED;
}

static void WM_OT_ios_immersive_remesh(wmOperatorType *ot)
{
  ot->name = "Immersive Remesh";
  ot->idname = "WM_OT_ios_immersive_remesh";
  ot->exec = wm_ios_immersive_remesh_exec;
  ot->poll = wm_ios_immersive_poll;
}
#endif

/** \} */

/* -------------------------------------------------------------------- */
/** \name Operator Registration & Keymaps
 * \{ */

void wm_operatortypes_register()
{
  WM_operatortype_append(WM_OT_window_close);
  WM_operatortype_append(WM_OT_window_new);
  WM_operatortype_append(WM_OT_window_new_main);
  WM_operatortype_append(WM_OT_read_history);
  WM_operatortype_append(WM_OT_read_homefile);
  WM_operatortype_append(WM_OT_read_factory_settings);
  WM_operatortype_append(WM_OT_save_homefile);
  WM_operatortype_append(WM_OT_save_userpref);
  WM_operatortype_append(WM_OT_read_userpref);
  WM_operatortype_append(WM_OT_read_factory_userpref);
  WM_operatortype_append(WM_OT_window_fullscreen_toggle);
  WM_operatortype_append(WM_OT_quit_blender);
  WM_operatortype_append(WM_OT_open_mainfile);
  WM_operatortype_append(WM_OT_revert_mainfile);
  WM_operatortype_append(WM_OT_link);
  WM_operatortype_append(WM_OT_append);
  WM_operatortype_append(WM_OT_id_linked_relocate);
  WM_operatortype_append(WM_OT_lib_relocate);
  WM_operatortype_append(WM_OT_lib_reload);
  WM_operatortype_append(WM_OT_recover_last_session);
  WM_operatortype_append(WM_OT_recover_auto_save);
  WM_operatortype_append(WM_OT_save_as_mainfile);
  WM_operatortype_append(WM_OT_save_mainfile);
  WM_operatortype_append(WM_OT_clear_recent_files);
  WM_operatortype_append(WM_OT_redraw_timer);
  WM_operatortype_append(WM_OT_memory_statistics);
  WM_operatortype_append(WM_OT_debug_menu);
  WM_operatortype_append(WM_OT_operator_defaults);
  WM_operatortype_append(WM_OT_splash);
  WM_operatortype_append(WM_OT_splash_about);
  WM_operatortype_append(WM_OT_search_menu);
  WM_operatortype_append(WM_OT_search_operator);
  WM_operatortype_append(WM_OT_search_single_menu);
  WM_operatortype_append(WM_OT_call_menu);
  WM_operatortype_append(WM_OT_call_menu_pie);
  WM_operatortype_append(WM_OT_call_panel);
  WM_operatortype_append(WM_OT_call_asset_shelf_popover);
  WM_operatortype_append(WM_OT_radial_control);
  WM_operatortype_append(WM_OT_stereo3d_set);
#if defined(WIN32)
  WM_operatortype_append(WM_OT_console_toggle);
#endif
#if defined(WITH_APPLE_CROSSPLATFORM)
  WM_operatortype_append(WM_OT_ios_immersive_toggle);
  WM_operatortype_append(WM_OT_ios_immersive_set_hand_as_pen);
  WM_operatortype_append(WM_OT_ios_immersive_set_hand_proximity_sculpt);
  WM_operatortype_append(WM_OT_ios_immersive_set_strength);
  WM_operatortype_append(WM_OT_ios_immersive_set_radius);
  WM_operatortype_append(WM_OT_ios_immersive_set_dyntopo);
  WM_operatortype_append(WM_OT_ios_immersive_set_mode);
  WM_operatortype_append(WM_OT_ios_immersive_set_usd_refresh_interval);
  WM_operatortype_append(WM_OT_ios_immersive_set_sync_transforms);
  WM_operatortype_append(WM_OT_ios_immersive_remesh);
  WM_operatortype_append(WM_OT_ios_immersive_multiuser_host);
  WM_operatortype_append(WM_OT_ios_immersive_multiuser_join);
  WM_operatortype_append(WM_OT_ios_immersive_multiuser_leave);
#endif
  WM_operatortype_append(WM_OT_previews_ensure);
  WM_operatortype_append(WM_OT_previews_clear);
  WM_operatortype_append(WM_OT_doc_view_manual_ui_context);
  WM_operatortype_append(WM_OT_set_working_color_space);

#ifdef WITH_XR_OPENXR
  wm_xr_operatortypes_register();
#endif

  /* Gizmos. */
  WM_operatortype_append(GIZMOGROUP_OT_gizmo_select);
  WM_operatortype_append(GIZMOGROUP_OT_gizmo_tweak);
}

/* Circle-select-like modal operators. */
static void gesture_circle_modal_keymap(wmKeyConfig *keyconf)
{
  static const EnumPropertyItem modal_items[] = {
      {GESTURE_MODAL_CANCEL, "CANCEL", 0, "Cancel", ""},
      {GESTURE_MODAL_CONFIRM, "CONFIRM", 0, "Confirm", ""},
      {GESTURE_MODAL_CIRCLE_ADD, "ADD", 0, "Add", ""},
      {GESTURE_MODAL_CIRCLE_SUB, "SUBTRACT", 0, "Subtract", ""},
      {GESTURE_MODAL_CIRCLE_SIZE, "SIZE", 0, "Size", ""},

      {GESTURE_MODAL_SELECT, "SELECT", 0, "Select", ""},
      {GESTURE_MODAL_DESELECT, "DESELECT", 0, "Deselect", ""},
      {GESTURE_MODAL_NOP, "NOP", 0, "No Operation", ""},

      {0, nullptr, 0, nullptr, nullptr},
  };

  /* WARNING: Name is incorrect, use for non-3d views. */
  wmKeyMap *keymap = WM_modalkeymap_find(keyconf, "View3D Gesture Circle");

  /* This function is called for each space-type, only needs to add map once. */
  if (keymap && keymap->modal_items) {
    return;
  }

  keymap = WM_modalkeymap_ensure(keyconf, "View3D Gesture Circle", modal_items);

  /* Assign map to operators. */
  WM_modalkeymap_assign(keymap, "VIEW3D_OT_select_circle");
  WM_modalkeymap_assign(keymap, "UV_OT_select_circle");
  WM_modalkeymap_assign(keymap, "SEQUENCER_OT_select_circle");
  WM_modalkeymap_assign(keymap, "CLIP_OT_select_circle");
  WM_modalkeymap_assign(keymap, "MASK_OT_select_circle");
  WM_modalkeymap_assign(keymap, "NODE_OT_select_circle");
  WM_modalkeymap_assign(keymap, "GRAPH_OT_select_circle");
  WM_modalkeymap_assign(keymap, "ACTION_OT_select_circle");
}

/* Straight line modal operators. */
static void gesture_straightline_modal_keymap(wmKeyConfig *keyconf)
{
  static const EnumPropertyItem modal_items[] = {
      {GESTURE_MODAL_CANCEL, "CANCEL", 0, "Cancel", ""},
      {GESTURE_MODAL_SELECT, "SELECT", 0, "Select", ""},
      {GESTURE_MODAL_BEGIN, "BEGIN", 0, "Begin", ""},
      {GESTURE_MODAL_MOVE, "MOVE", 0, "Move", ""},
      {GESTURE_MODAL_SNAP, "SNAP", 0, "Snap", ""},
      {GESTURE_MODAL_FLIP, "FLIP", 0, "Flip", ""},
      {0, nullptr, 0, nullptr, nullptr},
  };

  wmKeyMap *keymap = WM_modalkeymap_find(keyconf, "Gesture Straight Line");

  /* This function is called for each space-type, only needs to add map once. */
  if (keymap && keymap->modal_items) {
    return;
  }

  keymap = WM_modalkeymap_ensure(keyconf, "Gesture Straight Line", modal_items);

  /* Assign map to operators. */
  WM_modalkeymap_assign(keymap, "IMAGE_OT_sample_line");
  WM_modalkeymap_assign(keymap, "PAINT_OT_weight_gradient");
  WM_modalkeymap_assign(keymap, "MESH_OT_bisect");
  WM_modalkeymap_assign(keymap, "PAINT_OT_mask_line_gesture");
  WM_modalkeymap_assign(keymap, "SCULPT_OT_face_set_line_gesture");
  WM_modalkeymap_assign(keymap, "SCULPT_OT_trim_line_gesture");
  WM_modalkeymap_assign(keymap, "SCULPT_OT_project_line_gesture");
  WM_modalkeymap_assign(keymap, "PAINT_OT_hide_show_line_gesture");
}

/* Box_select-like modal operators. */
static void gesture_box_modal_keymap(wmKeyConfig *keyconf)
{
  static const EnumPropertyItem modal_items[] = {
      {GESTURE_MODAL_CANCEL, "CANCEL", 0, "Cancel", ""},
      {GESTURE_MODAL_SELECT, "SELECT", 0, "Select", ""},
      {GESTURE_MODAL_DESELECT, "DESELECT", 0, "Deselect", ""},
      {GESTURE_MODAL_BEGIN, "BEGIN", 0, "Begin", ""},
      {GESTURE_MODAL_MOVE, "MOVE", 0, "Move", ""},
      {0, nullptr, 0, nullptr, nullptr},
  };

  wmKeyMap *keymap = WM_modalkeymap_find(keyconf, "Gesture Box");

  /* This function is called for each space-type, only needs to add map once. */
  if (keymap && keymap->modal_items) {
    return;
  }

  keymap = WM_modalkeymap_ensure(keyconf, "Gesture Box", modal_items);

  /* Assign map to operators. */
  WM_modalkeymap_assign(keymap, "ACTION_OT_select_box");
  WM_modalkeymap_assign(keymap, "ANIM_OT_channels_select_box");
  WM_modalkeymap_assign(keymap, "ANIM_OT_previewrange_set");
  WM_modalkeymap_assign(keymap, "INFO_OT_select_box");
  WM_modalkeymap_assign(keymap, "FILE_OT_select_box");
  WM_modalkeymap_assign(keymap, "GRAPH_OT_select_box");
  WM_modalkeymap_assign(keymap, "MARKER_OT_select_box");
  WM_modalkeymap_assign(keymap, "NLA_OT_select_box");
  WM_modalkeymap_assign(keymap, "NODE_OT_select_box");
  WM_modalkeymap_assign(keymap, "NODE_OT_viewer_border");
  WM_modalkeymap_assign(keymap, "PAINT_OT_hide_show");
  WM_modalkeymap_assign(keymap, "OUTLINER_OT_select_box");
#if 0 /* Template. */
  WM_modalkeymap_assign(keymap, "SCREEN_OT_box_select");
#endif
  WM_modalkeymap_assign(keymap, "SEQUENCER_OT_select_box");
  WM_modalkeymap_assign(keymap, "SEQUENCER_OT_view_ghost_border");
  WM_modalkeymap_assign(keymap, "UV_OT_select_box");
  WM_modalkeymap_assign(keymap, "CLIP_OT_select_box");
  WM_modalkeymap_assign(keymap, "CLIP_OT_graph_select_box");
  WM_modalkeymap_assign(keymap, "MASK_OT_select_box");
  WM_modalkeymap_assign(keymap, "PAINT_OT_mask_box_gesture");
  WM_modalkeymap_assign(keymap, "SCULPT_OT_face_set_box_gesture");
  WM_modalkeymap_assign(keymap, "SCULPT_OT_trim_box_gesture");
  WM_modalkeymap_assign(keymap, "VIEW2D_OT_zoom_border");
  WM_modalkeymap_assign(keymap, "VIEW3D_OT_clip_border");
  WM_modalkeymap_assign(keymap, "VIEW3D_OT_render_border");
  WM_modalkeymap_assign(keymap, "VIEW3D_OT_select_box");
  /* XXX TODO: zoom border should perhaps map right-mouse to zoom out instead of in+cancel. */
  WM_modalkeymap_assign(keymap, "VIEW3D_OT_zoom_border");
  WM_modalkeymap_assign(keymap, "IMAGE_OT_render_border");
  WM_modalkeymap_assign(keymap, "IMAGE_OT_view_zoom_border");
  WM_modalkeymap_assign(keymap, "GREASE_PENCIL_OT_erase_box");
}

/* Lasso modal operators. */
static void gesture_lasso_modal_keymap(wmKeyConfig *keyconf)
{
  static const EnumPropertyItem modal_items[] = {
      {GESTURE_MODAL_MOVE, "MOVE", 0, "Move", ""},
      {0, nullptr, 0, nullptr, nullptr},
  };

  wmKeyMap *keymap = WM_modalkeymap_find(keyconf, "Gesture Lasso");

  /* This function is called for each space-type, only needs to add map once. */
  if (keymap && keymap->modal_items) {
    return;
  }

  keymap = WM_modalkeymap_ensure(keyconf, "Gesture Lasso", modal_items);

  /* Assign map to operators. */
  WM_modalkeymap_assign(keymap, "VIEW3D_OT_select_lasso");
  WM_modalkeymap_assign(keymap, "MASK_OT_select_lasso");
  WM_modalkeymap_assign(keymap, "PAINT_OT_mask_lasso_gesture");
  WM_modalkeymap_assign(keymap, "SCULPT_OT_face_set_lasso_gesture");
  WM_modalkeymap_assign(keymap, "SCULPT_OT_trim_lasso_gesture");
  WM_modalkeymap_assign(keymap, "ACTION_OT_select_lasso");
  WM_modalkeymap_assign(keymap, "CLIP_OT_select_lasso");
  WM_modalkeymap_assign(keymap, "GRAPH_OT_select_lasso");
  WM_modalkeymap_assign(keymap, "NODE_OT_select_lasso");
  WM_modalkeymap_assign(keymap, "UV_OT_select_lasso");
  WM_modalkeymap_assign(keymap, "SEQUENCER_OT_select_lasso");
  WM_modalkeymap_assign(keymap, "PAINT_OT_hide_show_lasso_gesture");
  WM_modalkeymap_assign(keymap, "GREASE_PENCIL_OT_erase_lasso");
}

/* Polyline modal operators */
static void gesture_polyline_modal_keymap(wmKeyConfig *keyconf)
{
  static const EnumPropertyItem modal_items[] = {
      {GESTURE_MODAL_CONFIRM, "CONFIRM", 0, "Confirm", ""},
      {GESTURE_MODAL_CANCEL, "CANCEL", 0, "Cancel", ""},
      {GESTURE_MODAL_SELECT, "SELECT", 0, "Select", ""},
      {GESTURE_MODAL_MOVE, "MOVE", 0, "Move", ""},
      {0, nullptr, 0, nullptr, nullptr},
  };

  wmKeyMap *keymap = WM_modalkeymap_find(keyconf, "Gesture Polyline");

  /* This function is called for each space-type, only needs to add map once. */
  if (keymap && keymap->modal_items) {
    return;
  }

  keymap = WM_modalkeymap_ensure(keyconf, "Gesture Polyline", modal_items);

  /* assign map to operators */
  WM_modalkeymap_assign(keymap, "PAINT_OT_hide_show_polyline_gesture");
  WM_modalkeymap_assign(keymap, "PAINT_OT_mask_polyline_gesture");
  WM_modalkeymap_assign(keymap, "SCULPT_OT_face_set_polyline_gesture");
  WM_modalkeymap_assign(keymap, "SCULPT_OT_trim_polyline_gesture");
}

/* Zoom to border modal operators. */
static void gesture_zoom_border_modal_keymap(wmKeyConfig *keyconf)
{
  static const EnumPropertyItem modal_items[] = {
      {GESTURE_MODAL_CANCEL, "CANCEL", 0, "Cancel", ""},
      {GESTURE_MODAL_IN, "IN", 0, "In", ""},
      {GESTURE_MODAL_OUT, "OUT", 0, "Out", ""},
      {GESTURE_MODAL_BEGIN, "BEGIN", 0, "Begin", ""},
      {0, nullptr, 0, nullptr, nullptr},
  };

  wmKeyMap *keymap = WM_modalkeymap_find(keyconf, "Gesture Zoom Border");

  /* This function is called for each space-type, only needs to add map once. */
  if (keymap && keymap->modal_items) {
    return;
  }

  keymap = WM_modalkeymap_ensure(keyconf, "Gesture Zoom Border", modal_items);

  /* Assign map to operators. */
  WM_modalkeymap_assign(keymap, "VIEW2D_OT_zoom_border");
  WM_modalkeymap_assign(keymap, "VIEW3D_OT_zoom_border");
  WM_modalkeymap_assign(keymap, "IMAGE_OT_view_zoom_border");
}

void wm_window_keymap(wmKeyConfig *keyconf)
{
  WM_keymap_ensure(keyconf, "Window", SPACE_EMPTY, RGN_TYPE_WINDOW);

  wm_gizmos_keymap(keyconf);
  gesture_circle_modal_keymap(keyconf);
  gesture_box_modal_keymap(keyconf);
  gesture_zoom_border_modal_keymap(keyconf);
  gesture_straightline_modal_keymap(keyconf);
  gesture_lasso_modal_keymap(keyconf);
  gesture_polyline_modal_keymap(keyconf);

  WM_keymap_fix_linking();
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Enum Filter Functions
 *
 * Filter functions that can be used with rna_id_itemf() below.
 * Should return false if 'id' should be excluded.
 *
 * \{ */

static bool rna_id_enum_filter_single(const ID *id, void *user_data)
{
  return (id != user_data);
}

/* Generic itemf's for operators that take library args. */
static const EnumPropertyItem *rna_id_itemf(bool *r_free,
                                            ID *id,
                                            bool local,
                                            bool (*filter_ids)(const ID *id, void *user_data),
                                            void *user_data)
{
  EnumPropertyItem item_tmp = {0}, *item = nullptr;
  int totitem = 0;
  int i = 0;

  if (id != nullptr) {
    const short id_type = GS(id->name);
    for (; id; id = static_cast<ID *>(id->next)) {
      if ((filter_ids != nullptr) && filter_ids(id, user_data) == false) {
        i++;
        continue;
      }
      if (local == false || !ID_IS_LINKED(id)) {
        item_tmp.identifier = item_tmp.name = id->name + 2;
        item_tmp.value = i++;

        /* Show collection color tag icons in menus. */
        if (id_type == ID_GR) {
          item_tmp.icon = UI_icon_color_from_collection((Collection *)id);
        }

        RNA_enum_item_add(&item, &totitem, &item_tmp);
      }
    }
  }

  RNA_enum_item_end(&item, &totitem);
  *r_free = true;

  return item;
}

/* Can add more ID types as needed. */

const EnumPropertyItem *RNA_action_itemf(bContext *C,
                                         PointerRNA * /*ptr*/,
                                         PropertyRNA * /*prop*/,
                                         bool *r_free)
{

  return rna_id_itemf(
      r_free, C ? (ID *)CTX_data_main(C)->actions.first : nullptr, false, nullptr, nullptr);
}
#if 0 /* UNUSED. */
const EnumPropertyItem *RNA_action_local_itemf(bContext *C,
                                               PointerRNA * /*ptr*/,
                                               PropertyRNA * /*prop*/,
                                               bool *r_free)
{
  return rna_id_itemf(r_free, C ? (ID *)CTX_data_main(C)->action.first : nullptr, true);
}
#endif

const EnumPropertyItem *RNA_collection_itemf(bContext *C,
                                             PointerRNA * /*ptr*/,
                                             PropertyRNA * /*prop*/,
                                             bool *r_free)
{
  return rna_id_itemf(
      r_free, C ? (ID *)CTX_data_main(C)->collections.first : nullptr, false, nullptr, nullptr);
}
const EnumPropertyItem *RNA_collection_local_itemf(bContext *C,
                                                   PointerRNA * /*ptr*/,
                                                   PropertyRNA * /*prop*/,
                                                   bool *r_free)
{
  return rna_id_itemf(
      r_free, C ? (ID *)CTX_data_main(C)->collections.first : nullptr, true, nullptr, nullptr);
}

const EnumPropertyItem *RNA_image_itemf(bContext *C,
                                        PointerRNA * /*ptr*/,
                                        PropertyRNA * /*prop*/,
                                        bool *r_free)
{
  return rna_id_itemf(
      r_free, C ? (ID *)CTX_data_main(C)->images.first : nullptr, false, nullptr, nullptr);
}
const EnumPropertyItem *RNA_image_local_itemf(bContext *C,
                                              PointerRNA * /*ptr*/,
                                              PropertyRNA * /*prop*/,
                                              bool *r_free)
{
  return rna_id_itemf(
      r_free, C ? (ID *)CTX_data_main(C)->images.first : nullptr, true, nullptr, nullptr);
}

const EnumPropertyItem *RNA_scene_itemf(bContext *C,
                                        PointerRNA * /*ptr*/,
                                        PropertyRNA * /*prop*/,
                                        bool *r_free)
{
  return rna_id_itemf(
      r_free, C ? (ID *)CTX_data_main(C)->scenes.first : nullptr, false, nullptr, nullptr);
}
const EnumPropertyItem *RNA_scene_local_itemf(bContext *C,
                                              PointerRNA * /*ptr*/,
                                              PropertyRNA * /*prop*/,
                                              bool *r_free)
{
  return rna_id_itemf(
      r_free, C ? (ID *)CTX_data_main(C)->scenes.first : nullptr, true, nullptr, nullptr);
}
const EnumPropertyItem *RNA_scene_without_sequencer_scene_itemf(bContext *C,
                                                                PointerRNA * /*ptr*/,
                                                                PropertyRNA * /*prop*/,
                                                                bool *r_free)
{
  Scene *sequencer_scene = C ? CTX_data_sequencer_scene(C) : nullptr;
  return rna_id_itemf(r_free,
                      C ? (ID *)CTX_data_main(C)->scenes.first : nullptr,
                      false,
                      rna_id_enum_filter_single,
                      sequencer_scene);
}
const EnumPropertyItem *RNA_movieclip_itemf(bContext *C,
                                            PointerRNA * /*ptr*/,
                                            PropertyRNA * /*prop*/,
                                            bool *r_free)
{
  return rna_id_itemf(
      r_free, C ? (ID *)CTX_data_main(C)->movieclips.first : nullptr, false, nullptr, nullptr);
}
const EnumPropertyItem *RNA_movieclip_local_itemf(bContext *C,
                                                  PointerRNA * /*ptr*/,
                                                  PropertyRNA * /*prop*/,
                                                  bool *r_free)
{
  return rna_id_itemf(
      r_free, C ? (ID *)CTX_data_main(C)->movieclips.first : nullptr, true, nullptr, nullptr);
}

const EnumPropertyItem *RNA_mask_itemf(bContext *C,
                                       PointerRNA * /*ptr*/,
                                       PropertyRNA * /*prop*/,
                                       bool *r_free)
{
  return rna_id_itemf(
      r_free, C ? (ID *)CTX_data_main(C)->masks.first : nullptr, false, nullptr, nullptr);
}
const EnumPropertyItem *RNA_mask_local_itemf(bContext *C,
                                             PointerRNA * /*ptr*/,
                                             PropertyRNA * /*prop*/,
                                             bool *r_free)
{
  return rna_id_itemf(
      r_free, C ? (ID *)CTX_data_main(C)->masks.first : nullptr, true, nullptr, nullptr);
}

/** \} */
