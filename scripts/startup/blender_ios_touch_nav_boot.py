# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Nomad-style touch navigation toggle (Preferences > Navigation, 3D View > View)."""


def register():
    try:
        import blender_ios_touch_nav

        blender_ios_touch_nav.register()
    except Exception as exc:
        print("blender_ios_touch_nav register failed:", exc)


def unregister():
    try:
        import blender_ios_touch_nav

        blender_ios_touch_nav.unregister()
    except Exception:
        pass
