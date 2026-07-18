<!--
Keep this document short & concise,
linking to external resources instead of including content in-line.
-->

Blender for Apple Vision Pro
============================

Unofficial port of [Blender](https://www.blender.org) for **visionOS**, **iOS**, and **iPadOS**.

This repository tracks HoloMoto's Apple-platform work on top of upstream Blender source.
It is **not** affiliated with or maintained by the Blender Foundation.

Status
------

Experimental. Usable for development and testing on device; not a release build.

Demo on Vision Pro
------------------

Latest on-device behavior (visionOS):

[![Vision Pro demo](https://img.youtube.com/vi/7AkiuEGJ1lk/hqdefault.jpg)](https://youtu.be/7AkiuEGJ1lk)

Recent platform work includes:

- visionOS / iOS / iPadOS build and packaging
- USD / USDZ import and export
- Preferences and file-picker UI on iOS
- Vision Pro Bluetooth mouse input (in progress)
- Cycles Metal GPU on Apple Silicon

Requirements
------------

- **macOS** with **Xcode** (visionOS / iOS SDK; device builds only — simulator libs are not used here)
- **Apple Developer account** (code signing for physical devices)
- **CMake** and **Ninja** (or Xcode generator)
- Prebuilt Blender libraries: `lib/ios_arm64` and `lib/macos_arm64` (see Setup below — **not included in this repo**)
- See upstream [build documentation](https://developer.blender.org/docs/handbook/building_blender/) for general Blender build concepts

What is (and is not) in this repository
---------------------------------------

This repo is a **source snapshot** of the Apple-platform port. It does **not** include:

- Prebuilt dependency libraries (`lib/ios_arm64`, `lib/macos_arm64` — roughly 2 GB combined)
- A built `Blender.app` ready to install
- Personal code-signing settings (Team ID, bundle identifier)

The `release/datafiles/*.blend` and `splash.png` files **are** included in this repo (they are normally Git LFS in upstream Blender). If they are missing after clone, see Setup step 3.

Cloning alone is **not** enough to run Blender on a device. You must obtain the libraries, configure, build, and deploy from Xcode.

Setup (new Mac or second machine)
---------------------------------

### 1. Clone this repository

```bash
git clone -b ios git@github.com:HoloMoto/Blender_for_AppleVisionPro.git blender_fresh
cd blender_fresh
```

### 2. Obtain prebuilt libraries (choose one method)

**Option A — `make update` (recommended if versions match upstream)**

From the cloned tree, run Blender's library checkout (requires Git LFS):

```bash
make update
```

This should populate `lib/ios_arm64` and `lib/macos_arm64` under the source root.

**Option B — copy from an existing build machine**

Copy these folders from a machine that already builds this port:

- `lib/ios_arm64` (~1 GB)
- `lib/macos_arm64` (~1 GB)

Place them at `blender_fresh/lib/`. A symlink is fine, for example:

```bash
ln -s /path/to/lib/ios_arm64 lib/ios_arm64
ln -s /path/to/lib/macos_arm64 lib/macos_arm64
```

Library versions must match the Blender source revision in this branch.

### 3. Obtain embedded datafiles (required for `bf_editor_datafiles`)

The iOS build embeds these files via `datatoc` during compile:

- `release/datafiles/startup.blend`
- `release/datafiles/preview.blend`
- `release/datafiles/preview_grease_pencil.blend`
- `release/datafiles/splash.png`

Upstream Blender stores them in **Git LFS**. If Xcode fails with:

`Unable to open input .../release/datafiles/preview.blend`

the files are missing. Fix with one of:

**Option A — copy from a working build machine**

```bash
# On the machine that already builds successfully:
scp release/datafiles/{startup.blend,preview.blend,preview_grease_pencil.blend,splash.png} \
    other-mac:~/blender_fresh/release/datafiles/
```

**Option B — fetch from a full upstream Blender checkout**

```bash
# In a separate official blender.git clone with Git LFS installed:
git lfs pull
cp /path/to/blender/release/datafiles/{startup.blend,preview.blend,preview_grease_pencil.blend,splash.png} \
   release/datafiles/
```

### 4. Build macOS host tools (first time only)

iOS cross-builds need host tools (e.g. `datatoc`, `glsl_preprocess`). Build them in a separate directory:

```bash
mkdir -p ../build_darwin_tools && cd ../build_darwin_tools
cmake ../blender_fresh -DCMAKE_BUILD_TYPE=Release
cmake --build . --target datatoc glsl_preprocess -j8
```

Note the output path, e.g. `../build_darwin_tools/bin` — you will pass it as `BLENDER_IOS_HOST_TOOLS_DIR`.

An `APPLE_TARGET_DEVICE=ios` build deploys to Vision Pro in **iPad compatibility mode** and **cannot** open Immersive Space. Use a native visionOS build (below).

### 5. Configure the iOS build

```bash
mkdir -p ../build_ios_fresh && cd ../build_ios_fresh
cmake ../blender_fresh \
  -G Xcode \
  -DAPPLE_TARGET_DEVICE=ios \
  -DBLENDER_IOS_DEVELOPMENT_TEAM=YOUR_10_CHAR_TEAM_ID \
  -DBLENDER_IOS_BUNDLE_ID=com.yourdomain.blenderios \
  -DBLENDER_IOS_HOST_TOOLS_DIR=/absolute/path/to/build_darwin_tools/bin
```

Replace `YOUR_10_CHAR_TEAM_ID` with your Apple Developer Team ID and choose a unique bundle ID.

### 6. Build and deploy

```bash
cmake --build . --target blender -j8
```

Output: `build_ios_fresh/bin/Debug/Blender.app`

### 5b. Configure the visionOS build (Vision Pro Immersive Space)

Branch **`immersive-space`** only. Requires Xcode visionOS SDK and **`lib/visionos_arm64`**
(visionOS-native prebuilts — do not reuse `lib/ios_arm64` dylibs).

**Step 1 — Build visionOS dependencies** (first time; several hours):

```bash
# Homebrew build tools (once)
brew install autoconf automake bison dos2unix libtool meson ninja pkg-config yasm
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/libtool/libexec/gnubin:/opt/homebrew/bin:$PATH"

cd blender_fresh
# macOS host tools required for cross-compiling visionOS deps
make deps
# visionOS libraries → lib/visionos_arm64
make deps visionos
```

**Step 2 — Configure and build Blender:**

```bash
mkdir -p ../build_visionos && cd ../build_visionos
cmake ../blender_fresh \
  -G Xcode \
  -DAPPLE_TARGET_DEVICE=visionos \
  -DWITH_VISIONOS_IMMERSIVE_SPACE=ON \
  -DBLENDER_IOS_DEVELOPMENT_TEAM=YOUR_10_CHAR_TEAM_ID \
  -DBLENDER_IOS_BUNDLE_ID=com.yourdomain.blendervision \
  -DBLENDER_IOS_HOST_TOOLS_DIR=/absolute/path/to/build_darwin_tools/bin
cmake --build . --target blender -j8
```

Entry: **Window → Open Immersive Space** (exports scene to USDZ, opens RealityKit Immersive Space).

- Open the generated Xcode project or deploy the `.app` to a **physical** Vision Pro / iPad / iPhone.
- Remove any older Blender install on the device before testing a new build.
- If Xcode **Run** crashes with `PointerUI` / backtrace errors, launch from the home-screen icon instead, or disable **Enable backtrace recording** in the scheme's Run options.

### 7. USD / USDZ export on device

Exported files are written to **Files app → On My iPad / iPhone → Blender → Exports** (no system save picker).

Values you must supply locally
------------------------------

| Setting | Description |
|---------|-------------|
| `BLENDER_IOS_DEVELOPMENT_TEAM` | 10-character Team ID from Apple Developer |
| `BLENDER_IOS_BUNDLE_ID` | Unique app ID (e.g. `com.example.blenderios`) |
| `BLENDER_IOS_HOST_TOOLS_DIR` | Path to macOS host tools `bin` directory |
| `lib/ios_arm64` | Not in Git — `make update` or copy from another Mac |
| `lib/macos_arm64` | Not in Git — same as above |
| Xcode | visionOS / iOS SDK installed (device SDK) |

**Do not push** to the official `github.com/blender/blender` repository. This fork is published at [HoloMoto/Blender_for_AppleVisionPro](https://github.com/HoloMoto/Blender_for_AppleVisionPro) only.

Build (overview)
----------------

1. Complete **Setup** above (libraries + host tools + CMake configure).
2. Build the `blender` target for `iphoneos`.
3. Deploy `Blender.app` to a physical device from Xcode.

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
