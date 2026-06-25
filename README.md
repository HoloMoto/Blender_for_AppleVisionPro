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

Recent platform work includes:

- visionOS / iOS / iPadOS build and packaging
- USD / USDZ import and export
- Preferences and file-picker UI on iOS
- Vision Pro Bluetooth mouse input (in progress)
- Cycles Metal GPU on Apple Silicon

Requirements
------------

- macOS with Xcode (device builds; simulator libs are not used here)
- CMake host tools and iOS prebuilt libraries (`lib/ios_arm64`, etc.)
- See upstream [build documentation](https://developer.blender.org/docs/handbook/building_blender/) for general Blender build concepts

Build (overview)
----------------

1. Configure an iOS build directory with `APPLE_TARGET_DEVICE=ios` and host tools.
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
