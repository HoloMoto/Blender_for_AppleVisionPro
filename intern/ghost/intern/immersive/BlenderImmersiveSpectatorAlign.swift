/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Plan A: align Vision Pro Immersive space to an iPad via screen marker.
 *
 * 1) VP ImageTrackingProvider tracks a shared high-contrast reference image
 *    (same deterministic bitmap iPad can fullscreen).
 * 2) Optional: iPad ARKit device pose arrives over Multipeer (`t=ipadPose`).
 * 3) Lock computes T_vp←ipadWorld and pins a WorldAnchor via SharedAnchor.
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
    private var latestMarkerVP: simd_float4x4?
    private var latestIpadWorldFromDevice: simd_float4x4?
    private var latestIpadPoseTime: TimeInterval = 0

    private init() {
      BlenderImmersiveMultiuserSession.shared.onRemoteIpadPose = { [weak self] matrix in
        Task { @MainActor in
          self?.ingestIpadPose(matrix)
        }
      }
    }

    func startTracking() async {
      guard !isTracking else { return }
      locked = false
      markerVisible = false
      latestMarkerVP = nil
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
          statusText = "iPad合わせ: マーカー生成失敗"
          publish()
          return
        }
        let ref = ReferenceImage(
          cgimage: cgImage,
          physicalSize: CGSize(
            width: CGFloat(Self.markerPhysicalWidthMeters),
            height: CGFloat(Self.markerPhysicalWidthMeters)),
          orientation: .up)
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
        statusText = "iPad合わせ: マーカー捜索中（iPadにマーカー全画面）"
        listenForImageUpdates()
        publish()
      }
      catch {
        statusText = "iPad合わせ: 開始失敗 \(error.localizedDescription)"
        stopTracking()
        publish()
      }
    }

    func stopTracking() {
      updatesTask?.cancel()
      updatesTask = nil
      imageProvider = nil
      arSession = nil
      isTracking = false
      markerVisible = false
      if !locked {
        statusText = "iPad合わせ: 停止"
      }
      publish()
    }

    /** Try to lock origin from current marker (+ optional iPad pose). */
    func lockAlignment() async {
      guard let markerVP = latestMarkerVP else {
        statusText = "iPad合わせ: マーカー未検出"
        publish()
        return
      }

      var vpFromIpadWorld = markerVP * Self.markerToDevice
      if let ipadWorldFromDevice = latestIpadWorldFromDevice,
        Date.timeIntervalSinceReferenceDate - latestIpadPoseTime < 1.5
      {
        vpFromIpadWorld = markerVP * Self.markerToDevice * ipadWorldFromDevice.inverse
        statusText = "iPad合わせ: マーカー+ポーズでロック"
      }
      else {
        statusText = "iPad合わせ: マーカーのみでロック（ポーズ無し）"
      }

      if let anchor = BlenderImmersiveState.shared.sharedAnchor {
        await anchor.alignAtTransform(vpFromIpadWorld)
      }
      locked = true
      stopTracking()
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
          ? "iPad合わせ: マーカー+ポーズ受信 — ロック可"
          : "iPad合わせ: ポーズ受信・マーカー捜索中"
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
                  ? "iPad合わせ: マーカー+ポーズ — ロック可"
                  : "iPad合わせ: マーカー検出 — ロック可（ポーズ任意）"
              }
              self.publish()
            }
            else {
              self.markerVisible = false
              if self.isTracking && !self.locked {
                self.statusText = "iPad合わせ: マーカーロスト"
                self.publish()
              }
            }
          case .removed:
            self.markerVisible = false
            self.latestMarkerVP = nil
            if self.isTracking && !self.locked {
              self.statusText = "iPad合わせ: マーカー消失"
              self.publish()
            }
          @unknown default:
            break
          }
        }
      }
    }

    private func publish() {
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
