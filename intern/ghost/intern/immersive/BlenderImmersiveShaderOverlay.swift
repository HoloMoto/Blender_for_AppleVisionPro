/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Spatial Shading overlay — Build 87 (crash fix).
 *
 * - No socket spheres, no generateText, no HoverEffect
 * - No SwiftUI Attachments reparented under graphRoot (Build 86 SIGTRAP)
 * - Bodies + kind stripe + directional links (max 8)
 * - Node names shown on Hand / Studio only (option B)
 * - Opt-in: `spatialBoardWanted` only
 */

import RealityKit
import SwiftUI
import UIKit

#if os(visionOS)

  @_silgen_name("WM_IOS_immersive_shader_move_node")
  private func WM_IOS_immersive_shader_move_node(
    _ nodeName: UnsafePointer<CChar>, _ locx: Float, _ locy: Float)

  @_silgen_name("WM_IOS_immersive_shader_select_node")
  private func WM_IOS_immersive_shader_select_node(_ nodeName: UnsafePointer<CChar>?)

  @_silgen_name("WM_IOS_immersive_shader_auto_connect")
  private func WM_IOS_immersive_shader_auto_connect(
    _ fromNode: UnsafePointer<CChar>, _ toNode: UnsafePointer<CChar>)

  final class BlenderImmersiveShaderOverlay: ObservableObject {
    private var root = Entity()
    private var bodyEntities: [ModelEntity] = []
    private var stripeEntities: [ModelEntity] = []
    private var linkEntities: [ModelEntity] = []
    private var tipEntities: [ModelEntity] = []
    private var nodeNames: [String] = []
    private var positions: [SIMD3<Float>] = []
    private var kinds: [Int] = []
    private var selectedFlags: [Bool] = []
    private var attached = false
    private var lastSignature: UInt64 = 0
    private var isDragging = false
    private var dragIndex: Int?
    private var dragStartPos = SIMD3<Float>.zero
    private var dragStartHit = SIMD3<Float>.zero
    private var enabledAt: Date = .distantPast
    private var connectFlashIndex: Int?
    private var connectFlashUntil: Date = .distantPast
    private var flashClearTask: Task<Void, Never>?
    /** Opt-in: Mat ON alone must not spawn RealityKit entities. */
    private(set) var spatialBoardWanted = false

    private let scale: Float = 0.0022
    private let boardOrigin = SIMD3<Float>(0.55, 0.35, 0.25)
    private let bodySize = SIMD3<Float>(0.11, 0.052, 0.02)
    private let stripeSize = SIMD3<Float>(0.10, 0.01, 0.006)
    /** Larger than visual so pinch is easier. */
    private let hitSize = SIMD3<Float>(0.16, 0.09, 0.05)
    private let maxNodes = 8
    private let dropConnectDistance: Float = 0.075
    private let wireRadius: Float = 0.0045
    private let tipRadius: Float = 0.008

    func attach(to worldRoot: Entity) {
      if !attached {
        root.name = "BlenderImmersiveShaderGraph"
        root.isEnabled = false
        worldRoot.addChild(root)
        attached = true
      }
    }

    var isInteractive: Bool {
      spatialBoardWanted && attached && root.isEnabled && !bodyEntities.isEmpty
        && Date().timeIntervalSince(enabledAt) > 0.5
    }
    var graphRoot: Entity { root }

    func setSpatialBoardWanted(_ wanted: Bool) {
      if spatialBoardWanted == wanted { return }
      spatialBoardWanted = wanted
      if !wanted {
        clear()
      }
      else {
        lastSignature = 0
      }
    }

    func clear() {
      flashClearTask?.cancel()
      flashClearTask = nil
      connectFlashIndex = nil
      connectFlashUntil = .distantPast
      root.isEnabled = false
      lastSignature = 0
      isDragging = false
      dragIndex = nil
      nodeNames.removeAll()
      positions.removeAll()
      kinds.removeAll()
      selectedFlags.removeAll()
      /* Only remove entities we own — never touch Attachment-managed children. */
      for e in bodyEntities { e.removeFromParent() }
      bodyEntities.removeAll()
      for e in stripeEntities { e.removeFromParent() }
      stripeEntities.removeAll()
      for e in linkEntities { e.removeFromParent() }
      linkEntities.removeAll()
      for e in tipEntities { e.removeFromParent() }
      tipEntities.removeAll()
    }

    func update(
      materialName: String,
      nodePacked: [Float],
      nodeCount: Int,
      names: [String],
      typeNames: [String],
      linkPacked: [Int],
      linkCount: Int,
      sockTypes: [Int],
      sockNames: [String],
      visible: Bool
    ) {
      _ = typeNames
      _ = sockTypes
      _ = sockNames
      guard spatialBoardWanted, visible else {
        clear()
        return
      }
      let nCount = min(max(0, nodeCount), maxNodes)
      guard nCount > 0, nodePacked.count >= nCount * 6 else {
        clear()
        return
      }

      if isDragging {
        applyBodyMaterials()
        return
      }

      var sig: UInt64 = UInt64(nCount) &* 31 &+ UInt64(min(linkCount, 24))
      sig = sig &* 1_099_511_628_211 &+ UInt64(materialName.hashValue)
      for i in 0..<min(nCount * 6, nodePacked.count) {
        let q = Int((nodePacked[i] * 8).rounded())
        sig = sig &* 1_099_511_628_211 &+ UInt64(bitPattern: Int64(q))
      }
      for i in 0..<min(min(linkCount, 24) * 4, linkPacked.count) {
        sig = sig &* 1_099_511_628_211 &+ UInt64(bitPattern: Int64(linkPacked[i]))
      }
      if connectFlashIndex != nil && Date() >= connectFlashUntil {
        connectFlashIndex = nil
      }
      if sig == lastSignature && root.isEnabled {
        applyBodyMaterials()
        return
      }
      lastSignature = sig

      let wasEnabled = root.isEnabled
      root.isEnabled = true
      if !wasEnabled {
        enabledAt = Date()
      }

      nodeNames = Array(names.prefix(nCount))
      while nodeNames.count < nCount { nodeNames.append("Node\(nodeNames.count)") }

      positions.removeAll(keepingCapacity: true)
      kinds.removeAll(keepingCapacity: true)
      selectedFlags.removeAll(keepingCapacity: true)
      for i in 0..<nCount {
        let o = i * 6
        let local = SIMD3(nodePacked[o] * scale, nodePacked[o + 1] * scale, 0)
        positions.append(boardOrigin + local)
        kinds.append(Int(nodePacked[o + 2].rounded()))
        selectedFlags.append(nodePacked[o + 3] > 0.5)
      }

      while bodyEntities.count < nCount {
        let body = ModelEntity(
          mesh: .generateBox(size: bodySize, cornerRadius: 0.006),
          materials: [SimpleMaterial(color: .systemGray, isMetallic: false)])
        body.components.set(CollisionComponent(shapes: [.generateBox(size: hitSize)]))
        body.components.set(InputTargetComponent())
        root.addChild(body)
        bodyEntities.append(body)

        let stripe = ModelEntity(
          mesh: .generateBox(size: stripeSize, cornerRadius: 0.002),
          materials: [SimpleMaterial(color: .white, isMetallic: false)])
        root.addChild(stripe)
        stripeEntities.append(stripe)
      }
      while bodyEntities.count > nCount {
        bodyEntities.removeLast().removeFromParent()
        stripeEntities.removeLast().removeFromParent()
      }

      for i in 0..<nCount {
        let e = bodyEntities[i]
        e.name = "ShaderBody:\(i)"
        e.position = positions[i]
        let stripe = stripeEntities[i]
        stripe.position = positions[i] + SIMD3(0, bodySize.y * 0.5 + 0.008, bodySize.z * 0.35)
      }
      applyBodyMaterials()
      rebuildLinks(linkPacked: linkPacked, linkCount: min(linkCount, 24))
    }

    private func applyBodyMaterials() {
      for i in 0..<bodyEntities.count {
        let e = bodyEntities[i]
        let kind = i < kinds.count ? kinds[i] : 0
        let tint = Self.kindColor(kind)
        let selected = i < selectedFlags.count ? selectedFlags[i] : false
        let dragging = isDragging && dragIndex == i
        let flash = connectFlashIndex == i && Date() < connectFlashUntil
        let color: UIColor
        if flash {
          color = UIColor.systemGreen.withAlphaComponent(0.95)
        }
        else if dragging {
          color = UIColor.systemCyan.withAlphaComponent(0.98)
        }
        else if selected {
          color = tint
        }
        else {
          color = tint.withAlphaComponent(0.9)
        }
        e.model?.materials = [
          SimpleMaterial(color: color, isMetallic: selected || dragging || flash)
        ]
        var s: Float = 1.0
        if dragging { s = 1.14 }
        else if selected { s = 1.08 }
        else if flash { s = 1.12 }
        e.scale = SIMD3(repeating: s)

        if i < stripeEntities.count {
          let stripe = stripeEntities[i]
          stripe.model?.materials = [
            SimpleMaterial(color: UIColor.white.withAlphaComponent(0.92), isMetallic: true)
          ]
          stripe.scale = SIMD3(repeating: s)
          if i < positions.count {
            stripe.position = positions[i] + SIMD3(0, bodySize.y * 0.5 + 0.008, bodySize.z * 0.35)
          }
        }
      }
    }

    private func rebuildLinks(linkPacked: [Int], linkCount: Int) {
      struct Seg { var a: SIMD3<Float>; var b: SIMD3<Float> }
      var segs: [Seg] = []
      if linkPacked.count >= linkCount * 4 {
        for i in 0..<linkCount {
          let from = linkPacked[i * 4]
          let to = linkPacked[i * 4 + 2]
          guard from >= 0, from < positions.count, to >= 0, to < positions.count else { continue }
          let outOff = SIMD3(bodySize.x * 0.48, 0, 0)
          let inOff = SIMD3(-bodySize.x * 0.48, 0, 0)
          segs.append(Seg(a: positions[from] + outOff, b: positions[to] + inOff))
        }
      }
      while linkEntities.count < segs.count {
        let tube = ModelEntity(
          mesh: .generateCylinder(height: 1.0, radius: wireRadius),
          materials: [
            SimpleMaterial(color: UIColor.systemCyan.withAlphaComponent(0.85), isMetallic: false)
          ])
        root.addChild(tube)
        linkEntities.append(tube)
      }
      while tipEntities.count < segs.count {
        let tip = ModelEntity(
          mesh: .generateSphere(radius: tipRadius),
          materials: [
            SimpleMaterial(color: UIColor.systemYellow.withAlphaComponent(0.95), isMetallic: true)
          ])
        root.addChild(tip)
        tipEntities.append(tip)
      }
      while linkEntities.count > segs.count {
        linkEntities.removeLast().removeFromParent()
      }
      while tipEntities.count > segs.count {
        tipEntities.removeLast().removeFromParent()
      }
      for (i, seg) in segs.enumerated() {
        placeWire(linkEntities[i], from: seg.a, to: seg.b)
        tipEntities[i].isEnabled = true
        tipEntities[i].position = seg.b
      }
    }

    private func placeWire(_ e: ModelEntity, from a: SIMD3<Float>, to b: SIMD3<Float>) {
      let d = b - a
      let len = simd_length(d)
      guard len > 0.01 else {
        e.isEnabled = false
        return
      }
      e.isEnabled = true
      e.position = (a + b) * 0.5
      e.scale = SIMD3(1, len, 1)
      let dir = d / len
      let up = SIMD3<Float>(0, 1, 0)
      let axis = simd_cross(up, dir)
      let axisLen = simd_length(axis)
      if axisLen < 1e-5 {
        e.orientation =
          simd_dot(up, dir) > 0
          ? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
          : simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
      }
      else {
        let angle = acos(max(-1, min(1, simd_dot(up, dir))))
        e.orientation = simd_quatf(angle: angle, axis: axis / axisLen)
      }
    }

    func dragChanged(hitEntity: Entity, locationInRoot: SIMD3<Float>) -> Bool {
      guard isInteractive, let idx = index(of: hitEntity) else { return false }
      if !isDragging {
        isDragging = true
        dragIndex = idx
        dragStartPos = bodyEntities[idx].position
        dragStartHit = locationInRoot
        if idx < nodeNames.count {
          nodeNames[idx].withCString { WM_IOS_immersive_shader_select_node($0) }
        }
        if idx < selectedFlags.count {
          for i in 0..<selectedFlags.count { selectedFlags[i] = (i == idx) }
        }
      }
      guard let dragIndex, dragIndex == idx, dragIndex < bodyEntities.count else { return true }
      var pos = dragStartPos + (locationInRoot - dragStartHit)
      pos.z = boardOrigin.z
      bodyEntities[idx].position = pos
      if idx < positions.count { positions[idx] = pos }
      applyBodyMaterials()
      return true
    }

    func dragEnded(hitEntity: Entity?) {
      _ = hitEntity
      guard isDragging, let idx = dragIndex, idx < bodyEntities.count, idx < nodeNames.count else {
        isDragging = false
        dragIndex = nil
        return
      }
      let pos = bodyEntities[idx].position

      var bestIdx: Int?
      var bestDist = dropConnectDistance
      for j in 0..<bodyEntities.count where j != idx {
        let d = simd_length(pos - bodyEntities[j].position)
        if d < bestDist {
          bestDist = d
          bestIdx = j
        }
      }
      if let bestIdx, bestIdx < nodeNames.count {
        let from = nodeNames[idx]
        let to = nodeNames[bestIdx]
        from.withCString { f in
          to.withCString { t in
            WM_IOS_immersive_shader_auto_connect(f, t)
          }
        }
        flashConnect(at: bestIdx)
      }

      let canvasX = (pos.x - boardOrigin.x) / scale
      let canvasY = (pos.y - boardOrigin.y) / scale
      nodeNames[idx].withCString { WM_IOS_immersive_shader_move_node($0, canvasX, canvasY) }
      isDragging = false
      dragIndex = nil
      lastSignature = 0
      applyBodyMaterials()
    }

    func dragEnded() { dragEnded(hitEntity: nil) }

    private func flashConnect(at index: Int) {
      connectFlashIndex = index
      connectFlashUntil = Date().addingTimeInterval(0.55)
      applyBodyMaterials()
      flashClearTask?.cancel()
      flashClearTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled else { return }
        if Date() >= self.connectFlashUntil {
          self.connectFlashIndex = nil
          self.applyBodyMaterials()
        }
      }
    }

    private func index(of entity: Entity) -> Int? {
      var cur: Entity? = entity
      while let c = cur {
        if c.name.hasPrefix("ShaderBody:"),
          let idx = Int(c.name.dropFirst("ShaderBody:".count)),
          idx >= 0, idx < bodyEntities.count
        {
          return idx
        }
        if let i = bodyEntities.firstIndex(where: { $0 === c }) { return i }
        if c === root { return nil }
        cur = c.parent
      }
      return nil
    }

    static func kindColor(_ kind: Int) -> UIColor {
      switch kind {
      case 1: return UIColor(red: 0.85, green: 0.72, blue: 0.2, alpha: 1)
      case 2: return UIColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1)
      case 3: return UIColor(red: 0.2, green: 0.65, blue: 0.35, alpha: 1)
      case 4: return UIColor(red: 0.55, green: 0.35, blue: 0.75, alpha: 1)
      default: return UIColor(red: 0.45, green: 0.45, blue: 0.48, alpha: 1)
      }
    }
  }

#endif
