# Immersive Space — Vision Pro only (`immersive-space` branch)

This branch is **Apple Vision Pro / visionOS Immersive Space** only.
iPad camera AR lives on **`ipad-mr`**.

Add-on platform API (`blender_visionos` hands / capabilities):
see **[VISIONOS_API.md](./VISIONOS_API.md)**.

## Immersive sidebar — scene sync (performance)

View3D / Image Editor → **N-panel → Immersive → 空間シーン同期**:

| Option | Default | Notes |
|--------|---------|-------|
| **物体移動も空間へ反映** | Off | Lightweight position sync for up to 96 visible meshes (**no USD**). New objects / mesh edits still go through USD. |
| **空間更新間隔** | 0.35 s | Debounce for USDZ re-export (structure / sculpt / geo). Lower = snappier / heavier. |

Tip-up during sculpt stays near-immediate (~0.05 s) even when the interval is longer.

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
| **3** | Immersive-native mesh hit / dab (no 2D projection) | Done (TF-159, spatial sculpt) |
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

### Phase 3 — spatial sculpt (TF-159)

The Muse tip (or the hand pen) drives Blender's own sculpt stroke system in 3D:

- `sculpt_paint::spatial::stroke_sample()` runs `SCULPT_OT_brush_stroke` callbacks
  (`paint_stroke_spatial_step` / `paint_stroke_spatial_end`) with a world-space override:
  the ray is tip ± pen direction × reach, radius is in world units
  (Hand Menu radius ÷ view scale), view normal = −pen direction.
  Every brush asset, symmetry, auto-masking and undo (one step per stroke) work as in the
  desktop build. Direction falls back from pen aim → viewer→tip → region view.
- Spacing is world-space (brush spacing % × radius, ≤ 8 sub-steps per sample);
  grab-like / anchored brushes take one step per sample.
- Pie / knock brushes map to real assets: Draw, Clay Strips, Grab, Smooth, Inflate/Deflate
  (Deflate = invert stroke), Mask, Crease Polish, Layer, Snake Hook, Draw Sharp, Flatten/Contrast.
- Hand Menu **Engine** toggle keeps the previous custom deform path (`legacy`).
- Live Mesh: per-object cache; only changed vertex ranges are sent
  (`GHOST_IOS_immersive_live_mesh_update` → `LowLevelMesh` in-place write), full frame as fallback.
  Sculpt meshes ≥ 150k verts skip the tip-up USD rebuild (live mesh only).
- Near-mesh distance uses the sculpt BVH (`nearest_vertex_distance`) instead of a full scan.
- Spatial UI: brush preview ring at the surface hit (normal + strength), two-hand hold
  (move / rotate / scale the scene), Hand Menu **1:1 ↔ desk** scale toggle around the view
  center, and a peace pose (index + middle extended) that turns window 1-finger drag into pan
  (`blender_ios_hand_pose` → `set_drag_pan_override`, RealityKit joint anchors only).
  Hold is disabled while spectator alignment is locked.

### Phase 2 MVP (superseded by Phase 3 for Sculpt)

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
