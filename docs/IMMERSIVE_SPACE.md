# Immersive Space — Vision Pro only (`immersive-space` branch)

This branch is **Apple Vision Pro / visionOS Immersive Space** only.
iPad camera AR lives on **`ipad-mr`**.

## Branch map

| Branch | Purpose |
|--------|---------|
| `immersive-space` | visionOS RealityKit `ImmersiveSpace` (this branch) |
| `ipad-mr` | iPad ARKit + SceneKit USDZ preview |

Private remote: `visionpro` → `HoloMoto/Blender_for_AppleVisionPro.git`  
Do **not** push to upstream `origin` (blender/blender).

## Behavior

- Window → **Open Immersive Space** (shown only when visionOS Immersive Space is supported)
- Exports the visible scene to a temp USDZ
- Opens SwiftUI `ImmersiveSpace` + RealityKit `RealityView`
- **No iPad ARSCNView fallback** on this branch

## Configure (required)

**Prerequisite:** `lib/visionos_arm64` from `make deps visionos` (after `make deps` for macOS host tools).

```bash
cmake -S blender_fresh -B build_visionos \
  -G Xcode \
  -DWITH_APPLE_CROSSPLATFORM=ON \
  -DAPPLE_TARGET_DEVICE=visionos \
  -DWITH_VISIONOS_IMMERSIVE_SPACE=ON \
  -DWITH_USD=ON
```

An `APPLE_TARGET_DEVICE=ios` build will compile, but Immersive Space will not open
(`GHOST_IOS_immersive_space_is_supported()` is false). Use `visionos` for device runs.

Linking iOS dylibs into a visionOS app fails (`built for 'iOS'`). Always use `lib/visionos_arm64`.

## Remaining work

1. Attach GHOST MTKView into the SwiftUI `WindowGroup`
2. Wire Blender init into the visionOS Swift `@main` path
3. ~~Dedicated `lib/visionos_arm64` when needed~~ — `make deps visionos` wired; run the build
4. Live scene refresh while Immersive Space stays open
