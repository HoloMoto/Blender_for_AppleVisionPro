/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Muse primary-button marking menu (TF-161, replaces the 154 tap-to-open pie).
 *
 * Hold the primary (select) button still for `holdSeconds` (default 5 s, Hand Menu / N-panel):
 * a progress ring grows at the pen tip, then the menu opens at the tip, facing the wearer.
 * Keep holding and move / tilt the tip toward a slice (Maya-style marking menu); release
 * selects the highlighted slice, release inside the center deadzone cancels.
 *
 * Layout: 8 compass directions (marking menus stay reliable up to 8 directions). The inner
 * ring holds the 8 primary brushes; pushing further along the same direction reaches the
 * outer ring (4 more brushes, Dyntopo, and Voxel Remesh coarse / medium / fine on the lower
 * arc).
 *
 * Short taps (< 0.3 s) near the mesh keep the knock shortcuts; any longer press that is
 * released before the threshold does nothing. Starting a stroke cancels a pending hold, and
 * strokes are suppressed while the menu is open.
 */

import RealityKit
import SwiftUI

#if os(visionOS)

  @_silgen_name("WM_IOS_immersive_hand_menu_set_brush")
  private func WM_IOS_immersive_hand_menu_set_brush(
    _ toolId: UnsafePointer<CChar>, _ kind: Int32)

  @_silgen_name("WM_IOS_immersive_hand_menu_set_dyntopo")
  private func WM_IOS_immersive_hand_menu_set_dyntopo(_ enabled: Int32)

  @_silgen_name("WM_IOS_immersive_hand_menu_remesh_preset")
  private func WM_IOS_immersive_hand_menu_remesh_preset(_ preset: Int32)

  @_silgen_name("WM_IOS_immersive_hand_menu_set_mode")
  private func WM_IOS_immersive_hand_menu_set_mode(_ mode: Int32)

  @_silgen_name("WM_IOS_immersive_get_muse_menu_hold")
  private func WM_IOS_immersive_get_muse_menu_hold() -> Float

  @_silgen_name("WM_IOS_immersive_set_muse_menu_hold")
  private func WM_IOS_immersive_set_muse_menu_hold(_ seconds: Float)

  struct BlenderImmersiveMuseMenuSlot: Identifiable, Equatable {
    let id: Int
    let title: String
    /** Muse brush kind, -1 for the Dyntopo toggle, -10/-11/-12 for Remesh coarse/medium/fine. */
    let kind: Int
    var remeshPreset: Int? { kind <= -10 && kind >= -12 ? -10 - kind : nil }
    /** 0 = up, clockwise in 45° steps (as seen by the wearer). */
    let direction: Int
    let outer: Bool
  }

  @MainActor
  final class BlenderImmersiveMuseMarkingMenu: ObservableObject {
    static let shared = BlenderImmersiveMuseMarkingMenu()

    enum Phase: Int {
      case idle = 0
      case pressing = 1
      case open = 2
    }

    enum Event: Equatable {
      case none
      /** Short press (knock tap). */
      case tap
      case opened
      case selected(Int)
      case cancelled
    }

    static let slots: [BlenderImmersiveMuseMenuSlot] = [
      .init(id: 0, title: "Draw", kind: 0, direction: 0, outer: false),
      .init(id: 1, title: "Clay", kind: 1, direction: 1, outer: false),
      .init(id: 2, title: "Smooth", kind: 3, direction: 2, outer: false),
      .init(id: 3, title: "Inflate+", kind: 4, direction: 3, outer: false),
      .init(id: 4, title: "Grab", kind: 2, direction: 4, outer: false),
      .init(id: 5, title: "Inflate−", kind: 5, direction: 5, outer: false),
      .init(id: 6, title: "Mask", kind: 6, direction: 6, outer: false),
      .init(id: 7, title: "Flatten", kind: 11, direction: 7, outer: false),
      .init(id: 8, title: "Sharp", kind: 10, direction: 0, outer: true),
      .init(id: 9, title: "Layer", kind: 8, direction: 1, outer: true),
      .init(id: 10, title: "Crease", kind: 7, direction: 2, outer: true),
      .init(id: 11, title: "Dyntopo", kind: -1, direction: 7, outer: true),
      .init(id: 12, title: "Snake", kind: 9, direction: 6, outer: true),
      /* Destructive remesh grouped on the lower outer arc, one deliberate reach past the
       * inner ring; voxel = object diagonal / 48, 96, 192. */
      .init(id: 13, title: "Remesh 粗", kind: -10, direction: 3, outer: true),
      .init(id: 14, title: "Remesh 中", kind: -11, direction: 4, outer: true),
      .init(id: 15, title: "Remesh 細", kind: -12, direction: 5, outer: true),
    ]

    @Published private(set) var phase: Phase = .idle
    /** Hold progress 0–1 (published in 5 % steps). */
    @Published private(set) var progress: Float = 0
    @Published private(set) var highlighted: Int?
    @Published private(set) var dyntopoOn = false

    /** Center deadzone radius (m): release inside cancels. */
    let deadzone: Float = 0.02
    /** Distance (m) from the center where the outer ring starts. */
    let outerRadius: Float = 0.07
    let tapMaxSeconds: TimeInterval = 0.3
    /** Progress ring stays hidden for quick taps. */
    let ringDelaySeconds: TimeInterval = 0.4

    var headProvider: (() -> SIMD3<Float>?)?

    private weak var menuRoot: Entity?
    private var pressStart: TimeInterval = 0
    private var ignoreUntilRelease = false
    private var center = SIMD3<Float>.zero
    private var right = SIMD3<Float>(1, 0, 0)
    private var up = SIMD3<Float>(0, 1, 0)
    private var toViewer = SIMD3<Float>(0, 0, 1)
    private var currentDirection: Int?
    private var currentOuter = false
    private var lastSavedHold: Float = -1

    private static let holdDefaultsKey = "BlenderMuseMenuHoldSeconds"
    static let defaultHoldSeconds: Float = 5.0

    private init() {}

    var holdSeconds: Float {
      let v = WM_IOS_immersive_get_muse_menu_hold()
      return v.isFinite && v > 0 ? v : Self.defaultHoldSeconds
    }

    func setHoldSeconds(_ seconds: Float) {
      WM_IOS_immersive_set_muse_menu_hold(seconds)
      persistHoldIfChanged()
      objectWillChange.send()
    }

    /** Native value wins once changed (N-panel); otherwise restore the saved Hand Menu value. */
    func restoreSavedHold() {
      let current = WM_IOS_immersive_get_muse_menu_hold()
      if abs(current - Self.defaultHoldSeconds) < 1.0e-4,
        let saved = UserDefaults.standard.object(forKey: Self.holdDefaultsKey) as? Double
      {
        WM_IOS_immersive_set_muse_menu_hold(Float(saved))
      }
      lastSavedHold = holdSeconds
    }

    private func persistHoldIfChanged() {
      let h = holdSeconds
      if abs(h - lastSavedHold) > 1.0e-4 {
        lastSavedHold = h
        UserDefaults.standard.set(Double(h), forKey: Self.holdDefaultsKey)
      }
    }

    /** Strokes must not reach Blender while the menu is up. */
    var suppressesDrawing: Bool { phase == .open }

    var highlightedSlot: BlenderImmersiveMuseMenuSlot? {
      guard let id = highlighted else { return nil }
      return Self.slots.first(where: { $0.id == id })
    }

    func bind(menuRoot root: Entity) {
      menuRoot = root
      root.isEnabled = false
    }

    func reset() {
      phase = .idle
      progress = 0
      highlighted = nil
      currentDirection = nil
      ignoreUntilRelease = false
      menuRoot?.isEnabled = false
    }

    // MARK: - State machine

    /**
     * One Muse tick. `tipWorld` is the pen tip in RealityKit world space.
     * `drawDown`: tip / secondary pressed (a stroke is starting).
     */
    func update(
      primaryDown: Bool, drawDown: Bool, tipWorld: SIMD3<Float>, now: TimeInterval,
      menuAllowed: Bool = true
    ) -> Event {
      persistHoldIfChanged()
      switch phase {
      case .idle:
        if !primaryDown {
          ignoreUntilRelease = false
          return .none
        }
        if ignoreUntilRelease || !menuAllowed {
          ignoreUntilRelease = true
          return .none
        }
        phase = .pressing
        pressStart = now
        setProgress(0)
        placeRing(at: tipWorld, visible: false)
        return .none

      case .pressing:
        let held = now - pressStart
        if !primaryDown {
          phase = .idle
          setProgress(0)
          menuRoot?.isEnabled = false
          return held < tapMaxSeconds ? .tap : .none
        }
        if drawDown {
          /* A stroke started: this press is not a menu request. */
          phase = .idle
          ignoreUntilRelease = true
          setProgress(0)
          menuRoot?.isEnabled = false
          return .none
        }
        let total = TimeInterval(holdSeconds)
        setProgress(Float(min(held / total, 1)))
        if held >= total {
          open(at: tipWorld)
          return .opened
        }
        placeRing(at: tipWorld, visible: held >= ringDelaySeconds)
        return .none

      case .open:
        track(tipWorld)
        if primaryDown {
          return .none
        }
        let slot = highlightedSlot
        phase = .idle
        setProgress(0)
        menuRoot?.isEnabled = false
        highlighted = nil
        currentDirection = nil
        guard let slot else {
          log("muse menu CANCEL (deadzone)")
          return .cancelled
        }
        apply(slot)
        return .selected(slot.id)
      }
    }

    private func setProgress(_ p: Float) {
      let q = (p * 20).rounded() / 20
      if abs(q - progress) > 1.0e-4 { progress = q }
    }

    private func frame(at tip: SIMD3<Float>) {
      var forward = SIMD3<Float>(0, 0, 1)
      if let head = headProvider?() {
        let d = head - tip
        let h = SIMD3<Float>(d.x, 0, d.z)
        if simd_length(h) > 1.0e-3 {
          forward = simd_normalize(h)
        }
      }
      toViewer = forward
      right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))
      up = SIMD3<Float>(0, 1, 0)
    }

    private func open(at tip: SIMD3<Float>) {
      phase = .open
      center = tip
      frame(at: tip)
      highlighted = nil
      currentDirection = nil
      currentOuter = false
      if let root = menuRoot {
        /* Above the tip and slightly behind it (away from the wearer) so the pen and the
         * right hand stay below / in front of the menu instead of covering it. */
        root.setPosition(center + up * 0.03 - toViewer * 0.02, relativeTo: nil)
        root.setScale(SIMD3<Float>(repeating: 1), relativeTo: nil)
        root.isEnabled = true
      }
      log(String(format: "muse menu OPEN hold=%.1fs", holdSeconds))
    }

    private func placeRing(at tip: SIMD3<Float>, visible: Bool) {
      guard let root = menuRoot else { return }
      if visible {
        frame(at: tip)
        root.setPosition(tip + up * 0.03 - toViewer * 0.02, relativeTo: nil)
        root.setScale(SIMD3<Float>(repeating: 1), relativeTo: nil)
      }
      if root.isEnabled != visible {
        root.isEnabled = visible
      }
    }

    /** Tip displacement on the menu plane → slice (with angle / ring hysteresis). */
    private func track(_ tip: SIMD3<Float>) {
      let d = tip - center
      let x = simd_dot(d, right)
      let y = simd_dot(d, up)
      let r = (x * x + y * y).squareRoot()
      if r < deadzone {
        currentDirection = nil
        if highlighted != nil { highlighted = nil }
        return
      }
      /* Angle from "up", clockwise as seen by the wearer. */
      var angle = atan2(x, y) * 180 / Float.pi
      if angle < 0 { angle += 360 }
      var direction = Int((angle / 45).rounded()) % 8
      if let current = currentDirection {
        var delta = abs(angle - Float(current) * 45)
        if delta > 180 { delta = 360 - delta }
        if delta < 22.5 + 6 { direction = current }
      }
      currentDirection = direction
      let outerHys: Float = 0.006
      currentOuter = currentOuter ? r > outerRadius - outerHys : r > outerRadius + outerHys
      let slot =
        (currentOuter
          ? Self.slots.first(where: { $0.direction == direction && $0.outer }) : nil)
        ?? Self.slots.first(where: { $0.direction == direction && !$0.outer })
      if highlighted != slot?.id { highlighted = slot?.id }
    }

    private func apply(_ slot: BlenderImmersiveMuseMenuSlot) {
      if let preset = slot.remeshPreset {
        dyntopoOn = false
        WM_IOS_immersive_hand_menu_remesh_preset(Int32(preset))
        log("muse menu PICK Remesh preset=\(preset)")
        return
      }
      if slot.kind < 0 {
        let on = !BlenderImmersiveState.shared.handMenuDyntopo
        dyntopoOn = on
        WM_IOS_immersive_hand_menu_set_dyntopo(on ? 1 : 0)
        log("muse menu PICK Dyntopo \(on ? "on" : "off")")
        return
      }
      if BlenderImmersiveState.shared.handMenuMode == 0 {
        WM_IOS_immersive_hand_menu_set_mode(2)
      }
      "builtin.brush".withCString {
        WM_IOS_immersive_hand_menu_set_brush($0, Int32(slot.kind))
      }
      log("muse menu PICK \(slot.title) kind=\(slot.kind)")
    }

    private func log(_ msg: String) {
      print("[immersive] \(msg)")
      BlenderIOSDiagnosticLog.bootSwiftOnly(msg)
    }

    // MARK: - Debug hook (simulator smoke)

    private var debugNow: TimeInterval = 1000
    private var debugTip = SIMD3<Float>(0, 1.2, -0.5)
    private var debugLastEvent = "none"

    /**
     * 20 reset (synthetic clock, head at (0, 1.6, 0)), 21 feed one sample
     * (a = primary 0/1, b = advance seconds, c = draw 0/1), 22 set tip (RK world),
     * 23 set hold seconds, 24 query.
     */
    func debug(action: Int32, a: Float, b: Float, c: Float) -> String {
      switch action {
      case 20:
        reset()
        debugNow = 1000
        debugTip = SIMD3<Float>(0, 1.2, -0.5)
        debugLastEvent = "none"
        if headProvider == nil {
          headProvider = { SIMD3<Float>(0, 1.6, 0) }
        }
      case 21:
        debugNow += TimeInterval(max(b, 0))
        let ev = update(
          primaryDown: a > 0.5, drawDown: c > 0.5, tipWorld: debugTip, now: debugNow)
        switch ev {
        case .none: break
        case .tap: debugLastEvent = "tap"
        case .opened: debugLastEvent = "opened"
        case .selected(let id): debugLastEvent = "selected:\(id)"
        case .cancelled: debugLastEvent = "cancelled"
        }
      case 22:
        debugTip = SIMD3<Float>(a, b, c)
      case 23:
        setHoldSeconds(a)
      case 24:
        break
      default:
        return "err action=\(action)"
      }
      let slot = highlightedSlot
      return String(
        format:
          "mm phase=%d progress=%.2f hl=%d hl_title=%@ hl_kind=%d event=%@ suppress=%d hold=%.2f dyn=%d center=(%.3f,%.3f,%.3f) right=(%.2f,%.2f,%.2f)",
        phase.rawValue, progress, slot?.id ?? -1, slot?.title ?? "-", slot?.kind ?? -99,
        debugLastEvent, suppressesDrawing ? 1 : 0, holdSeconds,
        BlenderImmersiveState.shared.handMenuDyntopo ? 1 : 0,
        center.x, center.y, center.z, right.x, right.y, right.z)
    }
  }

  /** Progress ring while holding, marking menu once open. Placed by the controller. */
  struct BlenderImmersiveMusePieMenu: View {
    @ObservedObject private var menu = BlenderImmersiveMuseMarkingMenu.shared

    /* Points ≈ 0.73 mm in RealityKit attachments: inner ≈ 4.5 cm, outer ≈ 9 cm. */
    private let innerRadius: CGFloat = 62
    private let outerRadius: CGFloat = 122

    var body: some View {
      ZStack {
        if menu.phase == .open {
          Circle()
            .fill(.ultraThinMaterial)
            .frame(width: 2 * outerRadius + 70, height: 2 * outerRadius + 70)
            .opacity(0.85)
          Circle()
            .stroke(.white.opacity(0.35), lineWidth: 1)
            .frame(width: 2 * 30, height: 2 * 30)
          ForEach(BlenderImmersiveMuseMarkingMenu.slots) { slot in
            label(slot)
          }
          Text(menu.highlighted == nil ? "離す=キャンセル" : "離す=決定")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        else if menu.phase == .pressing {
          Circle()
            .stroke(.white.opacity(0.18), lineWidth: 4)
            .frame(width: 44, height: 44)
          Circle()
            .trim(from: 0, to: CGFloat(menu.progress))
            .stroke(.orange.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 44, height: 44)
        }
      }
      .frame(width: 2 * outerRadius + 80, height: 2 * outerRadius + 80)
      .allowsHitTesting(false)
    }

    @ViewBuilder
    private func label(_ slot: BlenderImmersiveMuseMenuSlot) -> some View {
      let rad = Double(slot.direction) * 45 * .pi / 180
      let r = slot.outer ? outerRadius : innerRadius
      let x = CGFloat(sin(rad)) * r
      let y = -CGFloat(cos(rad)) * r
      let hot = menu.highlighted == slot.id
      let title =
        slot.kind == -1
        ? (BlenderImmersiveState.shared.handMenuDyntopo ? "Dyntopo●" : "Dyntopo") : slot.title
      Text(title)
        .font(.system(size: slot.outer ? 11 : 13, weight: hot ? .bold : .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
          Capsule().fill(
            hot
              ? Color.orange.opacity(0.95)
              : slot.remeshPreset != nil
                ? Color.indigo.opacity(0.55)
              : (BlenderImmersiveState.shared.handMenuBrushKind == slot.kind
                ? Color.teal.opacity(0.6) : Color.gray.opacity(slot.outer ? 0.35 : 0.5))))
        .scaleEffect(hot ? 1.18 : 1)
        .offset(x: x, y: y)
    }
  }

#endif
