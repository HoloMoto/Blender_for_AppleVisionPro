/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Plan A / RealityMixer: align Vision Pro Immersive to an iPad via **screen** calib image.
 *
 * 1) iPad Window → fullscreen calib bitmap (same deterministic pattern).
 * 2) VP ImageTrackingProvider tracks that on-screen image (VP looks at iPad — not vice versa).
 * 3) Lock pins WorldAnchor; iPad may hide the calib image.
 * 4) Next: Mixed Reality Capture stream (extern/RealityMixerVisionPro) to iPad spectator.
 *
 * Short-lived ARKitSession — stop after lock to avoid fighting WorldMesh /
 * SharedAnchor sessions.
 */

import ARKit
import CoreGraphics
import Foundation
import ImageIO
import RealityKit
import simd
import UIKit

#if os(visionOS)

  public extension Notification.Name {
    static let blenderImmersiveSpectatorAlignChanged = Notification.Name(
      "blender.immersiveSpectatorAlignChanged")
  }

  @MainActor
  final class BlenderImmersiveSpectatorAlignController: ObservableObject {
    static let shared = BlenderImmersiveSpectatorAlignController()

    /** Physical width of the on-screen marker square (meters). */
    static let markerPhysicalWidthMeters: Float = 0.18

    /**
     * Screen-center → device origin offset in marker local space.
     * Approximate for a thin tablet; refine later per device.
     */
    static let markerToDevice = simd_float4x4(
      SIMD4<Float>(1, 0, 0, 0),
      SIMD4<Float>(0, 1, 0, 0),
      SIMD4<Float>(0, 0, 1, 0),
      SIMD4<Float>(0, 0, -0.008, 1))

    @Published private(set) var statusText = "iPad合わせ: 待機"
    @Published private(set) var isTracking = false
    @Published private(set) var markerVisible = false
    @Published private(set) var hasIpadPose = false
    @Published private(set) var locked = false

    private var arSession: ARKitSession?
    private var imageProvider: ImageTrackingProvider?
    private var updatesTask: Task<Void, Never>?
    /** Kept for MRC after align lock (RealityMixer keeps tracking the screen image). */
    private(set) var lastReferenceImage: ReferenceImage?
    private var latestMarkerVP: simd_float4x4?
    /** Exposed so MRC can seed cameraToWorld without a second ImageTracking session. */
    var latestMarkerWorldPoseForMRC: simd_float4x4? { latestMarkerVP }
    private var latestIpadWorldFromDevice: simd_float4x4?
    private var latestIpadPoseTime: TimeInterval = 0

    /** Spatial feedback: sits on sceneContainer (not worldRoot) so SharedAnchor reparent does not drag it. */
    private weak var vizParent: Entity?
    private var vizRoot: Entity?
    private var lastLoggedStatus: String = ""

    private init() {}

    /** Call once from Immersive RealityView with the scene container. */
    func attachVisualization(to sceneRoot: Entity) {
      if vizRoot?.parent === sceneRoot { return }
      vizRoot?.removeFromParent()
      let root = Entity()
      root.name = "SpectatorMarkerViz"
      root.isEnabled = false

      /* Semi-transparent plate matching physical marker size (0.18 m). */
      let plateMat = SimpleMaterial(
        color: UIColor.systemGreen.withAlphaComponent(0.45), isMetallic: false)
      let plate = ModelEntity(
        mesh: .generatePlane(
          width: Self.markerPhysicalWidthMeters, depth: Self.markerPhysicalWidthMeters),
        materials: [plateMat])
      plate.name = "SpectatorMarkerPlate"
      root.addChild(plate)

      /* Billboard icon floating above the plate — clear “detected” cue. */
      let iconMat = SimpleMaterial(color: UIColor.systemCyan, isMetallic: false)
      let icon = ModelEntity(
        mesh: .generateSphere(radius: 0.028), materials: [iconMat])
      icon.name = "SpectatorMarkerIcon"
      icon.position = SIMD3(0, 0.06, 0)
      icon.components.set(BillboardComponent())
      root.addChild(icon)

      /* Small upward cone as a pin. */
      let pinMat = SimpleMaterial(color: UIColor.systemYellow, isMetallic: false)
      let pin = ModelEntity(
        mesh: .generateCone(height: 0.05, radius: 0.018), materials: [pinMat])
      pin.name = "SpectatorMarkerPin"
      pin.position = SIMD3(0, 0.10, 0)
      root.addChild(pin)

      sceneRoot.addChild(root)
      vizParent = sceneRoot
      vizRoot = root
      syncVisualization()
      appendAlignLog("viz_attached")
    }

    func detachVisualization() {
      vizRoot?.removeFromParent()
      vizRoot = nil
      vizParent = nil
    }

    private func syncVisualization() {
      guard let root = vizRoot else { return }
      if markerVisible, let t = latestMarkerVP {
        root.transform.matrix = t
        root.isEnabled = true
      }
      else {
        root.isEnabled = false
      }
    }

    private func appendAlignLog(_ event: String) {
      let line =
        "\(ISO8601DateFormatter().string(from: Date())) \(event) tracking=\(isTracking) visible=\(markerVisible) pose=\(hasIpadPose) locked=\(locked) status=\(statusText)\n"
      guard
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      else { return }
      let url = docs.appendingPathComponent("spectator_align.log")
      if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: url.path) {
          if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
              try handle.seekToEnd()
              try handle.write(contentsOf: data)
            }
            catch {
              /* best-effort log */
            }
          }
        }
        else {
          try? data.write(to: url, options: .atomic)
        }
      }
      /* Avoid flooding on every ImageTracking update — log status changes only from callers. */
      _ = lastLoggedStatus
    }

    private func logStatusIfChanged() {
      if statusText != lastLoggedStatus {
        lastLoggedStatus = statusText
        appendAlignLog("status")
      }
    }

    func startTracking() async {
      guard !isTracking else { return }
      locked = false
      markerVisible = false
      latestMarkerVP = nil
      syncVisualization()
      statusText = "iPad合わせ: 権限確認…"
      publish()

      do {
        let session = ARKitSession()
        let auth = await session.requestAuthorization(for: [.worldSensing])
        if auth[.worldSensing] != .allowed {
          statusText = "iPad合わせ: World Sensing 権限が必要"
          publish()
          return
        }

        guard let cgImage = Self.makeReferenceCGImage() else {
          statusText = "iPad合わせ: 合わせ画像の生成失敗"
          publish()
          return
        }
        let ref = ReferenceImage(
          cgimage: cgImage,
          physicalSize: CGSize(
            width: CGFloat(Self.markerPhysicalWidthMeters),
            height: CGFloat(Self.markerPhysicalWidthMeters)),
          orientation: .up)
        lastReferenceImage = ref
        guard ImageTrackingProvider.isSupported else {
          statusText = "iPad合わせ: Image Tracking 非対応"
          publish()
          return
        }
        let provider = ImageTrackingProvider(referenceImages: [ref])
        try await session.run([provider])
        arSession = session
        imageProvider = provider
        isTracking = true
        statusText = "iPad合わせ: iPad画面の合わせ画像を検出中"
        listenForImageUpdates()
        publish()
      }
      catch {
        statusText = "iPad合わせ: 開始失敗 \(error.localizedDescription)"
        await stopTracking()
        publish()
      }
    }

    func stopTracking() async {
      updatesTask?.cancel()
      updatesTask = nil
      imageProvider = nil
      if let session = arSession {
        await session.stop()
      }
      arSession = nil
      isTracking = false
      markerVisible = false
      syncVisualization()
      if !locked {
        statusText = "iPad合わせ: 停止"
      }
      publish()
    }

    /** Try to lock origin from current marker (+ optional iPad pose). */
    func lockAlignment() async {
      guard let markerVP = latestMarkerVP else {
        statusText = "iPad合わせ: 合わせ画像未検出"
        publish()
        return
      }

      var vpFromIpadWorld = markerVP * Self.markerToDevice
      if let ipadWorldFromDevice = latestIpadWorldFromDevice,
        Date.timeIntervalSinceReferenceDate - latestIpadPoseTime < 1.5
      {
        vpFromIpadWorld = markerVP * Self.markerToDevice * ipadWorldFromDevice.inverse
        statusText = "iPad合わせ: 画像+ポーズでロック"
      }
      else {
        statusText = "iPad合わせ: 合わせ画像のみでロック"
      }

      if let anchor = BlenderImmersiveState.shared.sharedAnchor {
        await anchor.alignAtTransform(vpFromIpadWorld)
      }
      locked = true
      /* Keep calib image available for MRC ImageTracking (RealityMixer). */
      let refImage = lastReferenceImage
      await stopTracking()
      statusText = "iPad合わせ: ロック済 — MRC起動中"
      publish()
      /* No second ARKitSession — MRC is TCP-only + SharedAnchor world tracking. */
      await BlenderImmersiveMRCController.shared.startAfterAlignLock(referenceImage: refImage)
      if BlenderImmersiveMRCController.shared.serverListening {
        let ip = BlenderImmersiveMRCController.shared.localIPv4
        statusText = "ロック済 MRC :13370 \(ip.isEmpty ? "" : ip)"
      }
      else {
        let mrc = BlenderImmersiveMRCController.shared.statusText
        statusText = "ロック済 — \(mrc)"
      }
      publish()
    }

    func ingestIpadPose(_ deviceFromIpadWorld: simd_float4x4) {
      /* Payload is T_ipadWorld←device (device pose in iPad ARKit world). */
      latestIpadWorldFromDevice = deviceFromIpadWorld
      latestIpadPoseTime = Date.timeIntervalSinceReferenceDate
      hasIpadPose = true
      if isTracking && !locked {
        statusText =
          markerVisible
          ? "iPad合わせ: 画像+ポーズ受信 — ロック可"
          : "iPad合わせ: ポーズ受信・画像検出中"
      }
      publish()
    }

    private func listenForImageUpdates() {
      updatesTask?.cancel()
      updatesTask = Task { [weak self] in
        guard let self, let provider = self.imageProvider else { return }
        for await update in provider.anchorUpdates {
          guard !Task.isCancelled else { return }
          let anchor = update.anchor
          switch update.event {
          case .added, .updated:
            if anchor.isTracked {
              self.latestMarkerVP = anchor.originFromAnchorTransform
              self.markerVisible = true
              if !self.locked {
                self.statusText =
                  self.hasIpadPose
                  ? "iPad合わせ: 画像+ポーズ — ロック可"
                  : "iPad合わせ: 合わせ画像検出 — ロック可"
              }
              self.syncVisualization()
              self.publish()
            }
            else {
              self.markerVisible = false
              self.syncVisualization()
              if self.isTracking && !self.locked {
                self.statusText = "iPad合わせ: 合わせ画像ロスト"
                self.publish()
              }
            }
          case .removed:
            self.markerVisible = false
            self.latestMarkerVP = nil
            self.syncVisualization()
            if self.isTracking && !self.locked {
              self.statusText = "iPad合わせ: 合わせ画像消失"
              self.publish()
            }
          @unknown default:
            break
          }
        }
      }
    }

    private func publish() {
      syncVisualization()
      logStatusIfChanged()
      NotificationCenter.default.post(name: .blenderImmersiveSpectatorAlignChanged, object: nil)
    }

    /** Deterministic high-contrast marker shared with iPad fullscreen display. */
    static func makeReferenceCGImage() -> CGImage? {
      let size = 512
      let bytesPerRow = size * 4
      var pixels = [UInt8](repeating: 255, count: size * size * 4)
      /* Unique non-periodic cells (avoid stripes/rings — ARKit rejects those). */
      var seed: UInt64 = 0xB1E5_50A1_1A11_50A1
      func nextBit() -> Bool {
        seed = seed &* 6364136223846793005 &+ 1
        return ((seed >> 63) & 1) == 1
      }
      let cell = 32
      var bits = [[Bool]](repeating: [Bool](repeating: false, count: size / cell), count: size / cell)
      for cy in 0..<(size / cell) {
        for cx in 0..<(size / cell) {
          bits[cy][cx] = nextBit()
        }
      }
      /* Finder-like corners for orientation. */
      for cy in 0..<3 {
        for cx in 0..<3 {
          bits[cy][cx] = (cx == 1 && cy == 1) ? false : true
          bits[cy][size / cell - 1 - cx] = (cx == 1 && cy == 1) ? false : true
          bits[size / cell - 1 - cy][cx] = (cx == 1 && cy == 1) ? false : true
        }
      }
      for y in 0..<size {
        for x in 0..<size {
          let border = x < 24 || y < 24 || x >= size - 24 || y >= size - 24
          let on: Bool
          if border {
            on = false
          }
          else {
            on = bits[y / cell][x / cell]
          }
          let i = (y * size + x) * 4
          let v: UInt8 = on ? 0 : 255
          pixels[i] = v
          pixels[i + 1] = v
          pixels[i + 2] = v
          pixels[i + 3] = 255
        }
      }
      let cs = CGColorSpaceCreateDeviceRGB()
      guard
        let ctx = CGContext(
          data: &pixels,
          width: size,
          height: size,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: cs,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else {
        return nil
      }
      return ctx.makeImage()
    }

    /** PNG data for iPad fullscreen (same pixels). */
    static func makeReferencePNGData() -> Data? {
      guard let cg = makeReferenceCGImage() else { return nil }
      let data = NSMutableData()
      guard let dest = CGImageDestinationCreateWithData(
        data as CFMutableData, "public.png" as CFString, 1, nil)
      else {
        return nil
      }
      CGImageDestinationAddImage(dest, cg, nil)
      guard CGImageDestinationFinalize(dest) else { return nil }
      return data as Data
    }
  }

#endif
