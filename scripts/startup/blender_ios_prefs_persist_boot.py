# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Save Preferences on change — visionOS never runs WM_exit, so nothing else writes them."""

try:
    import blender_ios_prefs_persist

    blender_ios_prefs_persist.bootstrap_at_startup()
except Exception as exc:
    try:
        from pathlib import Path

        path = Path.home() / "Documents" / "Blender" / "prefs_persist.log"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as fh:
            fh.write(f"startup blender_ios_prefs_persist_boot failed: {exc}\n")
    except Exception:
        pass


def register():
    pass


def unregister():
    pass
