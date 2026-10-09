<!--
Keep this document short & concise,
linking to external resources instead of including content in-line.
-->

Blender for Apple Vision Pro
============================

Unofficial port of [Blender](https://www.blender.org) **5.0** for **visionOS** (Apple Vision Pro),
with an **iPadOS spectator** companion.

This repository tracks HoloMoto's Apple-platform work on top of upstream Blender source.
It is **not** affiliated with or maintained by the Blender Foundation.

Research context: how a full desktop DCC changes the creative environment when it runs
natively in spatial computing (evaluated with professional sculptors).

Status
------

| | |
|---|---|
| Track | **Blender 5.0 line** (marketing `5.0.1`) |
| Branch | **`immersive-space`** (remote `visionpro` → [HoloMoto/Blender_for_AppleVisionPro](https://github.com/HoloMoto/Blender_for_AppleVisionPro)) |
| Latest TestFlight (Vision Pro) | **158** — Nomad-style touch navigation in the 3D Viewport (two-finger pan, pinch zoom, one-finger orbit on empty space); includes 157 Preferences persistence |
| 5.3 line | Paused (`immersive-space-53`). Not shipped until it launches as reliably as 5.0 |

Experimental. Usable for development and testing on device; not a release build.

Demo on Vision Pro
------------------

[![Vision Pro demo](https://img.youtube.com/vi/7AkiuEGJ1lk/hqdefault.jpg)](https://youtu.be/7AkiuEGJ1lk)

Features (visionOS)
-------------------

**Immersive Space (RealityKit)**

- Scene mirror into an Immersive Space (USDZ) with object visibility honoring `hide_viewport` / `hide_render`
- **Live Mesh Bridge**: depsgraph-evaluated meshes streamed directly to RealityKit `MeshResource`
  (USD as fallback); Sculpt / Edit updates follow while the pen tip is down
- Timeline playback drives Immersive refresh (animation via USD keeps materials and normals)
- World Mesh (scene reconstruction) as tiled, session-accumulated objects; Sample Y / Hand Pickup physics

**Input**

- **Logitech Muse** spatial pen: pressure sculpting, near-mesh brush switching,
  far-from-mesh secondary button opens a **brush pie menu**
- Hand Menu (shown only when the palm faces the user), hand tracking API for add-ons
- **Nomad-style touch navigation** in the window 3D Viewport (finger input only):
  two-finger drag pans, pinch zooms, one-finger drag starting on empty space orbits.
  A drag on the mesh still sculpts / selects; gizmos, taps, pen and pointer input are unchanged.
  Toggle: **View → Nomad-Style Touch Navigation** or
  **Preferences → Navigation → Orbit & Pan → Touch (Vision Pro)** (default on, saved across restarts)

**Audio**

- Speaker objects play through `AVAudioEngine` (Blender's Audaspace is unavailable on visionOS)
  with distance falloff; Ogg Vorbis is converted to PCM WAV on device (`stb_vorbis`)

**Spectator (iPad) / MRC**

- Origin alignment in Vision Pro, then mixed-reality capture stream to the iPad app over TCP
  (UDP beacon discovery + manual IP entry), RealityMixer-style compositing

**Python & add-ons**

- In-app `pip install` (pure-Python packages) from the Python Console / Text Editor ▶
- System keyboard for Text Editor / Python Console
- External add-ons from `Documents/Blender/scripts/addons` (`Files` app), Install… from
  `Documents/Blender/incoming` with chunked ZIP extraction
- Preferences are saved as soon as they change (visionOS kills apps without Blender's exit-time auto-save);
  backup + enabled add-on list in `Documents/Blender/config/`
- `blender_visionos` platform API (hands, capabilities); `print()` appears in the **Info** editor

Documentation
-------------

| Doc | Contents |
|-----|----------|
| [docs/VISIONOS_API.md](docs/VISIONOS_API.md) | Add-on platform API (`blender_visionos`) — hands, capabilities, C ABI |
| [docs/IMMERSIVE_SPACE.md](docs/IMMERSIVE_SPACE.md) | Immersive Space behavior, Muse, Multiuser MVP, build flags |

```python
import blender_visionos as vision

if vision.available():
    print(sorted(vision.capabilities()))  # e.g. hand_tracking, immersive_active
    snap = vision.hands.snapshot()        # Immersive Space must be open
    if snap.right.tracked:
        print(snap.right.index_tip, snap.right.pinch)
```

What is (and is not) in this repository
---------------------------------------

This repo is a **source snapshot** of the Apple-platform port. It does **not** include:

- Prebuilt dependency libraries (`lib/visionos_arm64`, `lib/visionos-simulator_arm64`, `lib/macos_arm64`)
- A built `Blender.app` / TestFlight archive
- Personal code-signing settings (Team ID, bundle identifier)

Third-party sources vendored for visionOS: `extern/RealityMixerVisionPro` (MIT),
`extern/SwiftSocket` (BSD-3-Clause), `intern/ghost/intern/immersive/stb_vorbis.c` (public domain / MIT).

Building for Vision Pro
-----------------------

### Requirements

- macOS on Apple Silicon, **Xcode** with the visionOS SDK (device + Simulator)
- Apple Developer account (code signing)
- CMake, Ninja, Homebrew build tools for dependencies

### 1. Clone

```bash
git clone -b immersive-space git@github.com:HoloMoto/Blender_for_AppleVisionPro.git blender_50_immersive
cd blender_50_immersive
```

`release/datafiles/*.blend` and `splash.png` are included (upstream keeps them in Git LFS).

### 2. Dependencies (`lib/`)

Build visionOS libraries once (several hours):

```bash
brew install autoconf automake bison dos2unix libtool meson ninja pkg-config yasm
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/libtool/libexec/gnubin:/opt/homebrew/bin:$PATH"
make deps            # macOS host tools
make deps visionos   # → lib/visionos_arm64
```

**Library generations must match this branch.** Device builds must link the same generation
(OpenEXR 3.2 / OIIO 3.0 / OSD 3.6 / USD 25 / OCIO 2.4) that the app frameworks ship; mixing a newer
generation (e.g. from the 5.3 tree) builds fine and passes the Simulator but **crashes on device**.
Keep `lib/visionos_arm64` pointing to a single known-good generation.

### 3. Host tools

```bash
mkdir -p ../build_darwin_tools && cd ../build_darwin_tools
cmake ../blender_50_immersive -DCMAKE_BUILD_TYPE=Release
cmake --build . --target datatoc glsl_preprocess -j
```

### 4. Configure and build

```bash
mkdir -p ../build_visionos && cd ../build_visionos
cmake ../blender_50_immersive \
  -G Xcode \
  -DAPPLE_TARGET_DEVICE=visionos \
  -DWITH_VISIONOS_IMMERSIVE_SPACE=ON \
  -DBLENDER_IOS_DEVELOPMENT_TEAM=YOUR_10_CHAR_TEAM_ID \
  -DBLENDER_IOS_BUNDLE_ID=com.yourdomain.blendervision \
  -DBLENDER_IOS_HOST_TOOLS_DIR=/absolute/path/to/build_darwin_tools/bin
xcodebuild -project Blender.xcodeproj -scheme blender -configuration Release \
  -destination generic/platform=visionOS -parallelizeTargets build
```

A separate Simulator build uses `-sdk xrsimulator` and `lib/visionos-simulator_arm64`.

### 5. Release gate (used for every TestFlight build)

1. Build **both** the device archive and a separate `xrsimulator` build (device binaries cannot run in the Simulator).
2. The bundle must contain UI assets: `icons` ≥ 100, `icons_svg` ≥ 500, `startup.blend`.
3. `simctl install` + `simctl launch` — the process must stay alive ≥ 20 s (first launch after install
   compiles Metal shaders; allow a warm-up launch).
4. Smoke-test the changed feature path in the Simulator (e.g. a Speaker + timeline playback scene for audio).
5. Treat `class method ... not found` warnings for the ObjC↔Swift bridge as build failures
   (undeclared selectors silently corrupt `float` arguments).

Entry on device: **Window → Open Immersive Space**.

Values you must supply locally
------------------------------

| Setting | Description |
|---------|-------------|
| `BLENDER_IOS_DEVELOPMENT_TEAM` | 10-character Team ID |
| `BLENDER_IOS_BUNDLE_ID` | Unique app ID |
| `BLENDER_IOS_HOST_TOOLS_DIR` | macOS host tools `bin` directory |
| `lib/visionos_arm64` | Not in Git — build with `make deps visionos` |

**Do not push** to the official `github.com/blender/blender` repository. This fork is published at
[HoloMoto/Blender_for_AppleVisionPro](https://github.com/HoloMoto/Blender_for_AppleVisionPro) only.

Upstream Blender
----------------

Blender is the free and open source 3D creation suite for modeling, rigging, animation,
simulation, rendering, compositing, motion tracking, and video editing.

- [Main website](https://www.blender.org)
- [Reference manual](https://docs.blender.org/manual/en/latest/index.html)
- [Developer handbook](https://developer.blender.org/docs/handbook/)

License
-------

Blender as a whole is licensed under the GNU General Public License, Version 3.
Individual files may have a different but compatible license.

See [blender.org/about/license](https://www.blender.org/about/license) for details.
