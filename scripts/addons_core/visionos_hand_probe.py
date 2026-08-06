# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Example Vision Pro add-on: poll hand tips and print when Immersive is active.

Enable from Preferences → Add-ons. Open Immersive Space, then watch the
Info / System Console (or run the operator).
"""

bl_info = {
    "name": "VisionOS Hand Probe (Example)",
    "author": "Blender Vision Pro",
    "version": (0, 1, 0),
    "blender": (4, 2, 0),
    "location": "View3D → Sidebar → VisionOS",
    "description": "Example add-on using blender_visionos.hands platform API",
    "category": "Development",
    "support": "COMMUNITY",
}

import bpy


class VISIONOS_OT_hand_probe(bpy.types.Operator):
    bl_idname = "visionos.hand_probe"
    bl_label = "Probe Hands Once"
    bl_description = "Print one hand snapshot via blender_visionos"

    def execute(self, context):
        try:
            import blender_visionos as vision
        except Exception as exc:
            self.report({'ERROR'}, f"blender_visionos missing: {exc}")
            return {'CANCELLED'}

        if not vision.available():
            self.report({'WARNING'}, "Not a Vision Pro host build")
            return {'CANCELLED'}

        caps = vision.capabilities()
        snap = vision.hands.snapshot()
        msg = (
            f"caps={sorted(caps)} ok={snap.ok} immersive={snap.immersive_active} "
            f"L={snap.left.tracked} R={snap.right.tracked}"
        )
        if snap.right.tracked:
            t = snap.right.index_tip
            msg += f" R.index=({t.x:.3f},{t.y:.3f},{t.z:.3f})"
        print("[visionos_hand_probe]", msg)
        self.report({'INFO'}, msg[:256])
        return {'FINISHED'}


class VISIONOS_OT_hand_watch(bpy.types.Operator):
    """Modal timer that polls hands ~10 Hz (example live loop)."""

    bl_idname = "visionos.hand_watch"
    bl_label = "Watch Hands (modal)"

    _timer = None

    def modal(self, context, event):
        if event.type in {'RIGHTMOUSE', 'ESC'}:
            self.cancel(context)
            return {'CANCELLED'}
        if event.type == 'TIMER':
            import blender_visionos as vision
            snap = vision.hands.snapshot()
            if snap.right.tracked:
                t = snap.right.index_tip
                context.workspace.status_text_set(
                    f"VisionOS R.index {t.x:.2f} {t.y:.2f} {t.z:.2f} pinch={snap.right.pinch:.2f}"
                )
            else:
                context.workspace.status_text_set("VisionOS hands: waiting (open Immersive)")
        return {'PASS_THROUGH'}

    def execute(self, context):
        import blender_visionos as vision
        if not vision.available():
            self.report({'WARNING'}, "Not a Vision Pro host build")
            return {'CANCELLED'}
        wm = context.window_manager
        self._timer = wm.event_timer_add(0.1, window=context.window)
        wm.modal_handler_add(self)
        return {'RUNNING_MODAL'}

    def cancel(self, context):
        wm = context.window_manager
        if self._timer is not None:
            wm.event_timer_remove(self._timer)
            self._timer = None
        context.workspace.status_text_set(None)


class VISIONOS_PT_hand_probe(bpy.types.Panel):
    bl_label = "VisionOS"
    bl_idname = "VISIONOS_PT_hand_probe"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "VisionOS"

    def draw(self, context):
        layout = self.layout
        try:
            import blender_visionos as vision
            layout.label(text="Platform OK" if vision.available() else "Not Vision host")
            layout.label(text=", ".join(sorted(vision.capabilities())) or "(no caps)")
        except Exception:
            layout.label(text="blender_visionos missing")
        layout.operator("visionos.hand_probe")
        layout.operator("visionos.hand_watch")


classes = (
    VISIONOS_OT_hand_probe,
    VISIONOS_OT_hand_watch,
    VISIONOS_PT_hand_probe,
)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
