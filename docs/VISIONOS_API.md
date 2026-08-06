# Vision OS Platform API

Add-on facing surface for **Blender on Apple Vision Pro**.

This is a **platform / host API**, not a single app feature. Native capabilities
are published through a stable C ABI and consumed from Python as
`blender_visionos`. New features land as capability bits and optional fields
(`api_version` + `struct_size`) so existing add-ons keep working.

| Layer | Location |
|-------|----------|
| C ABI | `source/blender/windowmanager/WM_ios_visionos_api.h` |
| C++ runtime | `source/blender/windowmanager/intern/wm_ios_visionos_api.cc` |
| Swift publisher | `intern/ghost/intern/immersive/BlenderVisionOSPlatform.swift` |
| Python package | `scripts/modules/blender_visionos/` |
| Example add-on | `scripts/addons_core/visionos_hand_probe.py` |

**API version:** `1` (`BLENDER_VISIONOS_API_VERSION`)

**Coordinates:** Blender world space, **meters**, **Z-up**, relative to the
Immersive world root (same mapping as Muse / Hand pen).

**Prerequisite for live samples:** Immersive Space must be open.

---

## Quick start (Python)

```python
import blender_visionos as vision

if not vision.available():
    print("Not a Vision Pro / Immersive host build")
else:
    print("api", vision.api_version)
    print("caps", sorted(vision.capabilities()))
    snap = vision.hands.snapshot()
    if snap.right.tracked:
        print("right index", snap.right.index_tip)
        print("pinch", snap.right.pinch)
```

