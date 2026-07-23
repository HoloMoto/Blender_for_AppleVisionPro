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

## Muse Pen roadmap (Logitech Muse)

Ultimate goal: **sculpt in Immersive Space** with bidirectional sync
(Immersive edits update the 2D Blender window, and vice versa).

| Phase | Goal | Status |
|-------|------|--------|
| **1** | Muse as Immersive cursor (tip anchor + visual) | Done |
| **2** | Muse tip → 2D View3D sculpt (tablet projection MVP) | Done (MVP) |
| **3** | Immersive-native mesh hit / dab (no 2D projection) | Planned |
| **4** | Multi Vision Pro experience share (Multiuser-inspired) | Done (MVP) |

### Phase 4 — Vision Multiuser (MVP)

Inspired by [Blender Multiuser](https://extensions.blender.org/add-ons/multi-user/)
(host / join / collaborative session), scoped to Immersive experience sharing:

| Role | Behavior |
|------|----------|
| **Idle** (default) | Existing single-user Immersive path unchanged |
| **Host** | Advertises Multipeer session; broadcasts Immersive USDZ on mesh refresh; sends Muse tip presence |
| **Guest** | Joins nearby host; loads shared USDZ into Immersive; shows remote Muse cursors; sends own presence |

**UI**
- Immersive hand / ornament menu: **Host / Join / Leave**
- Addon **Vision Multiuser** (`scripts/addons_core/vision_multiuser`): Sidebar → **Vision Share**
- Operators: `wm.ios_immersive_multiuser_{host,join,leave}`

**Transport:** MultipeerConnectivity service `_blender-imu._tcp` (local network).
Requires `NSLocalNetworkUsageDescription` + Bonjour entitlement in Info.plist.

**Not in MVP (later):** full datablock replication like Multiuser; bidirectional mesh edit merge.
Host remains authoritative for the shared USD scene.

### Phase 2 MVP (current)

Immersive Muse tip/pressure is sampled in Swift, queued via
`WM_IOS_immersive_muse_sample`, projected into the active View3D with
`ED_view3d_project_float_global`, then injected as GHOST stylus tablet
cursor/button events so the existing `SCULPT_OT_brush_stroke` path runs.
Immersive mesh appearance updates through the same debounce USD reload used
for edit mode (extended to sculpt; reload prefers tip-up).

**How to try:** put the active object in Sculpt Mode, open Immersive Space
(Travel Mode off), press and drag the Muse tip. Brush dabs appear in the 2D
View3D; after releasing the tip, Immersive USD refreshes shortly after.

Phase 1 uses `GameController` (`GCStylus`) + RealityKit
`AnchoringComponent.AccessoryAnchoringSource` / `SpatialTrackingSession`
(`.accessory`). Requires `NSAccessoryTrackingUsageDescription`.
