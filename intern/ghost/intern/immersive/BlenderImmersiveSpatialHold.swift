/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Spatial-only Immersive features (TF-159):
 * - Two-hand hold: left pinch grabs the scene (move + yaw), both hands add scale.
 * - Real-scale toggle (1:1 ↔ desk) + reset.
 * - Brush preview (ring / disc / normal needle) driven by native sculpt hits.
 *
 * worldRoot.transform = T(placement + holdTranslation) * R(holdYaw) * S(viewScale).
 * Hand input uses RealityKit hand AnchorEntities only — never a second ARKitSession
 * (TF-134 crash type). Disabled while the spectator WorldAnchor is locked.
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
    @Published private(set) var holdEnabled = true
    @Published private(set) var isRealScale = true
    @Published private(set) var displayScale: Float = 1
    @Published private(set) var statusText = "ホールド: 待機"

    /** Pushed by the space view (palm-facing Hand Menu / interactive Mat board). */
    var handMenuVisible = false
    var uiBlocked = false
    weak var musePen: BlenderImmersiveMusePenController?

    private weak var worldRoot: Entity?
    private var handRoot: Entity?
    private var leftThumb: AnchorEntity?
    private var leftIndex: AnchorEntity?
    private var leftPalm: AnchorEntity?
    private var rightThumb: AnchorEntity?
    private var rightIndex: AnchorEntity?

    private var placementBase = SIMD3<Float>(0, 0, -1.2)
    private var holdTranslation = SIMD3<Float>.zero
    private var holdYaw: Float = 0
    private var viewScale: Float = 1
    private var lastSentScale: Float = 1

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

    private var grab: Grab?
    private var leftPinching = false
    private var rightPinching = false
    private var leftPinchStart: Date?
    private var leftPinchStartPos = SIMD3<Float>.zero
    private var lastHandYaw: Float = 0
    private var wasAligned = false
    private var sampleTask: Task<Void, Never>?
    private var bindGeneration: UInt = 0

    private let pinchThreshold: Float = 0.028
    private let pinchRelease: Float = 0.038
    private let engageSeconds: TimeInterval = 0.25
    private let engageDistance: Float = 0.01
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
      leftPalm = anchor(.left, .palm, "HoldLPalm")
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
      leftPalm = nil
      rightThumb = nil
      rightIndex = nil
      grab = nil
      leftPinching = false
      rightPinching = false
      leftPinchStart = nil
      if worldRoot != nil {
        /* Native strokes outside Immersive use 1:1. Restored on next bind. */
        WM_IOS_immersive_set_view_scale(1)
        lastSentScale = 1
      }
      worldRoot = nil
    }

    /**
     * Called from BlenderImmersiveObjectSync.updatePlacement — composes placement with
     * hold so the two never fight. Aligned (WorldAnchor) keeps the legacy behaviour.
     */
    func applyPlacement(base: SIMD3<Float>, to root: Entity) {
      placementBase = base
      if root !== worldRoot || isAligned {
        root.position = base
        return
      }
      applyComposite()
    }

    private func applyComposite() {
      guard let root = worldRoot, !isAligned else { return }
      root.position = placementBase + holdTranslation
      root.orientation = simd_quatf(angle: holdYaw, axis: SIMD3<Float>(0, 1, 0))
      root.scale = SIMD3<Float>(repeating: viewScale)
      sendScale(force: false)
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
      setStatus(twoHand ? "ホールド: 両手（移動・回転・拡縮）" : "ホールド: 片手（移動・回転）")
      return true
    }

    private func moveGrab(pivotWorld: SIMD3<Float>, yaw: Float, dist: Float) {
      guard let g = grab, let root = worldRoot else { return }
      if isAligned {
        endGrab()
        return
      }
      let pivot = parentSpace(pivotWorld, root: root)
      let dYaw = Self.wrapAngle(yaw - g.refYaw)
      var newScale = g.startScale
      if g.twoHand {
        newScale = min(max(g.startScale * (dist / g.refDist), minScale), maxScale)
      }
      let ratio = newScale / max(g.startScale, 1.0e-4)
      let rot = simd_quatf(angle: dYaw, axis: SIMD3<Float>(0, 1, 0))
      let position = pivot + rot.act((g.startPosition - g.pivot) * ratio)
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
      setStatus(isAligned ? "ホールド: iPad合わせ中は無効" : "ホールド: 待機")
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
      guard simd_length(h) > 1.0e-4 else { return nil }
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
          holdTranslation = .zero
          holdYaw = 0
          viewScale = 1
          worldRoot?.scale = SIMD3<Float>(repeating: 1)
          sendScale(force: true)
          publishState()
          setStatus("ホールド: iPad合わせ中は無効")
        }
        else {
          applyComposite()
          sendScale(force: true)
          setStatus("ホールド: 待機")
        }
      }

      guard let lt = leftThumb, let li = leftIndex, let lp = leftPalm,
        let rt = rightThumb, let ri = rightIndex
      else { return }

      let leftTracked = lt.isAnchored && li.isAnchored
      let lThumb = lt.position(relativeTo: nil)
      let lIndex = li.position(relativeTo: nil)
      let leftPoint = (lThumb + lIndex) * 0.5
      leftPinching = updatePinch(leftPinching, tracked: leftTracked, a: lThumb, b: lIndex)

      let rightTracked = rt.isAnchored && ri.isAnchored
      let rThumb = rt.position(relativeTo: nil)
      let rIndex = ri.position(relativeTo: nil)
      let rightPoint = (rThumb + rIndex) * 0.5
      rightPinching = updatePinch(rightPinching, tracked: rightTracked, a: rThumb, b: rIndex)

      if lp.isAnchored {
        let m = lp.transformMatrix(relativeTo: nil)
        let xAxis = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        if simd_length(SIMD2<Float>(xAxis.x, xAxis.z)) > 0.3, let yaw = Self.yawOf(xAxis) {
          lastHandYaw = yaw
        }
      }

      let now = Date()
      if leftPinching {
        if leftPinchStart == nil {
          leftPinchStart = now
          leftPinchStartPos = leftPoint
        }
      }
      else {
        leftPinchStart = nil
      }

      /* Debug-sourced grabs are driven only by debugSpatial. */
      if let g = grab, g.source == .debug {
        return
      }

      let blocked = !holdEnabled || aligned || handMenuVisible || uiBlocked
      if !leftPinching || blocked {
        endGrab()
        return
      }

      let museUp = !(musePen?.isTipDown ?? false)
      let twoHand = rightPinching && !BlenderImmersiveState.shared.useHandAsPen && museUp

      let pivot: SIMD3<Float>
      let yaw: Float
      let dist: Float
      if twoHand {
        pivot = (leftPoint + rightPoint) * 0.5
        yaw = Self.yawOf(rightPoint - leftPoint) ?? (grab?.refYaw ?? 0)
        dist = simd_length(rightPoint - leftPoint)
      }
      else {
        pivot = leftPoint
        yaw = lastHandYaw
        dist = 0
      }

      if let g = grab {
        if g.twoHand != twoHand {
          /* Re-base on one↔two-hand switch so the scene does not jump. */
          beginGrab(source: .hand, twoHand: twoHand, pivotWorld: pivot, refYaw: yaw, refDist: dist)
        }
        else {
          moveGrab(pivotWorld: pivot, yaw: yaw, dist: dist)
        }
        return
      }

      guard let start = leftPinchStart, now.timeIntervalSince(start) >= engageSeconds,
        simd_length(leftPoint - leftPinchStartPos) > engageDistance
      else { return }
      beginGrab(source: .hand, twoHand: twoHand, pivotWorld: pivot, refYaw: yaw, refDist: dist)
    }

    // MARK: - Scale / reset

    func setHoldEnabled(_ enabled: Bool) {
      if holdEnabled == enabled { return }
      holdEnabled = enabled
      if !enabled {
        grab = nil
      }
      setStatus(enabled ? "ホールド: 待機" : "ホールド: OFF")
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

    func reset() {
      grab = nil
      holdTranslation = .zero
      holdYaw = 0
      viewScale = 1
      applyComposite()
      sendScale(force: false)
      publishState()
      setStatus(isAligned ? "ホールド: iPad合わせ中は無効" : "ホールド: リセット")
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
      default:
        return "err action=\(action) " + query()
      }
      return query()
    }

    private func query() -> String {
      let pos = worldRoot?.position ?? .zero
      return String(
        format: "ok bound=%d scale=%.3f pos=(%.3f,%.3f,%.3f) yaw=%.2f hold=%d preview=%d aligned=%d enabled=%d",
        worldRoot != nil ? 1 : 0,
        viewScale,
        pos.x, pos.y, pos.z,
        holdYaw,
        grab != nil ? 1 : 0,
        BlenderImmersiveBrushPreview.shared.isShowing ? 1 : 0,
        isAligned ? 1 : 0,
        holdEnabled ? 1 : 0)
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
