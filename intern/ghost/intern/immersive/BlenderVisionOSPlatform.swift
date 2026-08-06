/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Vision Pro platform publisher — feeds #BLENDER_VISIONOS_* for Python add-ons.
 *
 * Always-on while Immersive Space is open (independent of HandPen sculpt mode).
 * HandLocation subset that RealityKit exposes today: wrist / palm / thumb / index.
 * Middle/ring/little fields stay in the ABI (filled from palm until SDK grows).
 */

import Foundation
import RealityKit
import simd

#if os(visionOS)

  @_silgen_name("BLENDER_VISIONOS_hand_publish")
  private func BLENDER_VISIONOS_hand_publish(_ snap: UnsafePointer<BLENDER_VISIONOS_HandSnapshotC>)

  @_silgen_name("BLENDER_VISIONOS_set_immersive_active")
  private func BLENDER_VISIONOS_set_immersive_active(_ active: Int32)

  /** Mirror of WM_ios_visionos_api.h — keep in sync. */
  private struct BLENDER_VISIONOS_Vec3C {
    var x: Float = 0
    var y: Float = 0
    var z: Float = 0
  }

  private struct BLENDER_VISIONOS_HandSideC {
    var tracked: UInt32 = 0
    var wrist = BLENDER_VISIONOS_Vec3C()
    var palm = BLENDER_VISIONOS_Vec3C()
    var thumb_tip = BLENDER_VISIONOS_Vec3C()
    var index_tip = BLENDER_VISIONOS_Vec3C()
    var middle_tip = BLENDER_VISIONOS_Vec3C()
    var ring_tip = BLENDER_VISIONOS_Vec3C()
    var little_tip = BLENDER_VISIONOS_Vec3C()
    var pinch: Float = -1
    var _pad0: Float = 0
  }

  private struct BLENDER_VISIONOS_HandSnapshotC {
    var struct_size: UInt32 = 0
    var api_version: UInt32 = 1
    var timestamp: Double = 0
    var immersive_active: UInt32 = 0
    var _pad1: UInt32 = 0
    var left = BLENDER_VISIONOS_HandSideC()
    var right = BLENDER_VISIONOS_HandSideC()
  }

  @MainActor
  final class BlenderVisionOSPlatformPublisher: ObservableObject {
    private weak var worldRoot: Entity?
    private var sampleTask: Task<Void, Never>?
    private var attachGeneration: UInt = 0

    private struct HandAnchors {
      var wrist: AnchorEntity
      var palm: AnchorEntity
      var thumb: AnchorEntity
      var index: AnchorEntity
    }

    private var left: HandAnchors?
    private var right: HandAnchors?

    func attach(to root: Entity) {
      detach()
      worldRoot = root
      attachGeneration &+= 1
      let generation = attachGeneration

      left = makeHand(.left, root: root)
      right = makeHand(.right, root: root)
      BLENDER_VISIONOS_set_immersive_active(1)

      sampleTask = Task { @MainActor [weak self] in
        await self?.runSampleLoop(generation: generation)
      }
    }

    func detach() {
      attachGeneration &+= 1
      sampleTask?.cancel()
      sampleTask = nil
      removeHand(&left)
      removeHand(&right)
      worldRoot = nil
      BLENDER_VISIONOS_set_immersive_active(0)
    }

    private func makeHand(_ chirality: AnchoringComponent.Target.Chirality, root: Entity)
      -> HandAnchors
    {
      func anchor(_ loc: AnchoringComponent.Target.HandLocation, name: String) -> AnchorEntity {
        let a = AnchorEntity(.hand(chirality, location: loc), trackingMode: .continuous)
        a.name = name
        root.addChild(a)
        return a
      }
      let side = chirality == .left ? "L" : "R"
      return HandAnchors(
        wrist: anchor(.wrist, name: "VisionOSHand\(side)Wrist"),
        palm: anchor(.palm, name: "VisionOSHand\(side)Palm"),
        thumb: anchor(.thumbTip, name: "VisionOSHand\(side)Thumb"),
        index: anchor(.indexFingerTip, name: "VisionOSHand\(side)Index"))
    }

    private func removeHand(_ hand: inout HandAnchors?) {
      guard let h = hand else { return }
      h.wrist.removeFromParent()
      h.palm.removeFromParent()
      h.thumb.removeFromParent()
      h.index.removeFromParent()
      hand = nil
    }

    private func runSampleLoop(generation: UInt) async {
      _ = await BlenderImmersiveSpatialTracking.ensure(capabilities: [.hand])
      while !Task.isCancelled, generation == attachGeneration {
        guard let root = worldRoot else { break }
        var snap = BLENDER_VISIONOS_HandSnapshotC()
        snap.struct_size = UInt32(MemoryLayout<BLENDER_VISIONOS_HandSnapshotC>.size)
        snap.api_version = 1
        snap.timestamp = Date().timeIntervalSinceReferenceDate
        snap.immersive_active = 1
        if let left {
          snap.left = sampleSide(left, root: root)
        }
        if let right {
          snap.right = sampleSide(right, root: root)
        }
        withUnsafePointer(to: snap) { ptr in
          BLENDER_VISIONOS_hand_publish(ptr)
        }
        try? await Task.sleep(nanoseconds: 16_666_667) /* ~60 Hz */
      }
    }

    private func sampleSide(_ hand: HandAnchors, root: Entity) -> BLENDER_VISIONOS_HandSideC {
      var side = BLENDER_VISIONOS_HandSideC()
      let tracked = hand.palm.isAnchored || hand.wrist.isAnchored
      side.tracked = tracked ? 1 : 0
      let palm = blenderPos(hand.palm, root: root)
      side.wrist = vec3(blenderPos(hand.wrist, root: root))
      side.palm = vec3(palm)
      side.thumb_tip = vec3(blenderPos(hand.thumb, root: root))
      side.index_tip = vec3(blenderPos(hand.index, root: root))
      /* ABI reserved; RealityKit HandLocation has no middle/ring/little yet. */
      side.middle_tip = side.palm
      side.ring_tip = side.palm
      side.little_tip = side.palm
      if tracked && hand.thumb.isAnchored && hand.index.isAnchored {
        let d = simd_length(
          blenderPos(hand.thumb, root: root) - blenderPos(hand.index, root: root))
        side.pinch = max(0, min(1, 1 - (d - 0.01) / 0.05))
      }
      else {
        side.pinch = -1
      }
      return side
    }

    private func blenderPos(_ anchor: AnchorEntity, root: Entity) -> SIMD3<Float> {
      let world = anchor.position(relativeTo: nil)
      let local = root.convert(position: world, from: nil)
      return BlenderImmersiveCoords.realityKitToBlender(local)
    }

    private func vec3(_ v: SIMD3<Float>) -> BLENDER_VISIONOS_Vec3C {
      BLENDER_VISIONOS_Vec3C(x: v.x, y: v.y, z: v.z)
    }
  }

#endif
