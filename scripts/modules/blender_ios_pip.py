# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""visionOS / iOS: writable user site-packages + in-process pip.

Desktop ``subprocess([sys.executable, "-m", "pip", ...])`` does not work in the
embedded App Store Python. Packages install into Documents and are added to
``sys.path`` at startup.

Python Console accepts shell-like lines (otherwise ``pip install`` is a SyntaxError):

    pip install music21
    python -v

You can still call the API:

.. code-block:: python

    import blender_ios_pip as p
    p.status()
    ok, msg = p.install_packages(["chardet"], upgrade=True)
    print(ok, msg)
    # music21 pulls numpy/matplotlib (no visionOS wheels) — auto no_deps + pure deps:
    ok, msg = p.install_packages(["music21"])
    print(ok, msg)
    import music21
"""

from __future__ import annotations

import importlib
import os
import ssl
import sys
import zipfile
from pathlib import Path


_ENV_SITE = "BLENDER_USER_SITE_PACKAGES"
_CERT_ENVS = ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "PIP_CERT")


def is_apple_mobile() -> bool:
    """True on iOS / visionOS style embeds (not desktop macOS)."""
    if os.environ.get(_ENV_SITE):
        return True
    home = str(Path.home())
    if "CoreSimulator" in home or "/Containers/Data/" in home:
        return True
    if os.environ.get("BLENDER_SYSTEM_PYTHON") and sys.platform in {"ios", "darwin"}:
        py = os.environ.get("BLENDER_SYSTEM_PYTHON", "")
        return "Assets" in py.replace("\\", "/")
    if sys.platform == "ios":
        return True
    exe = getattr(sys, "executable", None)
    if exe in {None, "None", ""}:
        docs = Path.home() / "Documents"
        if docs.is_dir() and (Path.home() / "tmp").is_dir():
            return True
    return False


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


def _cacert_candidates() -> list[Path]:
    here = Path(__file__).resolve().parent
    site = site_packages_dir()
    out = [
        here / "blender_ios_certs" / "cacert.pem",
        site / "certifi" / "cacert.pem",
        site / "pip" / "_vendor" / "certifi" / "cacert.pem",
    ]
    env_existing = os.environ.get("SSL_CERT_FILE", "")
    if env_existing:
        out.insert(0, Path(env_existing))
    try:
        import ensurepip

        bundled = Path(ensurepip.__file__).resolve().parent
        out.append(bundled / "_bundled" / "cacert.pem")
    except Exception:
        pass
    prefix = Path(getattr(sys, "prefix", "") or "")
    if prefix:
        out.append(prefix / "lib" / "python3.11" / "site-packages" / "certifi" / "cacert.pem")
    for entry in list(sys.path):
        p = Path(entry)
        out.append(p / "certifi" / "cacert.pem")
        out.append(p / "pip" / "_vendor" / "certifi" / "cacert.pem")
    # De-dupe while preserving order.
    seen: set[str] = set()
    unique: list[Path] = []
    for cand in out:
        key = str(cand)
        if key in seen:
            continue
        seen.add(key)
        unique.append(cand)
    return unique


def ssl_cert_path() -> Path | None:
    """Return the CA bundle path if one exists (does not set env)."""
    for cand in _cacert_candidates():
        try:
            if cand.is_file() and cand.stat().st_size > 1000:
                return cand
        except OSError:
            continue
    return None


def configure_ssl() -> Path | None:
    """Point OpenSSL / pip at a CA bundle. visionOS has no system cert store."""
    pem = ssl_cert_path()
    if pem is None:
        return None
    pem_s = str(pem)
    for key in _CERT_ENVS:
        os.environ[key] = pem_s
    try:
        ssl._create_default_https_context = lambda: ssl.create_default_context(cafile=pem_s)
    except Exception:
        pass
    return pem


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
            configure_ssl()
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

    configure_ssl()
    return True, f"extracted {', '.join(extracted)} → {target}"


def status() -> dict:
    """Return a small diagnostic dict (also prints a one-line summary)."""
    site = ensure_user_site_packages(create=True)
    pip_ok, pip_msg = ensure_pip()
    pem = configure_ssl()
    entries = sorted(p.name for p in site.iterdir()) if site.is_dir() else []
    info = {
        "site_packages": str(site),
        "pip_ok": pip_ok,
        "pip": pip_msg,
        "ssl_cert": str(pem) if pem else "",
        "entries": entries[:40],
        "entry_count": len(entries),
        "sys_path0": sys.path[0] if sys.path else "",
    }
    print(
        f"blender_ios_pip: site={site} pip_ok={pip_ok} ssl={pem or 'MISSING'} packages≈{len(entries)}",
        flush=True,
    )
    return info


def _pure_python_wheel_args() -> list[str]:
    """Force py3-none-any wheels. Host tags on visionOS look like macOS arm64."""
    return [
        "--only-binary=:all:",
        "--python-version",
        "311",
        "--implementation",
        "py",
        "--abi",
        "none",
        "--platform",
        "any",
    ]


def _run_pip_install(pip_main, cmd: list[str]) -> tuple[int, str]:
    """Run pip with a dummy sys.executable so console-script shebangs don't crash."""
    import contextlib
    import io

    buf = io.StringIO()
    saved_exe = sys.executable
    if not saved_exe:
        sys.executable = "/usr/bin/false"
    try:
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            code = pip_main(cmd)
    except SystemExit as exc:
        code = int(exc.code) if isinstance(exc.code, int) else 1
    except Exception as exc:
        return 1, f"pip crashed: {exc}\n{buf.getvalue()}"
    finally:
        sys.executable = saved_exe
    return int(code or 0), buf.getvalue().strip()


