# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Boot Documents/Blender/scripts as the writable add-on search path."""

try:
    import blender_ios_user_scripts

    blender_ios_user_scripts.bootstrap_at_startup()
except Exception as exc:
    try:
        from pathlib import Path

        path = Path.home() / "Documents" / "Blender" / "user_scripts_bootstrap.log"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"startup blender_ios_user_scripts_boot failed: {exc}\n", encoding="utf-8")
    except Exception:
        pass
