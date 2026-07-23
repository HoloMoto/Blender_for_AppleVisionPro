# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""N-panel UI inspired by Blender Multiuser host/join workflow."""

import bpy


class VISION_PT_multiuser_share(bpy.types.Panel):
    bl_label = "Vision Share"
    bl_idname = "VISION_PT_multiuser_share"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Vision Share"

    def draw(self, context):
        layout = self.layout
        prefs = context.preferences.addons.get(__package__)
        display_name = ""
        if prefs is not None and hasattr(prefs, "preferences"):
            display_name = getattr(prefs.preferences, "display_name", "")

        col = layout.column(align=True)
        col.label(text="Immersive Multiuser", icon='WORLD')
        col.label(text="Host / Join nearby Vision Pros")
        col.separator()

        box = layout.box()
        box.label(text="Session", icon='NETWORK_DRIVE')
        row = box.row(align=True)
        op = row.operator("vision.multiuser_host", text="Host", icon='PLAY')
        op.display_name = display_name
        op = row.operator("vision.multiuser_join", text="Join", icon='IMPORT')
        op.display_name = display_name
        box.operator("vision.multiuser_leave", text="Leave", icon='QUIT')

        help_box = layout.box()
        help_box.label(text="How it works", icon='INFO')
        help_box.label(text="• Host broadcasts Immersive USD")
        help_box.label(text="• Guests load the shared scene")
        help_box.label(text="• Muse tips appear as remote cursors")
        help_box.label(text="• No session = single-user unchanged")


class VisionMultiuserPreferences(bpy.types.AddonPreferences):
    bl_idname = __package__

    display_name: bpy.props.StringProperty(
        name="Display Name",
        description="Name shown to other Vision Pro users",
        default="",
        maxlen=63,
    )

    def draw(self, context):
        layout = self.layout
        layout.prop(self, "display_name")


classes = (
    VisionMultiuserPreferences,
    VISION_PT_multiuser_share,
)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)
