/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * World mesh (ARKit scene reconstruction) publisher for #BLENDER_VISIONOS_world_mesh_*.
 *
 * Accumulates SceneReconstructionProvider mesh anchors into one flat vertex /
 * index buffer, converts vertices into Blender world space (same convention
 * as hands — relative to the Immersive worldRoot, then RealityKit → Blender),
 * caps to the native MAX_VERTS / MAX_INDICES, and publishes at ~5 Hz while dirty.
 *
 * Packing rules (important for floors+walls):
 * - Prefer low Blender-Z anchors first (floors before tall walls).
 * - If one anchor does not fit the budget, **skip it and keep packing others**
 *   (never abort the whole accumulate — that left only "one group").
 * - Oversized single anchors are triangle-strided before insert.
 *
 * Soft-fails (logs once) when scene reconstruction is unsupported/unavailable
 * — never crashes the Immersive Space.
 */

import ARKit
import Foundation
import RealityKit
import simd

#if os(visionOS)

  @_silgen_name("BLENDER_VISIONOS_world_mesh_publish")
  private func BLENDER_VISIONOS_world_mesh_publish(
    _ revision: UInt32,
    _ xyz: UnsafePointer<Float>?,
    _ vertexCount: UInt32,
    _ indices: UnsafePointer<UInt32>?,
    _ indexCount: UInt32,
    _ truncated: Int32)

  private extension GeometrySource {
    /** Read this source as tightly packed float3 vertices (respects stride). */
    func asSIMD3Array() -> [SIMD3<Float>] {
      var result: [SIMD3<Float>] = []
      result.reserveCapacity(count)
      let base = buffer.contents().advanced(by: offset)
      for i in 0..<count {
        let p = base.advanced(by: stride * i).assumingMemoryBound(to: Float.self)
        result.append(SIMD3(p[0], p[1], p[2]))
      }
      return result
    }
  }

  @MainActor
  final class BlenderVisionOSWorldMesh: ObservableObject {
    /** Mirror of WM_ios_visionos_api.h — keep in sync. */
    private static let maxVerts = 16384
    private static let maxIndices = 49152
    /** Publish interval while dirty (was 500ms / 2 Hz — felt laggy). */
    private static let publishNanos: UInt64 = 200_000_000
    /** Single-anchor soft cap before triangle stride (leave room for more pieces). */
    private static let perAnchorSoftVerts = 6000

    private struct MeshEntry {
      var vertices: [SIMD3<Float>]
      var indices: [UInt32]
      var minZ: Float
      var maxZ: Float
    }

    private var session: ARKitSession?
    private var provider: SceneReconstructionProvider?
    private weak var worldRoot: Entity?
    private var sessionTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var meshes: [UUID: MeshEntry] = [:]
    private var revision: UInt32 = 0
    private var dirty = false
    private var loggedUnavailable = false
    private var generation: UInt = 0

    func start(worldRoot: Entity) {
      stop()
      self.worldRoot = worldRoot
      generation &+= 1
      let generation = self.generation

      guard SceneReconstructionProvider.isSupported else {
        logUnavailableOnce("SceneReconstructionProvider not supported on this device")
        return
      }

      let session = ARKitSession()
      let provider = SceneReconstructionProvider(modes: [])
      self.session = session
      self.provider = provider

      sessionTask = Task { @MainActor [weak self] in
        await self?.runSession(session: session, provider: provider, generation: generation)
      }
      publishTask = Task { @MainActor [weak self] in
        await self?.runPublishLoop(generation: generation)
      }
    }

    func stop() {
      generation &+= 1
      sessionTask?.cancel()
      sessionTask = nil
      publishTask?.cancel()
      publishTask = nil
      session = nil
      provider = nil
      meshes.removeAll()
      dirty = false
      worldRoot = nil
      BLENDER_VISIONOS_world_mesh_publish(0, nil, 0, nil, 0, 0)
    }

    private func logUnavailableOnce(_ message: String) {
      guard !loggedUnavailable else { return }
      loggedUnavailable = true
      print("[immersive] World mesh: \(message)")
    }

    private func runSession(
      session: ARKitSession, provider: SceneReconstructionProvider, generation: UInt
    ) async {
      do {
        try await session.run([provider])
      }
      catch {
        logUnavailableOnce("ARKitSession run failed: \(error)")
        return
      }
      guard generation == self.generation else { return }
      for await update in provider.anchorUpdates {
        guard generation == self.generation else { break }
        let anchor = update.anchor
        switch update.event {
        case .added, .updated:
          if let entry = Self.extractGeometry(anchor: anchor, worldRoot: worldRoot) {
            meshes[anchor.id] = entry
            dirty = true
          }
        case .removed:
          if meshes.removeValue(forKey: anchor.id) != nil {
            dirty = true
          }
        @unknown default:
          break
        }
      }
    }

    private func runPublishLoop(generation: UInt) async {
      while !Task.isCancelled, generation == self.generation {
        try? await Task.sleep(nanoseconds: Self.publishNanos)
        guard generation == self.generation else { break }
        if dirty {
          dirty = false
          publishAccumulated()
        }
      }
    }

    private func publishAccumulated() {
      var xyz: [Float] = []
      var indices: [UInt32] = []
      xyz.reserveCapacity(Self.maxVerts * 3)
      indices.reserveCapacity(Self.maxIndices)
      var truncated: Int32 = 0
      var usedAnchors = 0
      var skippedAnchors = 0

      /* Floor-first: lower Blender Z tends to be floor / table tops. */
      let ordered = meshes.values.sorted { a, b in
        if a.minZ != b.minZ { return a.minZ < b.minZ }
        return a.vertices.count < b.vertices.count
      }

      for raw in ordered {
        var entry = raw
        if entry.vertices.count > Self.perAnchorSoftVerts {
          entry = Self.strideDecimate(entry, targetVerts: Self.perAnchorSoftVerts)
        }

        let nextV = xyz.count / 3 + entry.vertices.count
        let nextI = indices.count + entry.indices.count
        if nextV > Self.maxVerts || nextI > Self.maxIndices {
          /* Skip this piece — keep trying others (was: break → only first wall). */
          truncated = 1
          skippedAnchors += 1
          continue
        }

        let baseVertex = UInt32(xyz.count / 3)
        for v in entry.vertices {
          xyz.append(v.x)
          xyz.append(v.y)
          xyz.append(v.z)
        }
        for idx in entry.indices {
          indices.append(baseVertex + idx)
        }
        usedAnchors += 1
      }

      revision &+= 1
      let vertexCount = UInt32(xyz.count / 3)
      let indexCount = UInt32(indices.count)
      if revision == 1 || revision % 5 == 0 || truncated != 0 {
        print(
          "[immersive] World mesh publish rev=\(revision) anchors=\(usedAnchors)/\(meshes.count) "
            + "skip=\(skippedAnchors) verts=\(vertexCount) tris=\(indexCount / 3) "
            + "trunc=\(truncated)")
      }
      xyz.withUnsafeBufferPointer { xyzBuf in
        indices.withUnsafeBufferPointer { idxBuf in
          BLENDER_VISIONOS_world_mesh_publish(
            revision, xyzBuf.baseAddress, vertexCount, idxBuf.baseAddress, indexCount, truncated)
        }
      }
    }

    /** Drop triangles by stride, remap vertex indices compactly. */
    private static func strideDecimate(_ entry: MeshEntry, targetVerts: Int) -> MeshEntry {
      guard entry.vertices.count > targetVerts, entry.indices.count >= 3 else {
        return entry
      }
      let triCount = entry.indices.count / 3
      let targetTris = max(32, (targetVerts * triCount) / max(entry.vertices.count, 1))
      let stride = max(1, triCount / targetTris)

      var newVerts: [SIMD3<Float>] = []
      var newIndices: [UInt32] = []
      var remap: [Int: UInt32] = [:]
      newVerts.reserveCapacity(targetVerts)
      newIndices.reserveCapacity(targetTris * 3)

      var t = 0
      while t < triCount {
        let o = t * 3
        let ia = Int(entry.indices[o])
        let ib = Int(entry.indices[o + 1])
        let ic = Int(entry.indices[o + 2])
        func map(_ old: Int) -> UInt32 {
          if let existing = remap[old] { return existing }
          let n = UInt32(newVerts.count)
          remap[old] = n
          newVerts.append(entry.vertices[old])
          return n
        }
        newIndices.append(map(ia))
        newIndices.append(map(ib))
        newIndices.append(map(ic))
        t += stride
      }
      var minZ = Float.greatestFiniteMagnitude
      var maxZ = -Float.greatestFiniteMagnitude
      for v in newVerts {
        minZ = min(minZ, v.z)
        maxZ = max(maxZ, v.z)
      }
      return MeshEntry(vertices: newVerts, indices: newIndices, minZ: minZ, maxZ: maxZ)
    }

    /** Mesh-anchor local vertices → Blender world space (relative to `worldRoot`). */
    private static func extractGeometry(anchor: MeshAnchor, worldRoot: Entity?) -> MeshEntry? {
      let geometry = anchor.geometry
      guard geometry.vertices.count > 0 else { return nil }

      let originTransform = anchor.originFromAnchorTransform
      let localVertices = geometry.vertices.asSIMD3Array()
      var worldVertices: [SIMD3<Float>] = []
      worldVertices.reserveCapacity(localVertices.count)
      var minZ = Float.greatestFiniteMagnitude
      var maxZ = -Float.greatestFiniteMagnitude
      for local in localVertices {
        let worldPos4 = originTransform * SIMD4<Float>(local.x, local.y, local.z, 1)
        let worldPos = SIMD3<Float>(worldPos4.x, worldPos4.y, worldPos4.z)
        let relative = worldRoot?.convert(position: worldPos, from: nil) ?? worldPos
        let blender = BlenderImmersiveCoords.realityKitToBlender(relative)
        worldVertices.append(blender)
        minZ = min(minZ, blender.z)
        maxZ = max(maxZ, blender.z)
      }

      let faces = geometry.faces
      let indexCount = faces.count * 3
      guard indexCount > 0 else {
        return MeshEntry(vertices: worldVertices, indices: [], minZ: minZ, maxZ: maxZ)
      }
      var indices: [UInt32] = []
      indices.reserveCapacity(indexCount)
      let indexBuffer = faces.buffer.contents()
      let bytesPerIndex = faces.bytesPerIndex
      for i in 0..<indexCount {
        let pointer = indexBuffer.advanced(by: i * bytesPerIndex)
        let value: UInt32 =
          bytesPerIndex == 2
          ? UInt32(pointer.assumingMemoryBound(to: UInt16.self).pointee)
          : pointer.assumingMemoryBound(to: UInt32.self).pointee
        indices.append(value)
      }
      return MeshEntry(vertices: worldVertices, indices: indices, minZ: minZ, maxZ: maxZ)
    }
  }

#endif
