/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Live Mesh Bridge payloads + RealityKit MeshResource builder (5.0.1).
 * Verts arrive in Blender object-relative space; convert to RealityKit here.
 *
 * MeshResource.generate is intentionally off the MainActor — TF-153 ran it
 * on MainActor at ~20 Hz and starved Logitech Muse pose/input sampling.
 */

import Foundation
import RealityKit
import simd
import UIKit

#if os(visionOS)

  public struct BlenderImmersiveLiveMeshPayload {
    public let name: String
    public let verts: Data
    public let indices: Data
    public let color: SIMD4<Float>
  }

  enum BlenderImmersiveLiveMeshBuilder {
    /// Generation counter so superseded sculpt frames drop instead of queueing MainActor.
    static var applyGeneration: UInt = 0

    @MainActor
    static func apply(payloads: [BlenderImmersiveLiveMeshPayload], to worldRoot: Entity) async
      -> Entity?
    {
      applyGeneration &+= 1
      let generation = applyGeneration

      /* Build MeshResources off the main actor so Muse / HandPen keep sampling. */
      let built: [(String, MeshResource, SIMD4<Float>)] = await Task.detached(priority: .userInitiated) {
        var out: [(String, MeshResource, SIMD4<Float>)] = []
        out.reserveCapacity(payloads.count)
        for payload in payloads {
          if let mesh = await makeMeshResource(from: payload) {
            out.append((payload.name, mesh, payload.color))
          }
        }
        return out
      }.value

      guard generation == applyGeneration else {
        /* A newer live-mesh commit superseded this frame — drop it. */
        return nil
      }

      let liveRoot = Entity()
      liveRoot.name = "BlenderImmersiveLive"

      for (name, mesh, colorVec) in built {
        let color = UIColor(
          red: CGFloat(colorVec.x),
          green: CGFloat(colorVec.y),
          blue: CGFloat(colorVec.z),
          alpha: CGFloat(max(0.05, colorVec.w)))
        let material = SimpleMaterial(color: color, isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = name
        /* Collisions only for grab/hit — skip mid-sculpt storms (Muse needs CPU). */
        liveRoot.addChild(entity)
      }

      guard generation == applyGeneration else {
        return nil
      }

      let oldLive = worldRoot.children.filter { $0.name == "BlenderImmersiveLive" }
      let oldUSD = worldRoot.children.filter { $0.name == "BlenderImmersiveUSD" }
      worldRoot.addChild(liveRoot)
      for old in oldLive {
        old.removeFromParent()
      }
      /* Prefer live geometry — hide USD snapshot when bridge is active. */
      for usd in oldUSD {
        usd.isEnabled = false
      }
      return liveRoot
    }

    nonisolated private static func makeMeshResource(from payload: BlenderImmersiveLiveMeshPayload)
      async -> MeshResource?
    {
      let vertFloats = payload.verts.withUnsafeBytes { buf -> [Float] in
        Array(buf.bindMemory(to: Float.self))
      }
      let indexInts = payload.indices.withUnsafeBytes { buf -> [UInt32] in
        Array(buf.bindMemory(to: UInt32.self))
      }
      let vertCount = vertFloats.count / 3
      let triCount = indexInts.count / 3
      guard vertCount > 0, triCount > 0 else { return nil }

      var positions: [SIMD3<Float>] = []
      positions.reserveCapacity(vertCount)
      for i in 0..<vertCount {
        let bl = SIMD3(vertFloats[i * 3], vertFloats[i * 3 + 1], vertFloats[i * 3 + 2])
        positions.append(BlenderImmersiveCoords.blenderToRealityKit(bl))
      }

      var descriptor = MeshDescriptor(name: payload.name)
      descriptor.positions = MeshBuffers.Positions(positions)
      descriptor.primitives = .triangles(indexInts)

      do {
        return try await MeshResource.generate(from: [descriptor])
      }
      catch {
        print("[immersive] live mesh generate failed \(payload.name): \(error)")
        return nil
      }
    }

    @MainActor
    static func clear(from worldRoot: Entity) {
      applyGeneration &+= 1
      for child in worldRoot.children where child.name == "BlenderImmersiveLive" {
        child.removeFromParent()
      }
      for usd in worldRoot.children where usd.name == "BlenderImmersiveUSD" {
        usd.isEnabled = true
      }
    }
  }

#else

  public struct BlenderImmersiveLiveMeshPayload {
    public let name: String
    public let verts: Data
    public let indices: Data
    public let color: SIMD4<Float>
  }

#endif
