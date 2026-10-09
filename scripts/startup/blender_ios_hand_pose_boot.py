# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Peace-sign hand pose: one-finger viewport drags pan while held (Immersive hand tracking)."""


def register():
    try:
        import blender_ios_hand_pose

        blender_ios_hand_pose.register()
    except Exception as exc:
        print("blender_ios_hand_pose register failed:", exc)


def unregister():
    try:
        import blender_ios_hand_pose

        blender_ios_hand_pose.unregister()
    except Exception:
        pass