On visionOS there is no system console. With recent builds, `print()` is routed
to the **Info** editor (see [Stdout bridge](#stdout-bridge-print-on-visionos)).

---

## Capabilities

`vision.capabilities()` → `frozenset[str]` derived from a native bitfield.

| Name | Bit | Meaning |
|------|-----|---------|
| `hand_tracking` | `1 << 0` | Hand snapshot publisher is available |
| `immersive_active` | `1 << 1` | Immersive Space is currently open |
| `realitykit_scene` | `1 << 2` | **Reserved** (spawn / scene query / world mesh) |

Always check members before using a capability:

```python
if "hand_tracking" not in vision.capabilities():
    ...
```

---

## Hands — `blender_visionos.hands`

### `snapshot() -> HandSnapshot`

Poll the latest dual-hand sample. Call from a **timer** or **modal** for live tracking (~10–60 Hz is typical).

#### `HandSnapshot`

| Field | Type | Notes |
|-------|------|-------|
| `ok` | `bool` | Snapshot call succeeded |
| `api_version` | `int` | Publisher API version |
| `timestamp` | `float` | Host clock seconds |
| `immersive_active` | `bool` | Immersive Space open |
| `left` / `right` | `Hand` | Per-hand sample |

#### `Hand`

| Field | Type | Tracking status (API v1) |
|-------|------|---------------------------|
| `tracked` | `bool` | Hand has a recent valid sample |
| `wrist` | `Vector` | **Live** |
| `palm` | `Vector` | **Live** |
| `thumb_tip` | `Vector` | **Live** |
| `index_tip` | `Vector` | **Live** |
| `middle_tip` | `Vector` | Placeholder (copies `palm` until RealityKit exposes it) |
| `ring_tip` | `Vector` | Placeholder (copies `palm`) |
| `little_tip` | `Vector` | Placeholder (copies `palm`) |
| `pinch` | `float` | Approx. thumb↔index closeness `0..1`, or `-1` if unknown |

### `is_supported() -> bool`

Convenience: `"hand_tracking" in vision.capabilities()`.

### Minimal live loop

```python
import bpy
import blender_visionos as vision

class OT_watch(bpy.types.Operator):
    bl_idname = "visionos.api_doc_watch"
    bl_label = "Watch Hands"

    _timer = None

    def modal(self, context, event):
        if event.type in {'ESC', 'RIGHTMOUSE'}:
            context.window_manager.event_timer_remove(self._timer)
            return {'CANCELLED'}
        if event.type == 'TIMER':
            snap = vision.hands.snapshot()
            if snap.right.tracked:
                t = snap.right.index_tip
                context.workspace.status_text_set(
                    f"R.index {t.x:.2f} {t.y:.2f} {t.z:.2f} pinch={snap.right.pinch:.2f}"
                )
        return {'PASS_THROUGH'}

    def execute(self, context):
        self._timer = context.window_manager.event_timer_add(0.05, window=context.window)
        context.window_manager.modal_handler_add(self)
        return {'RUNNING_MODAL'}
```

---

## C ABI (for native / ctypes)

Header: `WM_ios_visionos_api.h`

```c
int BLENDER_VISIONOS_available(void);
uint64_t BLENDER_VISIONOS_capabilities(void);
int BLENDER_VISIONOS_hand_snapshot(BLENDER_VISIONOS_HandSnapshot *out);

/* Publisher / host only — not for add-ons */
void BLENDER_VISIONOS_hand_publish(const BLENDER_VISIONOS_HandSnapshot *in);
void BLENDER_VISIONOS_set_immersive_active(int active);

/* visionOS stdout bridge */
void BLENDER_IOS_py_stdout_line(const char *line, int is_err);
```

Compatibility rules for add-on authors:

1. Call `BLENDER_VISIONOS_available()` (or `vision.available()`) first.
2. Treat unknown capability bits as “ignore”.
3. Before reading fields beyond an older known layout, check `out->struct_size`
   (Python bindings already match the current struct).

---

## Stdout bridge (`print` on visionOS)

Problem: Vision Pro has no Mac-style system console, so Text Editor `print()`
appeared to do nothing.

Solution (TestFlight build **90**+):

| Piece | Role |
|-------|------|
| `scripts/modules/blender_ios_stdout.py` | Redirect `sys.stdout` / `stderr` |
| `BLENDER_IOS_py_stdout_line` | Native emit → Info reports + device log |
| Bootstrap in `bpy_interface.cc` | Install at startup |

Look for output in the **Info** editor (report list), not a terminal window.

---

## Design principles

1. **Host, not sealed app** — ship sensors / Immersive plumbing; leave tools to add-ons and `bpy`.
2. **Capability bits** — feature presence is queryable; missing bits fail soft.
3. **ABI growth** — bump `BLENDER_VISIONOS_API_VERSION` when semantics change; append fields with `struct_size` checks.
4. **Same coordinates as Immersive tools** — Muse, hand menus, and add-ons share one world mapping.

---

## Roadmap (platform capabilities)

| Capability | Status |
|------------|--------|
| Hand tracking (wrist / palm / thumb / index + pinch) | **Shipped** (API v1) |
| Middle / ring / little tips | ABI reserved; filled from palm until OS/SDK grows |
| `print` → Info | **Shipped** (build 90+) |
| RealityKit scene spawn / query | Reserved bit only |
| World mesh / plane detection | Not started |
| Shared session hooks for add-ons | Immersive Multiuser MVP exists separately; not yet in this package |

Related Immersive behavior (Muse, Multiuser, spatial shading board) is
documented in [`IMMERSIVE_SPACE.md`](./IMMERSIVE_SPACE.md).

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `vision.available()` is false | Not a Vision / Immersive host build |
| `ok` true but hands never `tracked` | Open **Immersive Space**; keep hands in view |
| `print` invisible | Use Info editor; need stdout bridge build (90+) |
| Middle/ring/little cubes stick to palm | Expected on API v1 — placeholders |
| Import error `blender_visionos` | Scripts path / incomplete install of `scripts/modules` |

---

## License

Same as Blender (GPL-2.0-or-later for these modules / headers unless noted otherwise).
This Apple-platform port is maintained independently of the Blender Foundation.