def _write_pip_last(text: str) -> None:
    try:
        path = Path.home() / "Documents" / "Blender" / "pip_last_install.txt"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text[:8000], encoding="utf-8")
    except Exception:
        pass


_NATIVE_SKIP = {
    "numpy",
    "matplotlib",
    "scipy",
    "pandas",
    "pillow",
    "pil",
    "contourpy",
    "kiwisolver",
    "cv2",
    "sklearn",
    "scikit_learn",
    "pyarrow",
    "lxml",
}


def _fill_pure_import_gaps(
    packages: list[str],
    pip_main,
    pem: Path | None,
    target: str,
) -> str:
    """After --no-deps, pull missing pure-Python imports (requests, chardet, …)."""
    notes: list[str] = []
    extra = _pure_python_wheel_args() if (is_apple_mobile() or os.environ.get(_ENV_SITE)) else []
    cert = ["--cert", str(pem)] if pem is not None else []
    for pkg in packages:
        raw = pkg.split("==")[0].split("[")[0].strip()
        if not raw or "/" in raw or raw.endswith(".whl"):
            continue
        mod = raw.replace("-", "_")
        for _ in range(12):
            importlib.invalidate_caches()
            try:
                importlib.import_module(mod)
                break
            except ModuleNotFoundError as exc:
                missing = (exc.name or "").split(".")[0]
                key = missing.lower().replace("-", "_")
                if not missing or key in _NATIVE_SKIP:
                    notes.append(f"import {mod} skipped native {missing}")
                    break
                cmd = [
                    "install",
                    "--prefer-binary",
                    "--disable-pip-version-check",
                    "--no-compile",
                    *cert,
                    *extra,
                    "--target",
                    target,
                    missing,
                ]
                code, text = _run_pip_install(pip_main, cmd)
                if code != 0:
                    notes.append(f"could not install {missing}")
                    if text:
                        notes.append(text[-400:])
                    break
                notes.append(f"also installed {missing}")
            except Exception as exc:
                notes.append(f"import {mod}: {type(exc).__name__}: {exc}")
                break
    return "\n".join(notes)


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

    pem = configure_ssl()
    target = str(site_packages_dir())
    base = ["install", "--prefer-binary", "--disable-pip-version-check", "--no-compile"]
    if upgrade:
        base.append("--upgrade")
    if no_deps:
        base.append("--no-deps")
    if pem is not None:
        base.extend(["--cert", str(pem)])

    extras: list[list[str]] = []
    if is_apple_mobile() or os.environ.get(_ENV_SITE):
        # Never fall back to macosx_* wheels — device is darwin-tagged but cannot load them.
        extras.append(_pure_python_wheel_args())
    else:
        extras.append([])

    dep_flags = [no_deps]
    if not no_deps:
        # music21 etc. pull numpy/matplotlib — no visionOS wheels.
        dep_flags.append(True)

    texts: list[str] = []
    code = 1
    used_no_deps = no_deps
    for try_no_deps in dep_flags:
        used_no_deps = try_no_deps
        cmd_base = list(base)
        if try_no_deps and "--no-deps" not in cmd_base:
            cmd_base.append("--no-deps")
        for extra in extras:
            cmd = [*cmd_base, *extra, "--target", target, *packages]
            code, text = _run_pip_install(pip_main, cmd)
            if text:
                texts.append(text)
            if code == 0:
                ensure_user_site_packages(create=False)
                importlib.invalidate_caches()
                msg = text or f"Installed {', '.join(packages)} → {target}"
                if try_no_deps and not no_deps:
                    msg += (
                        "\nNote: installed without native deps "
                        "(numpy/matplotlib have no visionOS wheels)."
                    )
                    gaps = _fill_pure_import_gaps(packages, pip_main, pem, target)
                    if gaps:
                        msg += "\n" + gaps
                _write_pip_last(msg)
                return True, msg

    ensure_user_site_packages(create=False)
    importlib.invalidate_caches()
    text = "\n".join(texts).strip()
    hint = ""
    low = text.lower()
    if pem is None and ("certificate" in low or "ssl" in low or "certifi" in low):
        hint = "\nHint: CA bundle missing (SSL_CERT_FILE). Reinstall the certifi inject."
    elif "numpy" in low or "matplotlib" in low or "failed building wheel" in low:
        hint = (
            "\nHint: native wheels often lack visionOS builds. "
            "Retry with No Dependencies for pure-Python only "
            "(music21 works that way; numpy/scipy will not)."
        )
    elif "expected str, bytes or os.PathLike object, not NoneType" in text:
        hint = "\nHint: sys.executable is None; pip script wrappers need a dummy path."
    fail = (text or f"pip exited with code {code}") + hint
    _write_pip_last(fail)
    return False, fail


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


