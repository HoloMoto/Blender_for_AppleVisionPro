/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Spatial-only Immersive features (TF-159, reworked TF-160):
 * - Two-hand hold (opt-in): both hands pinch and hold still briefly, then the scene follows
 *   the midpoint (move), the inter-hand direction (yaw) and distance (scale).
 * - Real-scale toggle (1:1 ↔ desk), hold reset and full origin reset.
 * - Brush preview (ring / disc / normal needle) driven by native sculpt hits.
 *
 * worldRoot.transform = T(placement + holdTranslation) * R(holdYaw) * S(viewScale).
 * Hand input uses RealityKit hand AnchorEntities only — never a second ARKitSession
 * (TF-134 crash type). Disabled while the spectator WorldAnchor is locked.
 *
 * Window interactions (look + pinch) are also pinches, so a one-hand grab moved the scene
 * whenever a window was dragged (TF-159 jitter). Hold therefore needs both hands, filters
 * the hand input, ignores sub-deadzone motion and never writes the root while idle.
 */

import Foundation
import RealityKit
import SwiftUI
import UIKit
import simd

#if os(visionOS)

  @_silgen_name("WM_IOS_immersive_set_view_scale")
  private func WM_IOS_immersive_set_view_scale(_ scale: Float)

  @MainActor
  final class BlenderImmersiveSpatialHold: ObservableObject {
    static let shared = BlenderImmersiveSpatialHold()

    /* Published values change only on discrete events (UI re-renders steal pinches). */
    @Published private(set) var holdEnabled = false
    @Published private(set) var isRealScale = true
    @Published private(set) var displayScale: Float = 1
    @Published private(set) var statusText = "ホールド: OFF"

    /** Pushed by the space view (palm-facing Hand Menu / interactive Mat board). */
    var handMenuVisible = false
    var uiBlocked = false
    weak var musePen: BlenderImmersiveMusePenController?

    private weak var worldRoot: Entity?
    /** Smoke-only stand-in for the RealityView root (simulator never binds one). */
    private var testRoot: Entity?
    private var handRoot: Entity?
    private var leftThumb: AnchorEntity?
    private var leftIndex: AnchorEntity?
    private var rightThumb: AnchorEntity?
    private var rightIndex: AnchorEntity?

    private var placementBase = SIMD3<Float>(0, 0, -1.2)
    private var holdTranslation = SIMD3<Float>.zero
    private var holdYaw: Float = 0
    private var viewScale: Float = 1
    private var lastSentScale: Float = 1
    /** Number of frames that actually changed the root transform (smoke observability). */
    private(set) var writeCount = 0

    private enum GrabSource {
      case hand
      case debug
    }

    private struct Grab {
      var source: GrabSource
      var twoHand: Bool
      /** Pivot at grab start, in worldRoot-parent space. */
      var pivot: SIMD3<Float>
      var refYaw: Float
      var refDist: Float
      var startPosition: SIMD3<Float>
      var startYaw: Float
      var startScale: Float
    }

    struct HandFrame {
      var leftTracked: Bool
      var rightTracked: Bool
      var leftThumb: SIMD3<Float>
      var leftIndex: SIMD3<Float>
      var rightThumb: SIMD3<Float>
      var rightIndex: SIMD3<Float>
    }

    private var grab: Grab?
    private var leftPinching = false
    private var rightPinching = false
    private var bothSince: TimeInterval?
    private var lastStepTime: TimeInterval?
    private var filtPivot = SIMD3<Float>.zero
    private var filtYaw: Float = 0
    private var filtDist: Float = 0
    private var wasAligned = false
    private var sampleTask: Task<Void, Never>?
    private var bindGeneration: UInt = 0

    private let pinchThreshold: Float = 0.028
    private let pinchRelease: Float = 0.038
    /** Both hands must pinch this long before the scene follows. */
    private let engageSeconds: TimeInterval = 0.35
    /** Low-pass time constant for the hand pivot / yaw / distance. */
    private let filterTau: Float = 0.08
    private let moveDeadzone: Float = 0.008
    private let yawDeadzone: Float = 0.05
    private let scaleDeadzone: Float = 0.04
    private let minScale: Float = 0.05
    private let maxScale: Float = 20

    private init() {}

    var isBound: Bool { worldRoot != nil }

    private var isAligned: Bool {
      BlenderImmersiveState.shared.sharedAnchor?.hasWorldOrigin == true
    }

    // MARK: - Binding

    func bind(worldRoot root: Entity, handParent: Entity, placementBase base: SIMD3<Float>) {
      unbind()
      testRoot = nil
      worldRoot = root
      placementBase = base
      bindGeneration &+= 1
      let generation = bindGeneration

      let hands = Entity()
      hands.name = "BlenderSpatialHoldHands"
      handParent.addChild(hands)
      handRoot = hands
      func anchor(
        _ chirality: AnchoringComponent.Target.Chirality,
        _ location: AnchoringComponent.Target.HandLocation,
        _ name: String
      ) -> AnchorEntity {
        let a = AnchorEntity(.hand(chirality, location: location), trackingMode: .continuous)
        a.name = name
        hands.addChild(a)
        return a
      }
      leftThumb = anchor(.left, .thumbTip, "HoldLThumb")
      leftIndex = anchor(.left, .indexFingerTip, "HoldLIndex")
      rightThumb = anchor(.right, .thumbTip, "HoldRThumb")
      rightIndex = anchor(.right, .indexFingerTip, "HoldRIndex")

      wasAligned = isAligned
      applyComposite()
      sendScale(force: true)
      publishState()

      sampleTask = Task { @MainActor [weak self] in
        await self?.runLoop(generation: generation)
      }
    }

    /** `from`: only unbind when still bound to that root (re-open ordering safety). */
    func unbind(from expected: Entity? = nil) {
      if let expected, let current = worldRoot, current !== expected {
        return
      }
      bindGeneration &+= 1
      sampleTask?.cancel()
      sampleTask = nil
      handRoot?.removeFromParent()
      handRoot = nil
      leftThumb = nil
      leftIndex = nil
      rightThumb = nil
      rightIndex = nil
      grab = nil
      leftPinching = false
      rightPinching = false
      bothSince = nil
      lastStepTime = nil
      if worldRoot != nil {
        /* Native strokes outside Immersive use 1:1. Restored on next bind. */
        WM_IOS_immersive_set_view_scale(1)
        lastSentScale = 1
      }
      worldRoot = nil
      testRoot = nil
    }

    /**
     * Called from BlenderImmersiveObjectSync.updatePlacement — composes placement with
     * hold so the two never fight. Aligned (WorldAnchor) keeps the legacy behaviour.
     */
    func applyPlacement(base: SIMD3<Float>, to root: Entity) {
      placementBase = base
      if root !== worldRoot || isAligned {
        if root.position != base {
          root.position = base
        }
        return
      }
      applyComposite()
    }

    /** Writes the root only when the composed transform differs from what it holds. */
    private func applyComposite() {
      guard let root = worldRoot, !isAligned else { return }
      let position = placementBase + holdTranslation
      let orientation = simd_quatf(angle: holdYaw, axis: SIMD3<Float>(0, 1, 0))
      let scale = SIMD3<Float>(repeating: viewScale)
      var wrote = false
      if simd_length(root.position - position) > 1.0e-5 {
        root.position = position
        wrote = true
      }
      if Self.angleBetween(root.orientation, orientation) > 1.0e-4 {
        root.orientation = orientation
        wrote = true
      }
      if simd_length(root.scale - scale) > 1.0e-5 {
        root.scale = scale
        wrote = true
      }
      if wrote {
        writeCount &+= 1
      }
      sendScale(force: false)
    }

    private static func angleBetween(_ a: simd_quatf, _ b: simd_quatf) -> Double {
      let va = a.vector
      let vb = b.vector
      let dot =
        Double(va.x) * Double(vb.x) + Double(va.y) * Double(vb.y) + Double(va.z) * Double(vb.z)
        + Double(va.w) * Double(vb.w)
      return 2 * acos(min(1, abs(dot)))
    }

    private func sendScale(force: Bool) {
      let effective: Float = isAligned ? 1 : viewScale
      if force || abs(effective - lastSentScale) > 0.0005 {
        lastSentScale = effective
        WM_IOS_immersive_set_view_scale(effective)
      }
    }

    private func publishState() {
      let real = abs(viewScale - 1) < 0.001
      if isRealScale != real { isRealScale = real }
      if abs(displayScale - viewScale) > 0.0005 { displayScale = viewScale }
    }

    private func setStatus(_ text: String) {
      if statusText != text { statusText = text }
    }

    private var idleStatus: String {
      if isAligned { return "ホールド: iPad合わせ中は無効" }
      return holdEnabled ? "ホールド: 待機（両手ピンチ）" : "ホールド: OFF"
    }

    // MARK: - Grab (shared by hand loop and debug hook)

    @discardableResult
    private func beginGrab(
      source: GrabSource, twoHand: Bool, pivotWorld: SIMD3<Float>, refYaw: Float, refDist: Float
    ) -> Bool {
      guard holdEnabled, let root = worldRoot, !isAligned else { return false }
      grab = Grab(
        source: source,
        twoHand: twoHand,
        pivot: parentSpace(pivotWorld, root: root),
        refYaw: refYaw,
        refDist: max(refDist, 0.01),
        startPosition: placementBase + holdTranslation,
        startYaw: holdYaw,
        startScale: viewScale)
      setStatus(twoHand ? "ホールド: 両手（移動・回転・拡縮）" : "ホールド: 片手（移動）")
      return true
    }

    /** Motion inside the deadzone is ignored; outside it, only the excess applies (no jump). */
    private static func soft(_ v: Float, _ dz: Float) -> Float {
      let m = abs(v)
      return m <= dz ? 0 : (v > 0 ? m - dz : dz - m)
    }

    private static func soft(_ v: SIMD3<Float>, _ dz: Float) -> SIMD3<Float> {
      let m = simd_length(v)
      return m <= dz ? .zero : v * ((m - dz) / m)
    }

    private func moveGrab(pivotWorld: SIMD3<Float>, yaw: Float, dist: Float) {
      guard let g = grab, let root = worldRoot else { return }
      if isAligned {
        endGrab()
        return
      }
      let filtered = g.source == .hand
      var delta = parentSpace(pivotWorld, root: root) - g.pivot
      var dYaw = Self.wrapAngle(yaw - g.refYaw)
      var logRatio: Float = 0
      if g.twoHand {
        logRatio = log(max(dist, 0.01) / g.refDist)
      }
      if filtered {
        delta = Self.soft(delta, moveDeadzone)
        dYaw = Self.soft(dYaw, yawDeadzone)
        logRatio = Self.soft(logRatio, scaleDeadzone)
      }
      let newScale = min(max(g.startScale * exp(logRatio), minScale), maxScale)
      let ratio = newScale / max(g.startScale, 1.0e-4)
      let rot = simd_quatf(angle: dYaw, axis: SIMD3<Float>(0, 1, 0))
      let position = g.pivot + delta + rot.act((g.startPosition - g.pivot) * ratio)
      guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return }
      holdTranslation = position - placementBase
      holdYaw = Self.wrapAngle(g.startYaw + dYaw)
      viewScale = newScale
      applyComposite()
    }

    private func endGrab() {
      guard grab != nil else { return }
      grab = nil
      publishState()
      setStatus(idleStatus)
    }

    private func parentSpace(_ world: SIMD3<Float>, root: Entity) -> SIMD3<Float> {
      if let parent = root.parent {
        return parent.convert(position: world, from: nil)
      }
      return world
    }

    private static func wrapAngle(_ a: Float) -> Float {
      var v = a
      while v > Float.pi { v -= 2 * Float.pi }
      while v < -Float.pi { v += 2 * Float.pi }
      return v
    }

    /** Yaw about +Y (RealityKit up) of a horizontal direction: R_y(θ)·(1,0,0) = v. */
    private static func yawOf(_ v: SIMD3<Float>) -> Float? {
      let h = SIMD2<Float>(v.x, v.z)
      guard simd_length(h) > 0.05 else { return nil }
      return atan2(-v.z, v.x)
    }

    // MARK: - Hand loop

    private func runLoop(generation: UInt) async {
      _ = await BlenderImmersiveSpatialTracking.ensure(capabilities: [.hand])
      while !Task.isCancelled, generation == bindGeneration {
        tick()
        try? await Task.sleep(nanoseconds: 16_666_667)
      }
    }

    private func updatePinch(
      _ current: Bool, tracked: Bool, a: SIMD3<Float>, b: SIMD3<Float>
    ) -> Bool {
      guard tracked else { return false }
      let d = simd_length(a - b)
      if current {
        return d <= pinchRelease
      }
      return d < pinchThreshold
    }

    private func tick() {
      let aligned = isAligned
      if aligned != wasAligned {
        wasAligned = aligned
        if aligned {
          /* Protect MRC alignment: drop hold / scale entirely. */
          grab = nil
          bothSince = nil
          holdTranslation = .zero
          holdYaw = 0
          viewScale = 1
          worldRoot?.scale = SIMD3<Float>(repeating: 1)
          sendScale(force: true)
          publishState()
        }
        else {
          applyComposite()
          sendScale(force: true)
        }
        setStatus(idleStatus)
      }

      guard let lt = leftThumb, let li = leftIndex, let rt = rightThumb, let ri = rightIndex
      else { return }
      let frame = HandFrame(
        leftTracked: lt.isAnchored && li.isAnchored,
        rightTracked: rt.isAnchored && ri.isAnchored,
        leftThumb: lt.position(relativeTo: nil),
        leftIndex: li.position(relativeTo: nil),
        rightThumb: rt.position(relativeTo: nil),
        rightIndex: ri.position(relativeTo: nil))
      step(frame, now: Date().timeIntervalSinceReferenceDate)
    }

    /** One hand sample. Writes the root only while a two-hand hold is engaged. */
    private func step(_ f: HandFrame, now: TimeInterval) {
      leftPinching = updatePinch(
        leftPinching, tracked: f.leftTracked, a: f.leftThumb, b: f.leftIndex)
      rightPinching = updatePinch(
        rightPinching, tracked: f.rightTracked, a: f.rightThumb, b: f.rightIndex)
      let dt = Float(min(max(now - (lastStepTime ?? now), 0), 0.1))
      lastStepTime = now

      /* Debug-sourced grabs are driven only by debugSpatial. */
      if let g = grab, g.source == .debug {
        return
      }

      let museDown = musePen?.isTipDown ?? false
      let blocked =
        !holdEnabled || isAligned || handMenuVisible || uiBlocked
        || BlenderImmersiveState.shared.useHandAsPen || museDown
      guard leftPinching, rightPinching, !blocked else {
        bothSince = nil
        endGrab()
        return
      }

      let l = (f.leftThumb + f.leftIndex) * 0.5
      let r = (f.rightThumb + f.rightIndex) * 0.5
      let rawPivot = (l + r) * 0.5
      let rawDist = simd_length(r - l)
      if bothSince == nil {
        bothSince = now
        filtPivot = rawPivot
        filtYaw = Self.yawOf(r - l) ?? 0
        filtDist = rawDist
      }
      else {
        let alpha = 1 - exp(-dt / filterTau)
        filtPivot += (rawPivot - filtPivot) * alpha
        if let rawYaw = Self.yawOf(r - l) {
          filtYaw = Self.wrapAngle(filtYaw + Self.wrapAngle(rawYaw - filtYaw) * alpha)
        }
        filtDist += (rawDist - filtDist) * alpha
      }

      if grab == nil {
        guard let since = bothSince, now - since >= engageSeconds else { return }
        beginGrab(
          source: .hand, twoHand: true, pivotWorld: filtPivot, refYaw: filtYaw, refDist: filtDist)
        return
      }
      moveGrab(pivotWorld: filtPivot, yaw: filtYaw, dist: filtDist)
    }

    // MARK: - Scale / reset

    func setHoldEnabled(_ enabled: Bool) {
      if holdEnabled == enabled { return }
      holdEnabled = enabled
      if !enabled {
        grab = nil
        bothSince = nil
      }
      setStatus(idleStatus)
    }

    func toggleRealScale() {
      guard let root = worldRoot, !isAligned else {
        setStatus(isAligned ? "ホールド: iPad合わせ中は無効" : "ホールド: 未接続")
        return
      }
      let target: Float = abs(viewScale - 1) < 0.001 ? deskScale(root: root) : 1
      setScaleKeepingFocus(target, root: root)
      setStatus(abs(target - 1) < 0.001 ? "表示: 1:1" : String(format: "表示: 卓上 ×%.2f", target))
    }

    /** Clears hold move / yaw / scale; keeps the placement offset. */
    func reset() {
      grab = nil
      bothSince = nil
      holdTranslation = .zero
      holdYaw = 0
      viewScale = 1
      applyComposite()
      sendScale(force: false)
      publishState()
      setStatus(isAligned ? "ホールド: iPad合わせ中は無効" : "ホールド: リセット")
    }

    /**
     * Back to the default origin: hold + view scale + placement offset (Space tab sliders).
     * While the spectator origin is locked the scene stays on the locked WorldAnchor; only
     * the offsets are cleared so unlocking does not jump.
     */
    @discardableResult
    func resetOrigin() -> String {
      reset()
      let state = BlenderImmersiveState.shared
      if state.placementX != 0 || state.placementY != 0 || state.placementZ != 0 {
        state.updatePlacement(x: 0, y: 0, z: 0)
        NotificationCenter.default.post(name: .blenderImmersivePlacementChanged, object: nil)
      }
      placementBase = SIMD3<Float>(0, 0, -1.2)
      applyComposite()
      let text = isAligned ? "原点: iPad合わせ原点を維持（オフセット解除）" : "原点: リセット"
      setStatus(text)
      return text
    }

    private func setScaleKeepingFocus(_ target: Float, root: Entity) {
      grab = nil
      let focus = focusLocalPoint(root: root)
      let rot = simd_quatf(angle: holdYaw, axis: SIMD3<Float>(0, 1, 0))
      let position = placementBase + holdTranslation
      /* world(F) = pos + R·(s·F) stays fixed: pos' = pos + R·((s − t)·F). */
      let next = position + rot.act(focus * (viewScale - target))
      if next.x.isFinite && next.y.isFinite && next.z.isFinite {
        holdTranslation = next - placementBase
      }
      viewScale = target
      applyComposite()
      publishState()
    }

    private func sceneEntity(root: Entity) -> Entity? {
      if let live = root.children.first(where: { $0.name == "BlenderImmersiveLive" && $0.isEnabled })
      {
        return live
      }
      return root.children.first(where: { $0.name == "BlenderImmersiveUSD" && $0.isEnabled })
    }

    private func sceneBounds(root: Entity) -> BoundingBox? {
      guard let scene = sceneEntity(root: root) else { return nil }
      let bounds = scene.visualBounds(recursive: true, relativeTo: root)
      guard !bounds.isEmpty else { return nil }
      let ext = bounds.extents
      guard ext.x.isFinite, ext.y.isFinite, ext.z.isFinite else { return nil }
      return bounds
    }

    private func deskScale(root: Entity) -> Float {
      var diameter: Float = 0.25
      if let bounds = sceneBounds(root: root) {
        let d = simd_length(bounds.extents)
        if d.isFinite && d > 1.0e-4 {
          diameter = d
        }
      }
      return min(max(0.30 / diameter, 0.05), 8)
    }

    private func focusLocalPoint(root: Entity) -> SIMD3<Float> {
      let state = BlenderImmersiveState.shared
      if let name = state.activeObjectName, !name.isEmpty {
        return BlenderImmersiveCoords.blenderToRealityKit(
          SIMD3(state.activeObjectX, state.activeObjectY, state.activeObjectZ))
      }
      if let bounds = sceneBounds(root: root) {
        return bounds.center
      }
      return .zero
    }

    // MARK: - Debug hook (spec D)

    /** Deterministic noise for synthetic hand frames. */
    private struct Noise {
      var state: UInt64
      mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF) * 2 - 1
      }
      mutating func vec(_ amp: Float) -> SIMD3<Float> {
        SIMD3<Float>(next(), next(), next()) * amp
      }
    }

    /**
     * Synthetic hands, 60 Hz. Scenario:
     * 0 open hands, 1 peace pose (index/middle out, thumb away), 2 left pinch dragged 15 cm
     * (old one-hand trigger / window drag), 3 both pinching and held still,
     * 4 both pinching then moved 15 cm along +X.
     * Returns root writes and how far the root moved.
     */
    private func runSynthetic(frames: Int, noise amp: Float, scenario: Int) -> String {
      guard let root = worldRoot else { return "err nobind " + query() }
      var rng = Noise(state: 0x9E37_79B9_7F4A_7C15 &+ UInt64(scenario))
      let startPos = root.position
      let startScale = root.scale.x
      let startWrites = writeCount
      var t = (lastStepTime ?? 0) + 1
      let leftHome = SIMD3<Float>(-0.15, 1.1, -0.45)
      let rightHome = SIMD3<Float>(0.15, 1.1, -0.45)
      let pinchGap = SIMD3<Float>(0.012, 0, 0)
      let openGap = SIMD3<Float>(0.07, 0.04, 0)
      for i in 0..<max(frames, 1) {
        t += 1.0 / 60.0
        var lGap = openGap
        var rGap = openGap
        var lOff = SIMD3<Float>.zero
        var rOff = SIMD3<Float>.zero
        switch scenario {
        case 1:
          lGap = SIMD3<Float>(0.06, 0.08, 0.01)
          rGap = lGap
        case 2:
          lGap = pinchGap
          lOff = SIMD3<Float>(0.15 * Float(i) / Float(max(frames - 1, 1)), 0, 0)
        case 3:
          lGap = pinchGap
          rGap = pinchGap
        case 4:
          lGap = pinchGap
          rGap = pinchGap
          let move = max(0, Float(i) - 40) / Float(max(frames - 41, 1))
          lOff = SIMD3<Float>(0.15 * min(move, 1), 0, 0)
          rOff = lOff
        default:
          break
        }
        let lBase = leftHome + lOff
        let rBase = rightHome + rOff
        let frame = HandFrame(
          leftTracked: true,
          rightTracked: true,
          leftThumb: lBase + rng.vec(amp),
          leftIndex: lBase + lGap + rng.vec(amp),
          rightThumb: rBase + rng.vec(amp),
          rightIndex: rBase + rGap + rng.vec(amp))
        step(frame, now: t)
      }
      /* Release both hands. */
      t += 1.0 / 60.0
      step(
        HandFrame(
          leftTracked: false, rightTracked: false, leftThumb: .zero, leftIndex: .zero,
          rightThumb: .zero, rightIndex: .zero),
        now: t)
      let moved = simd_length(root.position - startPos)
      return query()
        + String(
          format: " writes=%d moved=%.4f dscale=%.4f",
          writeCount - startWrites, moved, root.scale.x - startScale)
    }

    func debug(action: Int32, a: Float, b: Float, c: Float) -> String {
      let p = SIMD3<Float>(a, b, c)
      switch action {
      case 1:
        if !beginGrab(source: .debug, twoHand: false, pivotWorld: p, refYaw: 0, refDist: 0) {
          return "err begin " + query()
        }
      case 2:
        if let g = grab {
          moveGrab(pivotWorld: p, yaw: g.refYaw, dist: 0)
        }
        else {
          return "err nohold " + query()
        }
      case 3:
        endGrab()
      case 4:
        toggleRealScale()
      case 5:
        reset()
      case 6:
        break
      case 7:
        let preview = BlenderImmersiveBrushPreview.shared
        preview.apply(
          BlenderImmersiveBrushPreviewParams(
            visible: true,
            position: p,
            normal: SIMD3<Float>(0, 0, 1),
            radius: 0.1,
            strength: 0.5,
            active: false,
            kind: 0))
        return query() + " " + preview.report()
      case 8:
        let before = viewScale
        let l0 = p - SIMD3<Float>(0.1, 0, 0)
        let r0 = p + SIMD3<Float>(0.1, 0, 0)
        guard
          beginGrab(
            source: .debug, twoHand: true, pivotWorld: (l0 + r0) * 0.5,
            refYaw: Self.yawOf(r0 - l0) ?? 0, refDist: simd_length(r0 - l0))
        else {
          return "err begin " + query()
        }
        let l1 = p - SIMD3<Float>(0.2, 0, 0)
        let r1 = p + SIMD3<Float>(0.2, 0, 0)
        moveGrab(
          pivotWorld: (l1 + r1) * 0.5, yaw: Self.yawOf(r1 - l1) ?? 0,
          dist: simd_length(r1 - l1))
        endGrab()
        return query() + String(format: " before=%.3f after=%.3f", before, viewScale)
      case 9:
        if worldRoot == nil {
          let root = Entity()
          root.name = "BlenderSpatialHoldSmokeRoot"
          testRoot = root
          worldRoot = root
          placementBase = SIMD3<Float>(0, 0, -1.2)
          applyComposite()
        }
      case 10:
        return runSynthetic(frames: Int(a), noise: b, scenario: Int(c))
      case 11:
        setHoldEnabled(a > 0.5)
      case 12:
        return resetOrigin() + " " + query()
      case 13:
        if let test = testRoot, worldRoot === test {
          unbind()
        }
      case 14:
        BlenderImmersiveState.shared.updatePlacement(x: a, y: b, z: c)
        if let root = worldRoot {
          applyPlacement(base: SIMD3<Float>(a, b, -1.2 + c), to: root)
        }
      default:
        return "err action=\(action) " + query()
      }
      return query()
    }

    private func query() -> String {
      let pos = worldRoot?.position ?? .zero
      let state = BlenderImmersiveState.shared
      return String(
        format:
          "ok bound=%d scale=%.3f pos=(%.3f,%.3f,%.3f) yaw=%.2f hold=%d preview=%d aligned=%d enabled=%d test=%d writes=%d place=(%.3f,%.3f,%.3f)",
        worldRoot != nil ? 1 : 0,
        viewScale,
        pos.x, pos.y, pos.z,
        holdYaw,
        grab != nil ? 1 : 0,
        BlenderImmersiveBrushPreview.shared.isShowing ? 1 : 0,
        isAligned ? 1 : 0,
        holdEnabled ? 1 : 0,
        testRoot != nil ? 1 : 0,
        writeCount,
        state.placementX, state.placementY, state.placementZ)
    }
  }

  // MARK: - Brush preview (3c)

  struct BlenderImmersiveBrushPreviewParams: Sendable {
    var visible: Bool
    /** Blender coords (worldRoot-local). */
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var radius: Float
    var strength: Float
    var active: Bool
    var kind: Int
  }

  /** Coalesces ~60 Hz native updates into at most one pending main-queue apply. */
  final class BlenderImmersiveBrushPreviewMailbox: @unchecked Sendable {
    static let shared = BlenderImmersiveBrushPreviewMailbox()

    private let lock = NSLock()
    private var pending: BlenderImmersiveBrushPreviewParams?
    private var scheduled = false

    func post(_ params: BlenderImmersiveBrushPreviewParams) {
      lock.lock()
      pending = params
      let needSchedule = !scheduled
      scheduled = true
      lock.unlock()
      guard needSchedule else { return }
      DispatchQueue.main.async {
        guard let next = self.take() else { return }
        MainActor.assumeIsolated {
          BlenderImmersiveBrushPreview.shared.apply(next)
        }
      }
    }

    private func take() -> BlenderImmersiveBrushPreviewParams? {
      lock.lock()
      defer { lock.unlock() }
      scheduled = false
      let next = pending
      pending = nil
      return next
    }
  }

  @MainActor
  final class BlenderImmersiveBrushPreview {
    static let shared = BlenderImmersiveBrushPreview()

    private weak var worldRoot: Entity?
    private var root: Entity?
    private var ring: ModelEntity?
    private var disc: ModelEntity?
    private var needle: ModelEntity?
    private var styleKey = -1
    private var latest: BlenderImmersiveBrushPreviewParams?

    private init() {}

    var isShowing: Bool {
      guard let root, worldRoot != nil, root.parent != nil else { return false }
      return root.isEnabled
    }

    func bind(worldRoot newRoot: Entity) {
      worldRoot = newRoot
      ensureEntities()
      if let root, root.parent !== newRoot {
        root.removeFromParent()
        newRoot.addChild(root)
      }
      root?.isEnabled = false
      if let latest {
        apply(latest)
      }
    }

    func unbind(from expected: Entity? = nil) {
      if let expected, let current = worldRoot, current !== expected {
        return
      }
      root?.removeFromParent()
      root?.isEnabled = false
      latest = nil
      worldRoot = nil
    }

    func report() -> String {
      let p = root?.position ?? .zero
      return String(
        format: "preview_enabled=%d preview_pos=(%.3f,%.3f,%.3f)",
        isShowing ? 1 : 0, p.x, p.y, p.z)
    }

    func apply(_ params: BlenderImmersiveBrushPreviewParams) {
      latest = params
      guard let world = worldRoot else { return }
      ensureEntities()
      guard let root, let ring, let disc, let needle else { return }
      if root.parent !== world {
        root.removeFromParent()
        world.addChild(root)
      }
      let p = params.position
      let n = params.normal
      guard params.visible, p.x.isFinite, p.y.isFinite, p.z.isFinite, params.radius.isFinite,
        params.radius > 0
      else {
        root.isEnabled = false
        return
      }

      root.position = BlenderImmersiveCoords.blenderToRealityKit(p)
      var nrk = BlenderImmersiveCoords.blenderToRealityKit(n)
      let len = simd_length(nrk)
      nrk = (len.isFinite && len > 1.0e-5) ? nrk / len : SIMD3<Float>(0, 1, 0)
      let up = SIMD3<Float>(0, 1, 0)
      let d = simd_dot(up, nrk)
      if d > 0.9999 {
        root.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
      }
      else if d < -0.9999 {
        root.orientation = simd_quatf(angle: Float.pi, axis: SIMD3<Float>(1, 0, 0))
      }
      else {
        root.orientation = simd_quatf(from: up, to: nrk)
      }

      let radius = min(max(params.radius, 0.001), 5)
      let strength = min(max(params.strength.isFinite ? params.strength : 0, 0), 1)
      ring.scale = SIMD3<Float>(repeating: radius)
      disc.scale = SIMD3<Float>(repeating: radius)
      let needleLen = radius * (0.3 + 0.7 * strength)
      needle.scale = SIMD3<Float>(1, needleLen, 1)
      needle.position = SIMD3<Float>(0, needleLen * 0.5, 0)

      let key = Self.colorClass(kind: params.kind) * 2 + (params.active ? 1 : 0)
      if key != styleKey {
        styleKey = key
        let color = Self.color(kind: params.kind)
        ring.model?.materials = [Self.material(color, alpha: params.active ? 0.95 : 0.6)]
        disc.model?.materials = [Self.material(color, alpha: params.active ? 0.14 : 0.06)]
        needle.model?.materials = [Self.material(color, alpha: params.active ? 0.9 : 0.55)]
      }
      root.isEnabled = true
    }

    private func ensureEntities() {
      guard root == nil else { return }
      let base = Entity()
      base.name = "BlenderBrushPreview"
      base.isEnabled = false

      let color = Self.color(kind: 0)
      let ringMesh = Self.makeRingMesh() ?? MeshResource.generateSphere(radius: 0.02)
      let ringEntity = ModelEntity(mesh: ringMesh, materials: [Self.material(color, alpha: 0.6)])
      ringEntity.name = "BrushPreviewRing"

      let discEntity = ModelEntity(
        mesh: .generateSphere(radius: 1.0), materials: [Self.material(color, alpha: 0.06)])
      discEntity.name = "BrushPreviewSphere"

      let needleEntity = ModelEntity(
        mesh: .generateCylinder(height: 1.0, radius: 0.0025),
        materials: [Self.material(color, alpha: 0.55)])
      needleEntity.name = "BrushPreviewNeedle"

      for e in [ringEntity, discEntity, needleEntity] {
        e.components.remove(CollisionComponent.self)
        e.components.remove(InputTargetComponent.self)
        base.addChild(e)
      }
      root = base
      ring = ringEntity
      disc = discEntity
      needle = needleEntity
      styleKey = -1
    }

    private static func colorClass(kind: Int) -> Int {
      switch kind {
      case 6: return 1
      case 5: return 2
      case 2, 9: return 3
      case 3: return 4
      default: return 0
      }
    }

    private static func color(kind: Int) -> UIColor {
      switch colorClass(kind: kind) {
      case 1: return .systemBlue
      case 2: return .systemPurple
      case 3: return .systemGreen
      case 4: return .cyan
      default: return .orange
      }
    }

    private static func material(_ color: UIColor, alpha: Float) -> UnlitMaterial {
      var material = UnlitMaterial(color: color)
      material.color = .init(tint: color.withAlphaComponent(CGFloat(alpha)))
      material.blending = .transparent(opacity: .init(floatLiteral: alpha))
      return material
    }

    /** Unit-radius torus in the XZ plane (normal +Y), double-sided. */
    private static func makeRingMesh() -> MeshResource? {
      let segments = 48
      let tubeSegments = 6
      let tube: Float = 0.015
      var positions: [SIMD3<Float>] = []
      var normals: [SIMD3<Float>] = []
      var indices: [UInt32] = []
      positions.reserveCapacity(segments * tubeSegments)
      normals.reserveCapacity(segments * tubeSegments)
      for i in 0..<segments {
        let u = Float(i) / Float(segments) * 2 * Float.pi
        let cu = cos(u)
        let su = sin(u)
        for j in 0..<tubeSegments {
          let v = Float(j) / Float(tubeSegments) * 2 * Float.pi
          let cv = cos(v)
          let sv = sin(v)
          positions.append(SIMD3<Float>((1 + tube * cv) * cu, tube * sv, (1 + tube * cv) * su))
          normals.append(SIMD3<Float>(cv * cu, sv, cv * su))
        }
      }
      for i in 0..<segments {
        let i1 = (i + 1) % segments
        for j in 0..<tubeSegments {
          let j1 = (j + 1) % tubeSegments
          let a = UInt32(i * tubeSegments + j)
          let b = UInt32(i1 * tubeSegments + j)
          let c = UInt32(i1 * tubeSegments + j1)
          let d = UInt32(i * tubeSegments + j1)
          indices.append(contentsOf: [a, b, c, a, c, d, a, c, b, a, d, c])
        }
      }
      var descriptor = MeshDescriptor(name: "BlenderBrushPreviewRing")
      descriptor.positions = MeshBuffers.Positions(positions)
      descriptor.normals = MeshBuffers.Normals(normals)
      descriptor.primitives = .triangles(indices)
      do {
        return try MeshResource.generate(from: [descriptor])
      }
      catch {
        print("[immersive] brush preview ring mesh failed: \(error)")
        return nil
      }
    }
  }

#endif
