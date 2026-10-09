/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Live Mesh Bridge payloads + RealityKit LowLevelMesh builder (5.0.1 / TF-159).
 * Verts / normals arrive in Blender object-relative space; convert to RealityKit here.
 *
 * Axis conversion + normal generation run off the MainActor — TF-153 ran mesh
 * generation on MainActor at ~20 Hz and starved Logitech Muse pose/input sampling.
 * Only buffer copies + MeshResource(from: LowLevelMesh) happen on MainActor.
 *
 * Partial updates (`update`) write vertex ranges in place into the retained
 * LowLevelMesh (no MeshResource rebuild) so sculpt strokes stay interactive.
 */

import Foundation
import Metal
import RealityKit
import simd
import UIKit

#if os(visionOS)

  public struct BlenderImmersiveLiveMeshPayload: Sendable {
    public let name: String
    /** Float32 xyz per vertex (Blender axes). */
    public let verts: Data
    /** Float32 xyz per vertex (Blender axes, unit). Empty → computed. */
    public let normals: Data
    /** UInt32 triangle list. */
    public let indices: Data
    public let color: SIMD4<Float>

    public init(
      name: String, verts: Data, normals: Data = Data(), indices: Data, color: SIMD4<Float>
    ) {
      self.name = name
      self.verts = verts
      self.normals = normals
      self.indices = indices
      self.color = color
    }
  }

  /** Converted (RealityKit axes) mesh ready for upload — built off-main. */
  struct BlenderImmersiveLiveMeshConverted: Sendable {
    let name: String
    let vertexCount: Int
    /** Interleaved position.xyz + normal.xyz (6 floats / 24 bytes per vertex). */
    let interleaved: [Float]
    let indices: [UInt32]
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
    let color: SIMD4<Float>
  }

  @MainActor
  final class BlenderImmersiveLiveMeshRecord {
    let entity: ModelEntity
    /** nil → MeshDescriptor fallback (partial updates unsupported). */
    let mesh: LowLevelMesh?
    let vertexCount: Int
    var bounds: BoundingBox

    init(entity: ModelEntity, mesh: LowLevelMesh?, vertexCount: Int, bounds: BoundingBox) {
      self.entity = entity
      self.mesh = mesh
      self.vertexCount = vertexCount
      self.bounds = bounds
    }
  }

  private struct BlenderImmersiveLiveMeshPartial {
    let name: String
    let vertexCount: Int
    /** (start, count) pairs. */
    let ranges: [Int32]
    let verts: Data
    let normals: Data
  }

  @MainActor
  enum BlenderImmersiveLiveMeshBuilder {
    /// Generation counter so superseded sculpt frames drop instead of queueing MainActor.
    static var applyGeneration: UInt = 0

    static let vertexStride = 24
    private static var registry: [String: BlenderImmersiveLiveMeshRecord] = [:]
    private static weak var boundWorldRoot: Entity?

    /* Full frame committed but not yet installed: partial updates for that frame are
     * recorded and replayed onto the new meshes after install (else they are lost). */
    private static var pendingRevision: UInt64 = 0
    private static var pendingVertexCounts: [String: Int] = [:]
    private static var pendingPartials: [BlenderImmersiveLiveMeshPartial] = []
    private static var pendingBytes = 0
    private static var pendingSince: Date?
    private static let pendingTimeout: TimeInterval = 3.0
    private static let pendingMaxBytes = 64 * 1024 * 1024

    private static var statLastLog = Date.distantPast
    private static var statCalls = 0
    private static var statRanges = 0
    private static var statVerts = 0
    private static var statMs: Double = 0
    private static var statName = ""

    /** Called on main right after `liveMeshCommit` (before the async apply starts). */
    static func noteFullFrame(_ payloads: [BlenderImmersiveLiveMeshPayload], revision: UInt64) {
      pendingPartials.removeAll()
      pendingBytes = 0
      guard !payloads.isEmpty, let root = boundWorldRoot, root.scene != nil else {
        pendingVertexCounts = [:]
        pendingSince = nil
        return
      }
      var counts: [String: Int] = [:]
      for payload in payloads {
        counts[payload.name] = payload.verts.count / 12
      }
      pendingVertexCounts = counts
      pendingRevision = revision
      pendingSince = Date()
    }

    static func apply(
      payloads: [BlenderImmersiveLiveMeshPayload], revision: UInt64, to worldRoot: Entity
    ) async -> Entity? {
      applyGeneration &+= 1
      let generation = applyGeneration
      boundWorldRoot = worldRoot

      /* Axis swap + normals off the main actor so Muse / HandPen keep sampling. */
      let converted: [BlenderImmersiveLiveMeshConverted] = await Task.detached(
        priority: .userInitiated
      ) {
        payloads.compactMap { BlenderImmersiveLiveMeshBuilder.convert($0) }
      }.value

      guard generation == applyGeneration else {
        /* A newer live-mesh commit superseded this frame — drop it. */
        return nil
      }

      let liveRoot = Entity()
      liveRoot.name = "BlenderImmersiveLive"
      var nextRegistry: [String: BlenderImmersiveLiveMeshRecord] = [:]

      for item in converted {
        let color = UIColor(
          red: CGFloat(item.color.x),
          green: CGFloat(item.color.y),
          blue: CGFloat(item.color.z),
          alpha: CGFloat(max(0.05, item.color.w)))
        let material = SimpleMaterial(color: color, isMetallic: false)
        var built = await makeLowLevelRecord(item, material: material)
        if built == nil {
          built = makeDescriptorRecord(item, material: material)
        }
        /* Each await yields MainActor — bail early if a newer frame arrived. */
        guard generation == applyGeneration else {
          return nil
        }
        guard let record = built else { continue }
        record.entity.name = item.name
        /* Collisions only for grab/hit — skip mid-sculpt storms (Muse needs CPU). */
        liveRoot.addChild(record.entity)
        nextRegistry[item.name] = record
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
      registry = nextRegistry

      if pendingSince != nil && revision == pendingRevision {
        for partial in pendingPartials {
          if let record = registry[partial.name] {
            _ = write(partial, into: record)
          }
        }
        pendingPartials.removeAll()
        pendingBytes = 0
        pendingVertexCounts = [:]
        pendingSince = nil
      }
      return liveRoot
    }

    /**
     * In-place partial update. Returns false when native must send a full frame.
     * `ranges` = Int32 (start, count) pairs; verts / normals = packed Float32 xyz
     * for every vertex in the ranges, in order.
     */
    static func update(
      name: String, vertexCount: Int, ranges: Data, verts: Data, normals: Data
    ) -> Bool {
      let t0 = CFAbsoluteTimeGetCurrent()
      let pairCount = ranges.count / 8
      guard pairCount > 0, vertexCount > 0 else { return false }
      var rangeValues = [Int32](repeating: 0, count: pairCount * 2)
      ranges.withUnsafeBytes { buf in
        for i in 0..<(pairCount * 2) {
          rangeValues[i] = buf.loadUnaligned(fromByteOffset: i * 4, as: Int32.self)
        }
      }
      let partial = BlenderImmersiveLiveMeshPartial(
        name: name, vertexCount: vertexCount, ranges: rangeValues, verts: verts, normals: normals)

      var written: Int?
      if let since = pendingSince {
        let live = boundWorldRoot?.scene != nil
        if !live || Date().timeIntervalSince(since) > pendingTimeout {
          pendingSince = nil
          pendingVertexCounts = [:]
          pendingPartials.removeAll()
          pendingBytes = 0
          return false
        }
        guard let pendingCount = pendingVertexCounts[name], pendingCount == vertexCount else {
          return false
        }
        pendingBytes += verts.count + normals.count + ranges.count
        if pendingBytes > pendingMaxBytes {
          pendingSince = nil
          pendingVertexCounts = [:]
          pendingPartials.removeAll()
          pendingBytes = 0
          return false
        }
        pendingPartials.append(partial)
        /* Keep the on-screen (older) mesh responsive until the new one installs. */
        if let record = registry[name], record.entity.scene != nil {
          written = write(partial, into: record)
        }
        logPartial(
          name: name, ranges: pairCount, verts: written ?? 0,
          ms: (CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
        return true
      }

      guard let record = registry[name], record.entity.scene != nil,
        record.mesh != nil, record.vertexCount == vertexCount
      else {
        return false
      }
      written = write(partial, into: record)
      guard let count = written else { return false }
      logPartial(
        name: name, ranges: pairCount, verts: count,
        ms: (CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
      return true
    }

    static func clear(from worldRoot: Entity) {
      applyGeneration &+= 1
      registry.removeAll()
      pendingSince = nil
      pendingVertexCounts = [:]
      pendingPartials.removeAll()
      pendingBytes = 0
      for child in worldRoot.children where child.name == "BlenderImmersiveLive" {
        child.removeFromParent()
      }
      for usd in worldRoot.children where usd.name == "BlenderImmersiveUSD" {
        usd.isEnabled = true
      }
    }

    // MARK: - Partial write

    /** Returns written vertex count, or nil when the partial does not fit this record. */
    private static func write(
      _ partial: BlenderImmersiveLiveMeshPartial, into record: BlenderImmersiveLiveMeshRecord
    ) -> Int? {
      guard let mesh = record.mesh, record.vertexCount == partial.vertexCount else { return nil }
      let pairCount = partial.ranges.count / 2
      var total = 0
      for r in 0..<pairCount {
        let start = Int(partial.ranges[r * 2])
        let count = Int(partial.ranges[r * 2 + 1])
        guard start >= 0, count >= 0, start + count <= record.vertexCount else { return nil }
        total += count
      }
      guard total > 0, partial.verts.count >= total * 12 else { return nil }
      let hasNormals = partial.normals.count >= total * 12
      let stride = vertexStride
      var bounds = record.bounds
      var ok = true

      partial.verts.withUnsafeBytes { vbuf in
        partial.normals.withUnsafeBytes { nbuf in
          mesh.withUnsafeMutableBytes(bufferIndex: 0) { dst in
            guard dst.count >= record.vertexCount * stride else {
              ok = false
              return
            }
            var k = 0
            for r in 0..<pairCount {
              let start = Int(partial.ranges[r * 2])
              let count = Int(partial.ranges[r * 2 + 1])
              for v in start..<(start + count) {
                let s = k * 12
                let o = v * stride
                let bx = vbuf.loadUnaligned(fromByteOffset: s, as: Float.self)
                let by = vbuf.loadUnaligned(fromByteOffset: s + 4, as: Float.self)
                let bz = vbuf.loadUnaligned(fromByteOffset: s + 8, as: Float.self)
                /* Blender (x,y,z) → RK (x,z,-y). */
                dst.storeBytes(of: bx, toByteOffset: o, as: Float.self)
                dst.storeBytes(of: bz, toByteOffset: o + 4, as: Float.self)
                dst.storeBytes(of: -by, toByteOffset: o + 8, as: Float.self)
                bounds.formUnion(SIMD3<Float>(bx, bz, -by))
                if hasNormals {
                  let nx = nbuf.loadUnaligned(fromByteOffset: s, as: Float.self)
                  let ny = nbuf.loadUnaligned(fromByteOffset: s + 4, as: Float.self)
                  let nz = nbuf.loadUnaligned(fromByteOffset: s + 8, as: Float.self)
                  dst.storeBytes(of: nx, toByteOffset: o + 12, as: Float.self)
                  dst.storeBytes(of: nz, toByteOffset: o + 16, as: Float.self)
                  dst.storeBytes(of: -ny, toByteOffset: o + 20, as: Float.self)
                }
                k += 1
              }
            }
          }
        }
      }
      guard ok else { return nil }

      if bounds != record.bounds {
        record.bounds = bounds
        if mesh.parts.count > 0 {
          mesh.parts[0].bounds = bounds
        }
      }
      return total
    }

    private static func logPartial(name: String, ranges: Int, verts: Int, ms: Double) {
      statCalls += 1
      statRanges += ranges
      statVerts += verts
      statMs += ms
      statName = name
      let now = Date()
      guard now.timeIntervalSince(statLastLog) >= 1.0 else { return }
      statLastLog = now
      print(
        String(
          format: "[immersive] live mesh partial name=%@ ranges=%d verts=%d ms=%.2f calls=%d",
          statName, statRanges, statVerts, statMs, statCalls))
      statCalls = 0
      statRanges = 0
      statVerts = 0
      statMs = 0
    }

    // MARK: - Full build

    private static func makeLowLevelRecord(
      _ item: BlenderImmersiveLiveMeshConverted, material: SimpleMaterial
    ) async -> BlenderImmersiveLiveMeshRecord? {
      var descriptor = LowLevelMesh.Descriptor()
      descriptor.vertexCapacity = item.vertexCount
      descriptor.indexCapacity = item.indices.count
      descriptor.indexType = .uint32
      descriptor.vertexAttributes = [
        LowLevelMesh.Attribute(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
        LowLevelMesh.Attribute(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
      ]
      descriptor.vertexLayouts = [
        LowLevelMesh.Layout(bufferIndex: 0, bufferOffset: 0, bufferStride: vertexStride)
      ]

      let mesh: LowLevelMesh
      do {
        mesh = try LowLevelMesh(descriptor: descriptor)
      }
      catch {
        print("[immersive] live mesh LowLevelMesh failed \(item.name): \(error)")
        return nil
      }

      mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { dst in
        item.interleaved.withUnsafeBytes { src in
          guard let d = dst.baseAddress, let s = src.baseAddress else { return }
          d.copyMemory(from: s, byteCount: min(dst.count, src.count))
        }
      }
      mesh.replaceUnsafeMutableIndices { dst in
        item.indices.withUnsafeBytes { src in
          guard let d = dst.baseAddress, let s = src.baseAddress else { return }
          d.copyMemory(from: s, byteCount: min(dst.count, src.count))
        }
      }
      let bounds = BoundingBox(min: item.boundsMin, max: item.boundsMax)
      mesh.parts.replaceAll([
        LowLevelMesh.Part(
          indexOffset: 0,
          indexCount: item.indices.count,
          topology: .triangle,
          materialIndex: 0,
          bounds: bounds)
      ])

      let resource: MeshResource
      do {
        resource = try await MeshResource(from: mesh)
      }
      catch {
        print("[immersive] live mesh MeshResource(LowLevelMesh) failed \(item.name): \(error)")
        return nil
      }
      let entity = ModelEntity(mesh: resource, materials: [material])
      return BlenderImmersiveLiveMeshRecord(
        entity: entity, mesh: mesh, vertexCount: item.vertexCount, bounds: bounds)
    }

    /** Fallback: classic MeshDescriptor path (partial updates then return false). */
    private static func makeDescriptorRecord(
      _ item: BlenderImmersiveLiveMeshConverted, material: SimpleMaterial
    ) -> BlenderImmersiveLiveMeshRecord? {
      var positions: [SIMD3<Float>] = []
      var normals: [SIMD3<Float>] = []
      positions.reserveCapacity(item.vertexCount)
      normals.reserveCapacity(item.vertexCount)
      for i in 0..<item.vertexCount {
        let o = i * 6
        positions.append(
          SIMD3(item.interleaved[o], item.interleaved[o + 1], item.interleaved[o + 2]))
        normals.append(
          SIMD3(item.interleaved[o + 3], item.interleaved[o + 4], item.interleaved[o + 5]))
      }
      var descriptor = MeshDescriptor(name: item.name)
      descriptor.positions = MeshBuffers.Positions(positions)
      descriptor.normals = MeshBuffers.Normals(normals)
      descriptor.primitives = .triangles(item.indices)
      do {
        let resource = try MeshResource.generate(from: [descriptor])
        let entity = ModelEntity(mesh: resource, materials: [material])
        return BlenderImmersiveLiveMeshRecord(
          entity: entity,
          mesh: nil,
          vertexCount: item.vertexCount,
          bounds: BoundingBox(min: item.boundsMin, max: item.boundsMax))
      }
      catch {
        print("[immersive] live mesh generate failed \(item.name): \(error)")
        return nil
      }
    }

    // MARK: - Off-main conversion

    nonisolated static func convert(_ payload: BlenderImmersiveLiveMeshPayload)
      -> BlenderImmersiveLiveMeshConverted?
    {
      let vertCount = payload.verts.count / 12
      let indexCount = (payload.indices.count / 4) / 3 * 3
      guard vertCount > 0, indexCount > 0 else { return nil }

      var out = [Float](repeating: 0, count: vertCount * 6)
      var indices = [UInt32](repeating: 0, count: indexCount)
      var bmin = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
      var bmax = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
      let hasNormals = payload.normals.count >= vertCount * 12

      out.withUnsafeMutableBufferPointer { dst in
        payload.verts.withUnsafeBytes { v in
          for i in 0..<vertCount {
            let bx = v.loadUnaligned(fromByteOffset: i * 12, as: Float.self)
            let by = v.loadUnaligned(fromByteOffset: i * 12 + 4, as: Float.self)
            let bz = v.loadUnaligned(fromByteOffset: i * 12 + 8, as: Float.self)
            let p = SIMD3<Float>(bx, bz, -by)
            dst[i * 6] = p.x
            dst[i * 6 + 1] = p.y
            dst[i * 6 + 2] = p.z
            bmin = simd_min(bmin, p)
            bmax = simd_max(bmax, p)
          }
        }
        if hasNormals {
          payload.normals.withUnsafeBytes { n in
            for i in 0..<vertCount {
              let nx = n.loadUnaligned(fromByteOffset: i * 12, as: Float.self)
              let ny = n.loadUnaligned(fromByteOffset: i * 12 + 4, as: Float.self)
              let nz = n.loadUnaligned(fromByteOffset: i * 12 + 8, as: Float.self)
              dst[i * 6 + 3] = nx
              dst[i * 6 + 4] = nz
              dst[i * 6 + 5] = -ny
            }
          }
        }
      }

      payload.indices.withUnsafeBytes { ib in
        let maxIndex = UInt32(vertCount)
        for i in 0..<indexCount {
          let idx = ib.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
          indices[i] = idx < maxIndex ? idx : 0
        }
      }

      if !hasNormals {
        /* Area-weighted vertex normals from RK-space positions. */
        out.withUnsafeMutableBufferPointer { dst in
          var t = 0
          while t + 2 < indexCount {
            let a = Int(indices[t])
            let b = Int(indices[t + 1])
            let c = Int(indices[t + 2])
            let pa = SIMD3<Float>(dst[a * 6], dst[a * 6 + 1], dst[a * 6 + 2])
            let pb = SIMD3<Float>(dst[b * 6], dst[b * 6 + 1], dst[b * 6 + 2])
            let pc = SIMD3<Float>(dst[c * 6], dst[c * 6 + 1], dst[c * 6 + 2])
            let fn = simd_cross(pb - pa, pc - pa)
            dst[a * 6 + 3] += fn.x
            dst[a * 6 + 4] += fn.y
            dst[a * 6 + 5] += fn.z
            dst[b * 6 + 3] += fn.x
            dst[b * 6 + 4] += fn.y
            dst[b * 6 + 5] += fn.z
            dst[c * 6 + 3] += fn.x
            dst[c * 6 + 4] += fn.y
            dst[c * 6 + 5] += fn.z
            t += 3
          }
          for i in 0..<vertCount {
            let n = SIMD3<Float>(dst[i * 6 + 3], dst[i * 6 + 4], dst[i * 6 + 5])
            let len = simd_length(n)
            let u = len > 1.0e-12 ? n / len : SIMD3<Float>(0, 1, 0)
            dst[i * 6 + 3] = u.x
            dst[i * 6 + 4] = u.y
            dst[i * 6 + 5] = u.z
          }
        }
      }

      if !(bmin.x.isFinite && bmax.x.isFinite && bmin.x <= bmax.x) {
        bmin = .zero
        bmax = .zero
      }

      return BlenderImmersiveLiveMeshConverted(
        name: payload.name,
        vertexCount: vertCount,
        interleaved: out,
        indices: indices,
        boundsMin: bmin,
        boundsMax: bmax,
        color: payload.color)
    }
  }

#else

  public struct BlenderImmersiveLiveMeshPayload {
    public let name: String
    public let verts: Data
    public let normals: Data
    public let indices: Data
    public let color: SIMD4<Float>

    public init(
      name: String, verts: Data, normals: Data = Data(), indices: Data, color: SIMD4<Float>
    ) {
      self.name = name
      self.verts = verts
      self.normals = normals
      self.indices = indices
      self.color = color
    }
  }

#endif