def _smoke_paths() -> tuple[Path, Path]:
    root = Path.home() / "Documents" / "Blender"
    return root / "pip_smoke_request.txt", root / "pip_smoke_result.txt"


def maybe_run_smoke() -> None:
    """If Documents/Blender/pip_smoke_request.txt exists, install those packages.

    Simulator/CI only. The request file is deleted so a shipped build does nothing
    unless someone drops that file into Files sharing.
    """
    req, out = _smoke_paths()
    if not req.is_file():
        return
    try:
        pkgs = [
            line.strip()
            for line in req.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
    except Exception as exc:
        pkgs = []
        fail = f"request read failed: {exc}"
    else:
        fail = ""
    try:
        req.unlink(missing_ok=True)
    except Exception:
        pass
    lines: list[str] = []
    try:
        pem = configure_ssl()
        lines.append(f"ssl={pem or 'MISSING'}")
        info = status()
        lines.append(f"pip_ok={info.get('pip_ok')} pip={info.get('pip')}")
        if fail:
            lines.append(fail)
        if pkgs:
            ok, msg = install_packages(pkgs, upgrade=True)
            lines.append(f"ok={ok}")
            lines.append(msg)
            for pkg in pkgs:
                mod = pkg.split("==")[0].split("[")[0].replace("-", "_")
                if "/" in mod or mod.endswith(".whl"):
                    # Local path / wheel: skip import probe.
                    continue
                try:
                    importlib.invalidate_caches()
                    importlib.import_module(mod)
                    lines.append(f"import {mod}: OK")
                except Exception as exc:
                    lines.append(f"import {mod}: {exc}")
        else:
            lines.append("ok=0")
            lines.append("empty request")
    except Exception as exc:
        lines.append(f"ok=0")
        lines.append(f"smoke crashed: {exc}")
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    except Exception as exc:
        print(f"blender_ios_pip: smoke result write failed: {exc}", flush=True)
    print("blender_ios_pip: smoke written →", out, flush=True)


def _write_boot_note(text: str) -> None:
    for path in (
        Path.home() / "Documents" / "Blender" / "pip_bootstrap.log",
        Path.home() / "Documents" / "pip_bootstrap.log",
    ):
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a", encoding="utf-8") as handle:
                handle.write(text.rstrip() + "\n")
        except Exception:
            continue


def rewrite_console_line(line: str) -> str | None:
    """Map shell-ish console input to Python, or None to leave the line alone.

    Blender's Python Console is a REPL, so ``pip install music21`` and
    ``python -v`` are SyntaxError unless rewritten.
    """
    import re
    import shlex

    s = (line or "").strip()
    if not s:
        return None
    if s[0] in "!%":
        s = s[1:].strip()
        if not s:
            return None

    py_m = re.match(r"^(python3?|python)(?:\s+(.*))?$", s, flags=re.IGNORECASE)
    if py_m:
        rest = (py_m.group(2) or "").strip()
        if rest.lower() in {"", "-v", "-V", "--version", "version"}:
            return "import sys; print(sys.version)"
        if rest.lower() in {"-h", "--help", "help"}:
            return "print('usage: python -v')"
        return None

    pip_m = re.match(r"^(pip3?)(?:\s+(.*))?$", s, flags=re.IGNORECASE)
    if not pip_m:
        return None
    rest = (pip_m.group(2) or "").strip()
    if rest.lower() in {"", "-h", "--help", "help"}:
        return (
            "print('usage: pip install PACKAGE\\n"
            "  pip uninstall PACKAGE\\n"
            "  pip list\\n"
            "  pip --version\\n"
            "Native wheels (numpy/scipy/matplotlib) cannot install on visionOS.')"
        )
    try:
        args = shlex.split(rest)
    except ValueError:
        args = rest.split()
    if not args:
        return None
    cmd = args[0].lower()
    flags = {a for a in args if a.startswith("-")}
    pkgs = [a for a in args[1:] if not a.startswith("-")]
    no_deps = "--no-deps" in flags or "-no-deps" in flags
    if cmd in {"-v", "-V", "--version", "version"}:
        return (
            "import blender_ios_pip as _p; _p.ensure_pip(); import pip as _pip; "
            "print(getattr(_pip, '__version__', 'pip'))"
        )
    if cmd in {"list", "freeze"}:
        return (
            "import blender_ios_pip as _p; _i=_p.status(); "
            "print('\\n'.join(_i.get('entries') or []) or '(empty)')"
        )
    if cmd in {"uninstall", "remove", "rm"}:
        if not pkgs:
            return "print('usage: pip uninstall PACKAGE')"
        return (
            f"import blender_ios_pip as _p; _ok,_m=_p.uninstall_packages({pkgs!r}); print(_m)"
        )
    if cmd in {"install", "add"}:
        if not pkgs:
            return "print('usage: pip install PACKAGE')"
        return (
            f"import blender_ios_pip as _p; "
            f"_ok,_m=_p.install_packages({pkgs!r}, no_deps={no_deps}); print(_m)"
        )
    if cmd.startswith("-"):
        return None
    # `pip music21` → install
    pkgs = [cmd, *pkgs]
    return (
        f"import blender_ios_pip as _p; "
        f"_ok,_m=_p.install_packages({pkgs!r}, no_deps={no_deps}); print(_m)"
    )


def rewrite_script_source(src: str) -> str | None:
    """Rewrite shell-ish lines in a Text Editor buffer. None = run as normal Python."""
    if not src or not str(src).strip():
        return None
    lines = str(src).splitlines()
    out: list[str] = []
    changed = False
    for line in lines:
        raw = line.strip()
        if not raw or raw.startswith("#"):
            out.append(line)
            continue
        py = rewrite_console_line(raw)
        if py is None:
            out.append(line)
        else:
            out.append(py)
            changed = True
    if not changed:
        return None
    text = "\n".join(out)
    if str(src).endswith("\n"):
        text += "\n"
    return text


def bootstrap_at_startup() -> None:
    """Called from Blender Python init on Apple mobile builds."""
    req, _ = _smoke_paths()
    mobile = is_apple_mobile() or bool(os.environ.get(_ENV_SITE)) or req.is_file()
    _write_boot_note(
        f"bootstrap enter mobile={mobile} home={Path.home()} "
        f"site_env={os.environ.get(_ENV_SITE, '')} "
        f"sys_py={os.environ.get('BLENDER_SYSTEM_PYTHON', '')} "
        f"platform={sys.platform} exe={getattr(sys, 'executable', None)} "
        f"req={req.is_file()}"
    )
    if not mobile:
        return
    try:
        ensure_user_site_packages(create=True)
        pem = configure_ssl()
        ok, msg = ensure_pip()
        pem = configure_ssl() or pem
        print(f"blender_ios_pip: user site-packages → {site_packages_dir()}", flush=True)
        print(f"blender_ios_pip: {msg}", flush=True)
        print(f"blender_ios_pip: ssl_cert={pem or 'MISSING'}", flush=True)
        _write_boot_note(f"bootstrap pip_ok={ok} ssl={pem or 'MISSING'} {msg}")
        if not ok:
            print("blender_ios_pip: pip bootstrap incomplete", flush=True)
        maybe_run_smoke()
    except Exception as exc:
        print(f"blender_ios_pip: bootstrap failed: {exc}", flush=True)
        _write_boot_note(f"bootstrap failed: {exc}")
