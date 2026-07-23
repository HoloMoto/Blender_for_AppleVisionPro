# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Operators wrapping native Immersive multiuser host/join/leave."""

import bpy


class VISION_OT_multiuser_host(bpy.types.Operator):
    bl_idname = "vision.multiuser_host"
    bl_label = "Host Immersive Session"
    bl_description = (
        "Advertise a local-network Immersive share session "
        "(nearby Vision Pros can Join)"
    )

    display_name: bpy.props.StringProperty(
        name="Display Name",
        description="Name shown to guests",
        default="",
        maxlen=63,
    )

    def execute(self, context):
        if not hasattr(bpy.ops.wm, "ios_immersive_multiuser_host"):
            self.report({'ERROR'}, "Immersive multiuser is not available in this build")
            return {'CANCELLED'}
        result = bpy.ops.wm.ios_immersive_multiuser_host(display_name=self.display_name)
        if result != {'FINISHED'}:
            self.report({'ERROR'}, "Failed to host Immersive session")
            return {'CANCELLED'}
        self.report({'INFO'}, "Hosting Immersive share session")
        return {'FINISHED'}


class VISION_OT_multiuser_join(bpy.types.Operator):
    bl_idname = "vision.multiuser_join"
    bl_label = "Join Immersive Session"
    bl_description = "Browse and join a nearby Vision Pro Immersive host"

    display_name: bpy.props.StringProperty(
        name="Display Name",
        description="Name shown to the host",
        default="",
        maxlen=63,
    )

    def execute(self, context):
        if not hasattr(bpy.ops.wm, "ios_immersive_multiuser_join"):
            self.report({'ERROR'}, "Immersive multiuser is not available in this build")
            return {'CANCELLED'}
        result = bpy.ops.wm.ios_immersive_multiuser_join(display_name=self.display_name)
        if result != {'FINISHED'}:
            self.report({'ERROR'}, "Failed to join Immersive session")
            return {'CANCELLED'}
        self.report({'INFO'}, "Joining Immersive share session")
        return {'FINISHED'}


class VISION_OT_multiuser_leave(bpy.types.Operator):
    bl_idname = "vision.multiuser_leave"
    bl_label = "Leave Immersive Session"
    bl_description = "Leave the current Immersive share session"

    def execute(self, context):
        if not hasattr(bpy.ops.wm, "ios_immersive_multiuser_leave"):
            self.report({'ERROR'}, "Immersive multiuser is not available in this build")
            return {'CANCELLED'}
        bpy.ops.wm.ios_immersive_multiuser_leave()
        self.report({'INFO'}, "Left Immersive share session")
        return {'FINISHED'}


classes = (
    VISION_OT_multiuser_host,
    VISION_OT_multiuser_join,
    VISION_OT_multiuser_leave,
)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)
