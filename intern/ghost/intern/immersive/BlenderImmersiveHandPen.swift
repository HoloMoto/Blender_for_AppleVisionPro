/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Right-hand sculpt / Anim input for Immersive Space (Muse substitute).
 *
 * Sculpt: tip = Palm / dorsum. Anim (etc.): tip = pinch midpoint (thumb↔index).
 * Pinch = tip down (unless proximity mode). Feeds WM_IOS_immersive_muse_sample.
 */

import ARKit
import Foundation
import RealityKit
import UIKit
import simd

#if os(visionOS)

  @_silgen_name("WM_IOS_immersive_muse_sample")
  private func WM_IOS_immersive_muse_sample(
    _ x: Float, _ y: Float, _ z: Float, _ pressure: Float, _ tipPressed: Int32)

  @_silgen_name("WM_IOS_immersive_muse_sculpt_engaged")
  private func WM_IOS_immersive_muse_sculpt_engaged() -> Int32

  @MainActor
  final class BlenderImmersiveHandPenController: ObservableObject {
    @Published private(set) var statusText = "Hand: OFF"
    @Published private(set) var isPinching = false

    private var rootEntity: Entity?
    /** Brush axis — palm / dorsal side of the right hand. */
    private var palmAnchor: AnchorEntity?
    private var indexTip: AnchorEntity?
    private var thumbTip: AnchorEntity?
    private var tipVisual: ModelEntity?
    private var sampleTask: Task<Void, Never>?
    private var attachGeneration: UInt = 0
    private var lastLoggedPinch = false
    private var arSession = ARKitSession()

    /** Pinch distance threshold in meters (index tip ↔ thumb tip). */
    private let pinchThreshold: Float = 0.028
    private let pinchRelease: Float = 0.038

    /**
     * Offset from palm center toward the dorsum / back of hand (meters, palm-local).
     * ARKit palm +Y faces out of the palm surface; negative Y sits on 手の甲.
     */
    private let dorsumOffsetLocal = SIMD3<Float>(0.0, -0.012, 0.0)

    func attach(to root: Entity) {
      rootEntity = root
      attachGeneration &+= 1
      let generation = attachGeneration

      let palm = AnchorEntity(.hand(.right, location: .palm), trackingMode: .continuous)
      palm.name = "HandPenPalm"
      let index = AnchorEntity(.hand(.right, location: .indexFingerTip), trackingMode: .continuous)
      index.name = "HandPenIndexTip"
      let thumb = AnchorEntity(.hand(.right, location: .thumbTip), trackingMode: .continuous)
      thumb.name = "HandPenThumbTip"

      var material = UnlitMaterial(color: .systemPink)
      material.color = .init(tint: UIColor.systemPink.withAlphaComponent(0.35))
      material.blending = .transparent(opacity: .init(floatLiteral: 0.35))
      let tip = ModelEntity(
        mesh: .generateSphere(radius: 0.028),
        materials: [material])
      tip.name = "HandPenTipVisual"
      tip.scale = SIMD3(repeating: 0.7)
      tip.components.set(OpacityComponent(opacity: 0.4))
      tip.isEnabled = false
      palm.addChild(tip)
      tip.position = dorsumOffsetLocal

      root.addChild(palm)
      root.addChild(index)
      root.addChild(thumb)
      palmAnchor = palm
      indexTip = index
      thumbTip = thumb
      tipVisual = tip

      sampleTask?.cancel()
      sampleTask = Task { @MainActor [weak self] in
        await self?.bootstrapAndSample(generation: generation)
      }
      refreshStatus()
    }

    func detach() {
      attachGeneration &+= 1
      sampleTask?.cancel()
      sampleTask = nil
      tipVisual?.removeFromParent()
      tipVisual = nil
      palmAnchor?.removeFromParent()
      indexTip?.removeFromParent()
      thumbTip?.removeFromParent()
      palmAnchor = nil
      indexTip = nil
      thumbTip = nil
      rootEntity = nil
      isPinching = false
      lastLoggedPinch = false
      /* Tip-up so sculpt strokes end cleanly when leaving Immersive. */
      WM_IOS_immersive_muse_sample(0, 0, 0, 0, 0)
      statusText = "Hand: OFF"
    }

    func refreshStatus() {
      let on = BlenderImmersiveState.shared.useHandAsPen
      if !on {
        statusText = "Hand: OFF"
        tipVisual?.isEnabled = false
        return
      }
      if BlenderImmersiveState.shared.handMenuMode == 0 {
        statusText = "Hand: 閲覧専用（Obj）"
        tipVisual?.isEnabled = true
        return
      }
      if BlenderImmersiveState.shared.handMenuMode == 4 {
        let proximity = BlenderImmersiveState.shared.handProximitySculpt
        let targetObj = BlenderImmersiveState.shared.animTargetMode == 1
        let tracked = (indexTip?.isAnchored == true) || (palmAnchor?.isAnchored == true)
        if tracked {
          if targetObj {
            statusText = proximity ? "Hand: Anim/Obj 近接移動" : "Hand: Anim/Obj ピンチで移動"
          }
          else {
            statusText = proximity ? "Hand: Anim ピンチ位置/近接" : "Hand: Anim ピンチ位置で掴み"
          }
        }
        else {
          statusText = "Hand: Anim 手を追跡中…"
        }
        tipVisual?.isEnabled = on
        return
      }
      let proximity = BlenderImmersiveState.shared.handProximitySculpt
      let tracked = palmAnchor?.isAnchored == true
      if tracked {
        if proximity {
          statusText = "Hand: Palm=ブラシ / 近接で描画（頂点距離）"
        }
        else {
          statusText = isPinching ? "Hand: Palmで描画中" : "Hand: Palm=ブラシ / ピンチで描画"
        }
      }
      else {
        statusText = "Hand: 右手Palmを追跡中…"
      }
      tipVisual?.isEnabled = on
    }

    private func bootstrapAndSample(generation: UInt) async {
      statusText = "Hand: 権限確認中…"
      let authorized = await requestHandTrackingAuthorization()
      guard generation == attachGeneration else { return }
      if !authorized {
        statusText = "Hand: 手トラッキング権限が必要です"
        return
      }

      let ok = await BlenderImmersiveSpatialTracking.ensure(capabilities: [.hand])
      guard generation == attachGeneration else { return }
      if !ok {
        statusText = "Hand: トラッキング開始に失敗"
        return
      }

      refreshStatus()
      await runSampleLoop(generation: generation)
    }

    private func requestHandTrackingAuthorization() async -> Bool {
      let types: [ARKitSession.AuthorizationType] = [.handTracking]
      let current = await arSession.queryAuthorization(for: types)
      print("[immersive] HandPen auth query: \(current)")
      if current[.handTracking] == .allowed {
        return true
      }
      let results = await arSession.requestAuthorization(for: types)
      print("[immersive] HandPen auth request: \(results)")
      return results[.handTracking] == .allowed || current[.handTracking] == .allowed
    }

    private func runSampleLoop(generation: UInt) async {
      var ticks = 0
      while !Task.isCancelled && generation == attachGeneration {
        let useHand = BlenderImmersiveState.shared.useHandAsPen
        tipVisual?.isEnabled = useHand

        if !useHand {
          if isPinching {
            isPinching = false
            WM_IOS_immersive_muse_sample(0, 0, 0, 0, 0)
            logPinch(false)
          }
          if ticks % 30 == 0 {
            refreshStatus()
          }
          ticks += 1
          try? await Task.sleep(nanoseconds: 33_000_000)
          continue
        }

        guard let palm = palmAnchor, let index = indexTip, let thumb = thumbTip,
          let root = rootEntity
        else {
          try? await Task.sleep(nanoseconds: 33_000_000)
          continue
        }

        /* Sculpt: palm tip. Anim/Edit/VPaint: pinch midpoint for hit testing. */
        let menuMode = BlenderImmersiveState.shared.handMenuMode
        let usePinchPoint = (menuMode == 4 || menuMode == 1 || menuMode == 3)

        let palmReady = palm.isAnchored
        let pinchReady = index.isAnchored && thumb.isAnchored
        guard palmReady || (usePinchPoint && pinchReady) else {
          if ticks % 30 == 0 {
            refreshStatus()
          }
          ticks += 1
          try? await Task.sleep(nanoseconds: 11_111_111)
          continue
        }

        var indexWorld = SIMD3<Float>.zero
        var thumbWorld = SIMD3<Float>.zero
        var pinch = isPinching
        if pinchReady {
          indexWorld = SIMD3(
            index.transformMatrix(relativeTo: nil).columns.3.x,
            index.transformMatrix(relativeTo: nil).columns.3.y,
            index.transformMatrix(relativeTo: nil).columns.3.z)
          thumbWorld = SIMD3(
            thumb.transformMatrix(relativeTo: nil).columns.3.x,
            thumb.transformMatrix(relativeTo: nil).columns.3.y,
            thumb.transformMatrix(relativeTo: nil).columns.3.z)
          let dist = simd_length(indexWorld - thumbWorld)
          if pinch {
            if dist > pinchRelease {
              pinch = false
            }
          }
          else if dist < pinchThreshold {
            pinch = true
          }
        }

        if pinch != isPinching {
          isPinching = pinch
          logPinch(pinch)
          refreshStatus()
        }

        let tipWorld: SIMD3<Float>
        if usePinchPoint && pinchReady {
          tipWorld = (indexWorld + thumbWorld) * 0.5
          if let tip = tipVisual, tip.parent !== root {
            tip.removeFromParent()
            root.addChild(tip)
          }
          tipVisual?.position = root.convert(position: tipWorld, from: nil)
        }
        else if palmReady {
          tipWorld = palm.convert(position: dorsumOffsetLocal, to: nil)
          if let tip = tipVisual, tip.parent !== palm {
            tip.removeFromParent()
            palm.addChild(tip)
            tip.position = dorsumOffsetLocal
          }
        }
        else {
          ticks += 1
          try? await Task.sleep(nanoseconds: 11_111_111)
          continue
        }

        let blender = realityKitWorldToBlender(tipWorld, root: root)
        let proximityMode = BlenderImmersiveState.shared.handProximitySculpt
        let viewOnly = menuMode == 0
        let armed = !viewOnly && proximityMode
        let pinchActive = !viewOnly && !proximityMode && pinch
        let tipPressed: Int32 = (armed || pinchActive) ? 1 : 0
        let sculptEngaged = proximityMode && WM_IOS_immersive_muse_sculpt_engaged() != 0
        let tipDownVisual = pinchActive || sculptEngaged
        updateTipVisual(tipDown: tipDownVisual)

        WM_IOS_immersive_muse_sample(blender.x, blender.y, blender.z, tipPressed != 0 ? 0.75 : 0, tipPressed)
        if BlenderImmersiveMultiuserSession.shared.isActive {
          BlenderImmersiveMultiuserSession.shared.sendLocalPresence(
            x: blender.x, y: blender.y, z: blender.z, tipDown: tipDownVisual)
        }

        ticks += 1
        try? await Task.sleep(nanoseconds: 11_111_111)
      }
    }

    private func updateTipVisual(tipDown: Bool) {
      guard let tip = tipVisual else { return }
      let scale: Float = tipDown ? 1.6 : 0.7
      tip.scale = SIMD3(repeating: scale)
      let alpha: Float = tipDown ? 0.55 : 0.35
      let color = tipDown ? UIColor.systemRed : UIColor.systemPink
      var material = UnlitMaterial(color: color)
      material.color = .init(tint: color.withAlphaComponent(CGFloat(alpha)))
      material.blending = .transparent(opacity: .init(floatLiteral: alpha))
      tip.model?.materials = [material]
      tip.components.set(OpacityComponent(opacity: alpha))
    }

    private func logPinch(_ down: Bool) {
      guard down != lastLoggedPinch else { return }
      lastLoggedPinch = down
      let msg = "hand pen pinch \(down ? "DOWN" : "UP")"
      print("[immersive] \(msg)")
      BlenderIOSDiagnosticLog.bootSwiftOnly(msg)
    }

    private func realityKitWorldToBlender(_ world: SIMD3<Float>, root: Entity) -> SIMD3<Float> {
      let local = root.convert(position: world, from: nil)
      return BlenderImmersiveCoords.realityKitToBlender(local)
    }
  }

#endif
