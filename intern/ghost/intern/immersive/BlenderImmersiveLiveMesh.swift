/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Live Mesh Bridge payloads + RealityKit MeshResource builder (5.0.1).
 * Verts arrive in Blender object-relative space; convert to RealityKit here.
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
    @MainActor
    static func apply(payloads: [BlenderImmersiveLiveMeshPayload], to worldRoot: Entity) async
      -> Entity
    {
      let liveRoot = Entity()
      liveRoot.name = "BlenderImmersiveLive"

      for payload in payloads {
        guard let entity = await makeEntity(from: payload) else { continue }
        liveRoot.addChild(entity)
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

    @MainActor
    private static func makeEntity(from payload: BlenderImmersiveLiveMeshPayload) async -> ModelEntity?
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
        let mesh = try await MeshResource.generate(from: [descriptor])
        let color = UIColor(
          red: CGFloat(payload.color.x),
          green: CGFloat(payload.color.y),
          blue: CGFloat(payload.color.z),
          alpha: CGFloat(max(0.05, payload.color.w)))
        let material = SimpleMaterial(color: color, isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = payload.name
        entity.generateCollisionShapes(recursive: false)
        return entity
      }
      catch {
        print("[immersive] live mesh generate failed \(payload.name): \(error)")
        return nil
      }
    }

    @MainActor
    static func clear(from worldRoot: Entity) {
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
