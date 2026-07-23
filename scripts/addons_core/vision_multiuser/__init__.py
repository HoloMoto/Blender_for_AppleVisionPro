# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

bl_info = {
    "name": "Vision Multiuser",
    "author": "Blender Vision Pro / HoloMoto",
    "version": (0, 1, 0),
    "blender": (4, 2, 0),
    "location": "3D Viewport > Sidebar > Vision Share",
    "description": (
        "Share Immersive Space across multiple Apple Vision Pro devices "
        "(inspired by Blender Multiuser host/join). Single-user Immersive "
        "editing stays unchanged until you Host or Join a session."
    ),
    "category": "3D View",
    "support": "COMMUNITY",
    "doc_url": "",
}

if "bpy" in locals():
    import importlib
    importlib.reload(ui)
    importlib.reload(operators)
else:
    from . import ui, operators

import bpy


def register():
    operators.register()
    ui.register()


def unregister():
    ui.unregister()
    operators.unregister()
