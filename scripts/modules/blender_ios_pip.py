# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""visionOS / iOS: writable user site-packages + in-process pip.

Desktop ``subprocess([sys.executable, "-m", "pip", ...])`` does not work in the
embedded App Store Python. Packages install into Documents and are added to
``sys.path`` at startup.

Console examples (Scripting → Python Console / Text Editor):

.. code-block:: python

    import blender_ios_pip as p
    p.status()
    ok, msg = p.install_packages(["chardet"], upgrade=True)
    print(ok, msg)
    # music21 pulls numpy/matplotlib (no visionOS wheels) — try no_deps:
    ok, msg = p.install_packages(["music21"], no_deps=True)
    print(ok, msg)
    import music21  # may still need optional deps for some features
"""

from __future__ import annotations

import importlib
import os
import sys
import zipfile
from pathlib import Path


_ENV_SITE = "BLENDER_USER_SITE_PACKAGES"


def is_apple_mobile() -> bool:
    """True on iOS / visionOS style embeds (not desktop macOS)."""
    if os.environ.get(_ENV_SITE):
        return True
    if os.environ.get("BLENDER_SYSTEM_PYTHON") and sys.platform in {"ios", "darwin"}:
        # visionOS Python often still reports darwin; prefer Documents layout.
        docs = Path.home() / "Documents"
        # Container home on device always has Documents; desktop Blender home does too,
        # so also require system python under the app Assets path.
        py = os.environ.get("BLENDER_SYSTEM_PYTHON", "")
        return "Assets" in py.replace("\\", "/")
    return sys.platform == "ios"


def site_packages_dir() -> Path:
    override = os.environ.get(_ENV_SITE)
    if override:
        return Path(override)
    return Path.home() / "Documents" / "Blender" / "python" / "site-packages"


def ensure_user_site_packages(*, create: bool = True) -> Path:
    """Create Documents site-packages and prepend it to ``sys.path``."""
    path = site_packages_dir()
    if create:
        path.mkdir(parents=True, exist_ok=True)
    path_str = str(path)
    if path_str not in sys.path:
        sys.path.insert(0, path_str)
    os.environ[_ENV_SITE] = path_str
    return path


def _try_import_pip_main():
    from pip._internal.cli.main import main as pip_main

    return pip_main


def ensure_pip(*, force_extract: bool = False) -> tuple[bool, str]:
    """Make in-process ``pip`` importable without subprocess.

    ``ensurepip.bootstrap()`` uses subprocess and fails under App Store Python.
    Extract the bundled pure-Python wheel from ``ensurepip/_bundled`` instead.
    """
    ensure_user_site_packages(create=True)
    if not force_extract:
        try:
            _try_import_pip_main()
            return True, "pip already available"
        except Exception:
            pass

    try:
        import ensurepip
    except Exception as exc:
        return False, f"ensurepip module missing: {exc}"

    bundled = Path(ensurepip.__file__).resolve().parent / "_bundled"
    if not bundled.is_dir():
        return False, f"ensurepip/_bundled missing at {bundled}"

    target = site_packages_dir()
    extracted: list[str] = []
    try:
        for whl in sorted(bundled.glob("*.whl")):
            with zipfile.ZipFile(whl) as zf:
                zf.extractall(target)
            extracted.append(whl.name)
    except Exception as exc:
        return False, f"wheel extract failed: {exc}"

    importlib.invalidate_caches()
    # Prefer freshly extracted modules over any stale failed import.
    for name in list(sys.modules):
        if name == "pip" or name.startswith("pip."):
            del sys.modules[name]

    try:
        _try_import_pip_main()
    except Exception as exc:
        return False, f"pip still not importable after extract {extracted}: {exc}"

    return True, f"extracted {', '.join(extracted)} → {target}"


def status() -> dict:
    """Return a small diagnostic dict (also prints a one-line summary)."""
    site = ensure_user_site_packages(create=True)
    pip_ok, pip_msg = ensure_pip()
    entries = sorted(p.name for p in site.iterdir()) if site.is_dir() else []
    info = {
        "site_packages": str(site),
        "pip_ok": pip_ok,
        "pip": pip_msg,
        "entries": entries[:40],
        "entry_count": len(entries),
        "sys_path0": sys.path[0] if sys.path else "",
    }
    print(
        f"blender_ios_pip: site={site} pip_ok={pip_ok} packages≈{len(entries)}",
        flush=True,
    )
    return info


def install_packages(
    packages: list[str],
    *,
    upgrade: bool = True,
    no_deps: bool = False,
) -> tuple[bool, str]:
    if not packages:
        return False, "No package names"
    ensure_user_site_packages(create=True)

    ok, msg = ensure_pip()
    if not ok:
        return False, msg
    try:
        pip_main = _try_import_pip_main()
    except Exception as exc:
        return False, f"pip not available: {exc}"

    import contextlib
    import io

    target = str(site_packages_dir())
    cmd = ["install", "--prefer-binary", "--disable-pip-version-check"]
    if upgrade:
        cmd.append("--upgrade")
    if no_deps:
        cmd.append("--no-deps")
    cmd.extend(["--target", target, *packages])

    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            code = pip_main(cmd)
    except SystemExit as exc:
        code = int(exc.code) if isinstance(exc.code, int) else 1
    except Exception as exc:
        return False, f"pip crashed: {exc}\n{buf.getvalue()}"

    text = buf.getvalue().strip()
    ensure_user_site_packages(create=False)
    importlib.invalidate_caches()
    if code == 0:
        return True, text or f"Installed {', '.join(packages)} → {target}"
    hint = ""
    low = text.lower()
    if "numpy" in low or "matplotlib" in low or "failed building wheel" in low:
        hint = (
            "\nHint: native wheels often lack visionOS builds. "
            "Retry with no_deps=True for pure-Python only, "
            "or install pure deps first (chardet, jsonpickle, …)."
        )
    return False, (text or f"pip exited with code {code}") + hint


def uninstall_packages(packages: list[str]) -> tuple[bool, str]:
    """Best-effort uninstall from the Documents target (manual delete of dist-info)."""
    if not packages:
        return False, "No package names"
    root = ensure_user_site_packages(create=True)
    removed: list[str] = []
    errors: list[str] = []
    for name in packages:
        norm = name.replace("-", "_").lower()
        matched = False
        for child in list(root.iterdir()):
            cname = child.name.lower()
            if cname == norm or cname.startswith(norm + "-") or cname.startswith(norm + "."):
                try:
                    if child.is_dir():
                        import shutil

                        shutil.rmtree(child)
                    else:
                        child.unlink()
                    removed.append(child.name)
                    matched = True
                except Exception as exc:
                    errors.append(f"{child.name}: {exc}")
        if not matched:
            # Also try dist-info / egg-info style folders.
            for child in list(root.iterdir()):
                if child.name.lower().startswith(norm) and (
                    child.name.endswith(".dist-info") or child.name.endswith(".egg-info")
                ):
                    try:
                        import shutil

                        shutil.rmtree(child)
                        removed.append(child.name)
                        matched = True
                    except Exception as exc:
                        errors.append(f"{child.name}: {exc}")
        if not matched:
            errors.append(f"not found: {name}")
    if errors and not removed:
        return False, "; ".join(errors)
    msg = f"Removed: {', '.join(removed)}" if removed else "Nothing removed"
    if errors:
        msg += " | " + "; ".join(errors)
    return True, msg


def bootstrap_at_startup() -> None:
    """Called from Blender Python init on Apple mobile builds."""
    if not is_apple_mobile():
        # Still honor explicit env override.
        if not os.environ.get(_ENV_SITE):
            return
    try:
        ensure_user_site_packages(create=True)
        ok, msg = ensure_pip()
        print(f"blender_ios_pip: user site-packages → {site_packages_dir()}", flush=True)
        print(f"blender_ios_pip: {msg}", flush=True)
        if not ok:
            print(f"blender_ios_pip: pip bootstrap incomplete", flush=True)
    except Exception as exc:
        print(f"blender_ios_pip: bootstrap failed: {exc}", flush=True)
