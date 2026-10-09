/* SPDX-FileCopyrightText: 2008 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup editors
 */

#pragma once

#include <cstddef>

struct Depsgraph;
struct Main;
struct Mesh;
struct Object;
struct RegionView3D;
struct ReportList;
struct Scene;
struct UndoType;
struct UndoStep;
struct bContext;
struct wmKeyConfig;
struct wmOperator;

namespace blender::ed::sculpt_paint {

void object_sculpt_mode_enter(Main &bmain,
                              Depsgraph &depsgraph,
                              Scene &scene,
                              Object &ob,
                              bool force_dyntopo,
                              ReportList *reports);
void object_sculpt_mode_enter(bContext *C, Depsgraph &depsgraph, ReportList *reports);
void object_sculpt_mode_exit(Main &bmain, Depsgraph &depsgraph, Scene &scene, Object &ob);
void object_sculpt_mode_exit(bContext *C, Depsgraph &depsgraph);

/* `sculpt.cc` */

/**
 * Checks if the currently active Sculpt Mode on the object is targeting a locked shape key,
 * and produces an error message if so (unless \a reports is null).
 * \return true if the shape key was locked.
 */
bool report_if_shape_key_is_locked(const Object &ob, ReportList *reports);

void operatortypes_sculpt();

void keymap_sculpt(wmKeyConfig *keyconf);

/**
 * Spatial (visionOS Immersive) strokes: drive the regular sculpt brush engine from a 3D tool
 * position instead of window events. The stroke location comes from a ray along the tool
 * direction through the tip, the brush radius is given in world units, and grab-type brushes
 * follow the tip in 3D. All brushes, brush settings, symmetry and undo apply as on the desktop.
 * The active object must be in Sculpt Mode and the context must have a 3D viewport region.
 */
namespace spatial {

struct ToolSample {
  /** World space tool tip. */
  float tip[3];
  /** World space unit direction the tool points into the surface (zero when unknown). */
  float dir[3];
  /** World distance searched behind and beyond the tip along `dir`. */
  float reach;
  /** World space brush radius. */
  float radius;
  float pressure;
  /** Region coordinates for screen-space stroke features (projection of the tip). */
  float mval[2];
  /** #BrushStrokeMode. */
  int stroke_mode;
};

/** Begin or continue the stroke. Returns true while the stroke is applying to the mesh. */
bool stroke_sample(bContext *C, const ToolSample &sample);
void stroke_end(bContext *C);
bool stroke_active();
/** World space surface point and normal under the tool, as the brush would see it. */
bool cursor_sample(bContext *C, const ToolSample &sample, float r_location[3], float r_normal[3]);
/** World space distance from `point` to the nearest sculpt vertex, or a negative value. */
float nearest_vertex_distance(const Depsgraph &depsgraph,
                              Object &ob,
                              const float point[3],
                              float max_distance);

}  // namespace spatial

/* `sculpt_transform.cc` */

void update_modal_transform(bContext *C, Object &ob);
void cancel_modal_transform(bContext *C, Object &ob);
void init_transform(bContext *C, Object &ob, const float mval_fl[2], const char *undo_name);
void end_transform(bContext *C, Object &ob);

/* `sculpt_undo.cc` */

namespace undo {

void register_type(UndoType *ut);

/**
 * Pushes an undo step using the operator name. This is necessary for
 * redo panels to work; operators that do not support that may use
 * #geometry_begin_ex instead if so desired.
 */
void geometry_begin(const Scene &scene, Object &ob, const wmOperator *op);
void geometry_begin_ex(const Scene &scene, Object &ob, const char *name);
void geometry_end(Object &ob);

/**
 * Undo for changes happening on a base mesh for multires sculpting.
 * if there is no multi-res sculpt active regular undo is used.
 */
void push_multires_mesh_begin(bContext *C, const char *str);
void push_multires_mesh_end(bContext *C, const char *str);

size_t step_memory_size_get(UndoStep *step);

}  // namespace undo

namespace face_set {

int find_next_available_id(Object &object);
void initialize_none_to_id(Mesh *mesh, int new_id);
int active_update_and_get(bContext *C, Object &ob, const float mval_fl[2]);

}  // namespace face_set

/**
 * Fills the object's active color attribute layer with the fill color.
 *
 * \param only_selected: Limit the fill to selected faces or vertices.
 *
 * \return #true if successful.
 */
bool object_active_color_fill(Object &ob, const float fill_color[4], bool only_selected);

/**
 * Fully replace the sculpt mesh with a mesh outside of #Main. This implements various checks to
 * avoid pushing full geometry-type undo steps when possible, allowing for better performance.
 *
 * \warning To avoid false negatives when detecting mesh changes, it is critical that the caller
 * adds an owner to the attribute data arrays before modifying the original object's mesh. This
 * allows constant time checks for whether the mesh has changed.
 */
void store_mesh_from_eval(const wmOperator &op,
                          const Scene &scene,
                          const Depsgraph &depsgraph,
                          const RegionView3D *rv3d,
                          Object &object,
                          Mesh *new_mesh);

}  // namespace blender::ed::sculpt_paint
