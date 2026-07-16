# Immersive Space (visionOS) — branch `immersive-space`

This branch targets **Apple Vision Pro Immersive Space** with RealityKit.
The iPad camera-MR path lives on branch `ipad-mr`.

## Branch map

| Branch | Purpose |
|--------|---------|
| `ipad-mr` | iPad ARKit + SceneKit USDZ preview |
| `immersive-space` | Vision Pro SwiftUI `ImmersiveSpace` + RealityKit |
| `reality-kit` | Earlier shared experiment (same tip as the split above) |

Private remote: `visionpro` → `HoloMoto/Blender_for_AppleVisionPro.git`  
Do **not** push to upstream `origin` (blender/blender).

## What landed in this scaffold

- Swift RealityKit view that loads the Blender-exported USDZ
- SwiftUI `ImmersiveSpace(id: "blender.scene.immersive")` app entry (`#if os(visionOS)`)
- ObjC/C bridge: `GHOST_Vision_*` called from the existing Window menu toggle
- CMake option `WITH_VISIONOS_IMMERSIVE_SPACE` (auto-ON when `APPLE_TARGET_DEVICE=visionos`)
- CMake device `visionos` (XROS SDK); temporarily reuses `lib/ios_arm64`

On iPad / iOS builds without the Swift Immersive Space flag, the toggle still falls back to the ARSCNView preview.

## Configure (visionOS)

```bash
cmake -S blender_fresh -B build_visionos \
  -G Xcode \
  -DWITH_APPLE_CROSSPLATFORM=ON \
  -DAPPLE_TARGET_DEVICE=visionos \
  -DWITH_VISIONOS_IMMERSIVE_SPACE=ON
```

## Remaining work

1. Attach the existing GHOST `MTKView` UIKit hierarchy into the SwiftUI `WindowGroup` (replace the placeholder root)
2. Call Blender init (`main_ios_callback` / GHOST finalize) from the visionOS Swift `@main` path
3. Dedicated `lib/visionos_arm64` prebuilts when iOS libs are insufficient
4. Mixed / progressive / full immersion controls from Blender UI
5. Live refresh of Immersive Space when the Blender scene changes
