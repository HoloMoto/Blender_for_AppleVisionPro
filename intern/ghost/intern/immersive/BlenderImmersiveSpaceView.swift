/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * RealityKit content for the Vision Pro Immersive Space.
 * Loads the USDZ exported from the current Blender scene.
 */

import Foundation
import RealityKit
import SwiftUI
import UIKit
import simd

#if os(visionOS)

  @_silgen_name("WM_IOS_immersive_set_object_z")
  private func WM_IOS_immersive_set_object_z(
    _ objectName: UnsafePointer<CChar>, _ z: Float)

  @_silgen_name("GHOST_IOS_immersive_muse_tick_set_enabled")
  private func GHOST_IOS_immersive_muse_tick_set_enabled(_ enable: Bool)

  @_silgen_name("WM_IOS_immersive_viewer_pose_sample")
  private func WM_IOS_immersive_viewer_pose_sample(_ mat16: UnsafePointer<Float>)

  /**
   * Track the wearer's head relative to Immersive worldRoot and push a
   * Blender-space camera matrix for 「視点→カメラにキー」.
   */
  @MainActor
  private final class BlenderImmersiveViewerPoseTracker: ObservableObject {
    private var headAnchor: AnchorEntity?
    private weak var worldRoot: Entity?
    private var sampleTask: Task<Void, Never>?

    func attach(content: inout RealityViewContent, worldRoot: Entity) {
      if headAnchor == nil {
        let head = AnchorEntity(.head)
        head.name = "BlenderImmersiveHead"
        content.add(head)
        headAnchor = head
      }
      self.worldRoot = worldRoot
      startSampling()
    }

    func detach() {
      sampleTask?.cancel()
      sampleTask = nil
      headAnchor?.removeFromParent()
      headAnchor = nil
      worldRoot = nil
    }

    private func startSampling() {
      sampleTask?.cancel()
      sampleTask = Task { @MainActor in
        while !Task.isCancelled {
          sampleOnce()
          try? await Task.sleep(nanoseconds: 33_333_333)
        }
      }
    }

    private func sampleOnce() {
      guard let head = headAnchor, let root = worldRoot else { return }
      let local = head.transformMatrix(relativeTo: root)
      let blender = BlenderImmersiveCoords.realityKitMatrixToBlender(local)
      var packed: [Float] = [
        blender.columns.0.x, blender.columns.0.y, blender.columns.0.z, blender.columns.0.w,
        blender.columns.1.x, blender.columns.1.y, blender.columns.1.z, blender.columns.1.w,
        blender.columns.2.x, blender.columns.2.y, blender.columns.2.z, blender.columns.2.w,
        blender.columns.3.x, blender.columns.3.y, blender.columns.3.z, blender.columns.3.w,
      ]
      packed.withUnsafeBufferPointer { buf in
        guard let base = buf.baseAddress else { return }
        WM_IOS_immersive_viewer_pose_sample(base)
      }
    }
  }

  /** Blender world (x,y,z) → RealityKit local (x,z,-y). */
  private func blenderToRealityKitCoord(_ b: SIMD3<Float>) -> SIMD3<Float> {
    BlenderImmersiveCoords.blenderToRealityKit(b)
  }

  @MainActor
  private final class BlenderImmersiveBoneOverlay: ObservableObject {
    private var root = Entity()
    private var boneEntities: [ModelEntity] = []
    private var attached = false
    private var lastSignature: UInt64 = 0

    func attach(to worldRoot: Entity) {
      if !attached {
        root.name = "BlenderImmersiveBones"
        worldRoot.addChild(root)
        attached = true
      }
    }

    func clear() {
      for e in boneEntities {
        e.removeFromParent()
      }
      boneEntities.removeAll()
      root.isEnabled = false
      lastSignature = 0
    }

    func update(packed: [Float], count: Int, visible: Bool) {
      guard visible, count > 0, packed.count >= count * 7 else {
        clear()
        return
      }

      var sig: UInt64 = UInt64(count)
      for i in 0..<min(count * 7, packed.count) {
        sig = sig &* 1_099_511_628_211 &+ UInt64(packed[i].bitPattern)
      }
      if sig == lastSignature && root.isEnabled {
        return
      }
      lastSignature = sig
      root.isEnabled = true

      struct BoneSeg {
        var mid: SIMD3<Float>
        var dir: SIMD3<Float>
        var len: Float
        var selected: Bool
      }
      var segs: [BoneSeg] = []
      segs.reserveCapacity(count)
      for i in 0..<count {
        let o = i * 7
        let headB = SIMD3(packed[o], packed[o + 1], packed[o + 2])
        let tailB = SIMD3(packed[o + 3], packed[o + 4], packed[o + 5])
        let selected = packed[o + 6] > 0.5
        let head = blenderToRealityKitCoord(headB)
        let tail = blenderToRealityKitCoord(tailB)
        let dir = tail - head
        let len = simd_length(dir)
        guard len >= 0.01, len <= 2.5,
              head.x.isFinite, head.y.isFinite, head.z.isFinite,
              tail.x.isFinite, tail.y.isFinite, tail.z.isFinite
        else { continue }
        segs.append(
          BoneSeg(mid: (head + tail) * 0.5, dir: dir / len, len: len, selected: selected))
      }

      while boneEntities.count < segs.count {
        let bone = ModelEntity(
          mesh: .generateCylinder(height: 1.0, radius: 0.007),
          materials: [Self.makeBoneMaterial(selected: false)])
        /* Never participate in gaze / pinch hit-testing (Hand UI must win). */
        bone.components.remove(CollisionComponent.self)
        bone.components.remove(InputTargetComponent.self)
        bone.components.set(OpacityComponent(opacity: 0.45))
        root.addChild(bone)
        boneEntities.append(bone)
      }
      while boneEntities.count > segs.count {
        boneEntities.removeLast().removeFromParent()
      }

      for (i, seg) in segs.enumerated() {
        let entity = boneEntities[i]
        entity.position = seg.mid
        entity.scale = SIMD3(1, seg.len, 1)
        let up = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(seg.dir, up)) < 0.999 {
          entity.orientation = simd_quatf(from: up, to: seg.dir)
        }
        else {
          entity.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        entity.model?.materials = [Self.makeBoneMaterial(selected: seg.selected)]
        entity.components.set(OpacityComponent(opacity: seg.selected ? 0.7 : 0.4))
        entity.components.remove(CollisionComponent.self)
        entity.components.remove(InputTargetComponent.self)
      }
    }

    private static func makeBoneMaterial(selected: Bool) -> UnlitMaterial {
      let color: UIColor = selected ?
        .systemPink.withAlphaComponent(0.55) : .cyan.withAlphaComponent(0.4)
      var mat = UnlitMaterial(color: color)
      mat.color = .init(tint: color)
      mat.blending = .transparent(opacity: .init(floatLiteral: selected ? 0.55 : 0.4))
      return mat
    }
  }

  @MainActor
  private final class BlenderImmersiveObjectSync: ObservableObject {
    /** Shared placement root (USD scene + Muse tip share this frame). */
    private var worldRoot: Entity?
    private var rootEntity: Entity?
    private var activeEntity: Entity?
    private var activeObjectName = ""
    private var blenderBaseLocation = SIMD3<Float>.zero
    private var entityBasePosition = SIMD3<Float>.zero
    private var xAxisInParent = SIMD3<Float>(1, 0, 0)
    private var yAxisInParent = SIMD3<Float>(0, 0, -1)
    private var verticalAxisInParent = SIMD3<Float>(0, 1, 0)
    private var dragStartLocation: SIMD3<Float>?
    private var dragStartEntityPosition = SIMD3<Float>.zero
    private var isDragging = false

    func configure(
      worldRoot: Entity,
      sceneRoot: Entity,
      placementOffset: SIMD3<Float>,
      generateCollisions: Bool = true
    ) {
      self.worldRoot = worldRoot
      rootEntity = sceneRoot
      updatePlacement(offset: placementOffset)
      activeEntity = nil
      dragStartLocation = nil
      if !activeObjectName.isEmpty {
        selectActiveEntity(
          name: activeObjectName,
          blenderLocation: blenderBaseLocation,
          generateCollisions: generateCollisions)
      }
    }

    /** Shared placement root — used to reload USD without remaking Muse. */
    var sharedWorldRoot: Entity? { worldRoot }

    func bindWorldRoot(_ root: Entity) {
      worldRoot = root
    }

    func updatePlacement(offset: SIMD3<Float>) {
      /* RealityKit is Y-up. Keep Blender's floor origin at Y=0 by default,
       * with the scene placed 1.2 meters in front of the wearer.
       * Placement is applied to the shared world root (USD + Muse), not the
       * USD file root alone — otherwise Muse tip and mesh frames diverge. */
      worldRoot?.position = SIMD3(offset.x, offset.y, -1.2 + offset.z)
    }

    func updateActiveObject(name: String, blenderLocation: SIMD3<Float>) {
      guard !name.isEmpty else { return }
      if name != activeObjectName || activeEntity == nil {
        activeObjectName = name
        selectActiveEntity(
          name: name, blenderLocation: blenderLocation, generateCollisions: true)
        return
      }

      guard !isDragging, let activeEntity else { return }
      /* Absolute world placement — avoids loc/parent drift that swapped Y/Z feel.
       * Blender world (x,y,z) → RK (x,z,-y), then into the USD entity parent. */
      let rkWorld = BlenderImmersiveCoords.blenderToRealityKit(blenderLocation)
      if let parent = activeEntity.parent, let worldRoot {
        activeEntity.position = parent.convert(position: rkWorld, from: worldRoot)
      }
      else {
        activeEntity.position = rkWorld
      }
      blenderBaseLocation = blenderLocation
      entityBasePosition = activeEntity.position
    }

    /**
     * Lightweight multi-object transform sync (no USD, no collision rebuild).
     * Finds existing USD entities by Blender name and updates position only —
     * used for Object Mode demos (Tetris etc.) where full USD reload is too slow.
     */
    func updateObjectTransforms(names: [String], locations: [SIMD3<Float>]) {
      guard let rootEntity, let worldRoot else { return }
      let n = min(names.count, locations.count)
      guard n > 0 else { return }
      for i in 0..<n {
        let name = names[i]
        guard !name.isEmpty, name != activeObjectName else { continue }
        guard let entity = findEntity(named: name, in: rootEntity) else { continue }
        let rkWorld = BlenderImmersiveCoords.blenderToRealityKit(locations[i])
        if let parent = entity.parent {
          entity.position = parent.convert(position: rkWorld, from: worldRoot)
        }
        else {
          entity.position = rkWorld
        }
      }
    }

    func dragParent(for hitEntity: Entity) -> Entity? {
      guard let activeEntity, belongsToActiveEntity(hitEntity) else { return nil }
      return activeEntity.parent
    }

    func dragChanged(hitEntity: Entity, locationInParent: SIMD3<Float>) {
      guard let activeEntity, belongsToActiveEntity(hitEntity) else { return }

      if dragStartLocation == nil {
        dragStartLocation = locationInParent
        dragStartEntityPosition = activeEntity.position
        isDragging = true
      }
      guard let dragStartLocation else { return }

      let verticalDelta = simd_dot(
        locationInParent - dragStartLocation, verticalAxisInParent)
      activeEntity.position =
        dragStartEntityPosition + verticalAxisInParent * verticalDelta
      let newBlenderZ =
        blenderBaseLocation.z
        + simd_dot(activeEntity.position - entityBasePosition, verticalAxisInParent)
      activeObjectName.withCString {
        WM_IOS_immersive_set_object_z($0, newBlenderZ)
      }
    }

    func dragEnded() {
      dragStartLocation = nil
      isDragging = false
    }

    private func selectActiveEntity(
      name: String,
      blenderLocation: SIMD3<Float>,
      generateCollisions: Bool = true
    ) {
      guard let rootEntity else {
        blenderBaseLocation = blenderLocation
        return
      }

      guard let entity = findEntity(named: name, in: rootEntity) else {
        activeEntity = nil
        print("[immersive] Could not find USD entity for active Blender object: \(name)")
        return
      }

      activeEntity = entity
      blenderBaseLocation = blenderLocation
      entityBasePosition = entity.position
      if let parent = entity.parent {
        let localOrigin = parent.convert(position: .zero, from: nil)
        let localWorldX = parent.convert(position: SIMD3<Float>(1, 0, 0), from: nil)
        let localWorldUp = parent.convert(position: SIMD3<Float>(0, 1, 0), from: nil)
        let localWorldForward = parent.convert(position: SIMD3<Float>(0, 0, -1), from: nil)
        let xAxis = localWorldX - localOrigin
        let yAxis = localWorldForward - localOrigin
        let zAxis = localWorldUp - localOrigin
        if simd_length_squared(xAxis) > 1.0e-8 {
          xAxisInParent = simd_normalize(xAxis)
        }
        if simd_length_squared(yAxis) > 1.0e-8 {
          yAxisInParent = simd_normalize(yAxis)
        }
        if simd_length_squared(zAxis) > 1.0e-8 {
          verticalAxisInParent = simd_normalize(zAxis)
        }
      }
      entity.components.set(InputTargetComponent())
      entity.components.set(HoverEffectComponent())
      /* Collision rebuild is expensive — skip on mid-stroke Immersive previews. */
      if generateCollisions {
        entity.generateCollisionShapes(recursive: true)
      }
      print("[immersive] Active object sync: \(name)")
    }

    private func findEntity(named blenderName: String, in entity: Entity) -> Entity? {
      let safeName = makeUSDSafeName(blenderName)
      if entity.name == blenderName || entity.name == safeName {
        return entity
      }
      for child in entity.children {
        if let match = findEntity(named: blenderName, in: child) {
          return match
        }
      }
      return nil
    }

    private func belongsToActiveEntity(_ entity: Entity) -> Bool {
      guard let activeEntity else { return false }
      var candidate: Entity? = entity
      while let current = candidate {
        if current === activeEntity {
          return true
        }
        candidate = current.parent
      }
      return false
    }

    private func makeUSDSafeName(_ name: String) -> String {
      var result = name.map { character -> Character in
        if character.isLetter || character.isNumber || character == "_" {
          return character
        }
        return "_"
      }
      if let first = result.first, first.isNumber {
        result.insert("_", at: result.startIndex)
      }
      return String(result)
    }
  }

  public struct BlenderImmersiveSpaceView: View {
    @State private var modelPath: String? = BlenderImmersiveState.shared.modelPath
    @State private var modelRevision: UInt64 = BlenderImmersiveState.shared.modelRevision
    @State private var activeObjectName: String =
      BlenderImmersiveState.shared.activeObjectName ?? ""
    @State private var activeObjectLocation = SIMD3<Float>(
      BlenderImmersiveState.shared.activeObjectX,
      BlenderImmersiveState.shared.activeObjectY,
      BlenderImmersiveState.shared.activeObjectZ)
    @State private var objectTransformNames = BlenderImmersiveState.shared.objectTransformNames
    @State private var objectTransformXYZ = BlenderImmersiveState.shared.objectTransformXYZ
    @State private var originX: Float = 0
    @State private var originHeight: Float = 0
    @State private var originDepth: Float = 0
    /** Monotonic token so only the latest USD load may swap the scene. */
    @State private var loadGeneration: UInt64 = 0
    @State private var isLoadingModel = false
    @State private var pendingModelReload = false
    /** Skip expensive collision rebuild during rapid mid-stroke previews. */
    @State private var lightModelReload = false
    @State private var handMenuMode = BlenderImmersiveState.shared.handMenuMode
    @State private var handMenuBrushKind = BlenderImmersiveState.shared.handMenuBrushKind
    @State private var handMenuStrength = BlenderImmersiveState.shared.handMenuStrength
    @State private var handMenuRadius = BlenderImmersiveState.shared.handMenuRadius
    @State private var handMenuBrushLabel = BlenderImmersiveState.shared.handMenuBrushLabel
    @State private var handMenuDyntopo = BlenderImmersiveState.shared.handMenuDyntopo
    /** Left hand, palm-right side — Muse is typically in the right hand.
     * Billboard keeps the panel facing the user for eye+pinch. */
    @State private var handMenuAnchor: Entity = AnchorEntity(
      .hand(.left, location: .palm), trackingMode: .continuous)
    @State private var handMenuConfigured = false
    @StateObject private var objectSync = BlenderImmersiveObjectSync()
    @StateObject private var boneOverlay = BlenderImmersiveBoneOverlay()
    @StateObject private var shaderOverlay = BlenderImmersiveShaderOverlay()
    @StateObject private var musePen = BlenderImmersiveMusePenController()
    @StateObject private var handPen = BlenderImmersiveHandPenController()
    @StateObject private var visionPlatform = BlenderVisionOSPlatformPublisher()
    @StateObject private var worldMesh = BlenderVisionOSWorldMesh()
    @StateObject private var sharedAnchor = BlenderImmersiveSharedAnchorController()
    @StateObject private var viewerPose = BlenderImmersiveViewerPoseTracker()
    @State private var bonePacked = BlenderImmersiveState.shared.bonePacked
    @State private var boneCount = BlenderImmersiveState.shared.boneCount
    @State private var shaderSpaceEnabled = BlenderImmersiveState.shared.shaderSpaceEnabled
    @State private var shaderMaterialName = BlenderImmersiveState.shared.shaderMaterialName
    @State private var shaderNodePacked = BlenderImmersiveState.shared.shaderNodePacked
    @State private var shaderNodeCount = BlenderImmersiveState.shared.shaderNodeCount
    @State private var shaderLinkPacked = BlenderImmersiveState.shared.shaderLinkPacked
    @State private var shaderLinkCount = BlenderImmersiveState.shared.shaderLinkCount
    @State private var shaderNodeNames = BlenderImmersiveState.shared.shaderNodeNames
    @State private var shaderTypeNames = BlenderImmersiveState.shared.shaderTypeNames
    @State private var shaderSockTypes = BlenderImmersiveState.shared.shaderSockTypes
    @State private var shaderSockNames = BlenderImmersiveState.shared.shaderSockNames
    @State private var useHandAsPen = BlenderImmersiveState.shared.useHandAsPen
    @State private var remotePresenceRoot = Entity()
    @State private var sceneContainer = Entity()
    @State private var immersiveWorldRoot: Entity?

    public init() {}

    private func configureHandMenuEntity(_ menuEntity: Entity) {
      if menuEntity.parent != handMenuAnchor {
        handMenuAnchor.addChild(menuEntity)
      }
      /* Do not force a fixed Euler tilt — that left the panel edge-on / covering the hand. */
      menuEntity.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
      menuEntity.components.set(BillboardComponent())
      /* Left palm: +X is toward the thumb / body-center (= right side of the left hand). */
      menuEntity.position = SIMD3(0.18, 0.07, 0.05)
      /* Keep near 1.0 for pinch hit targets. */
      menuEntity.scale = SIMD3(repeating: 0.95)
      handMenuConfigured = true
    }

    public var body: some View {
      RealityView { content, attachments in
          /* Scene container holds either free worldRoot or WorldAnchor→worldRoot. */
          let container = Entity()
          container.name = "BlenderImmersiveSceneContainer"
          content.add(container)
          sceneContainer = container

          /* One shared world root owns both Muse and the USD scene so tip
           * samples and mesh transforms share the same placement frame. */
          let worldRoot = Entity()
          worldRoot.name = "BlenderImmersiveWorld"
          container.addChild(worldRoot)
          worldRoot.position = SIMD3(
            placementOffset.x, placementOffset.y, -1.2 + placementOffset.z)
          immersiveWorldRoot = worldRoot

          objectSync.bindWorldRoot(worldRoot)
          boneOverlay.attach(to: worldRoot)
          shaderOverlay.attach(to: worldRoot)
          musePen.attach(to: worldRoot)
          handPen.attach(to: worldRoot)
          visionPlatform.attach(to: worldRoot)
          worldMesh.start(worldRoot: worldRoot)
          viewerPose.attach(content: &content, worldRoot: worldRoot)
          BlenderImmersiveState.shared.sharedAnchor = sharedAnchor
          remotePresenceRoot.name = "BlenderRemotePresence"
          worldRoot.addChild(remotePresenceRoot)
          content.add(handMenuAnchor)
          sharedAnchor.attach(sceneContainer: container, worldRoot: worldRoot)
          BlenderImmersiveMultiuserSession.shared.onRemoteSharedAnchor = { id, shared in
            Task { @MainActor in
              await sharedAnchor.adoptRemoteAnchor(idString: id, shared: shared)
            }
          }
          if let menuEntity = attachments.entity(for: "handMenu") {
            configureHandMenuEntity(menuEntity)
          }
          await sharedAnchor.start()
          await requestLoadModel(worldRoot: worldRoot)
      } update: { _, attachments in
          BlenderImmersiveState.shared.updatePlacement(
            x: placementOffset.x, y: placementOffset.y, z: placementOffset.z)
          /* When WorldAnchor owns the root, skip free placement offsets. */
          if !sharedAnchor.hasWorldOrigin {
            objectSync.updatePlacement(offset: placementOffset)
          }
          objectSync.updateActiveObject(
            name: activeObjectName, blenderLocation: activeObjectLocation)
          if !objectTransformNames.isEmpty {
            objectSync.updateObjectTransforms(
              names: objectTransformNames, locations: objectTransformLocations)
          }
          boneOverlay.update(
            packed: bonePacked, count: boneCount, visible: handMenuMode == 4)
          shaderOverlay.update(
            materialName: shaderMaterialName,
            nodePacked: shaderNodePacked,
            nodeCount: shaderNodeCount,
            names: shaderNodeNames,
            typeNames: shaderTypeNames,
            linkPacked: shaderLinkPacked,
            linkCount: shaderLinkCount,
            sockTypes: shaderSockTypes,
            sockNames: shaderSockNames,
            visible: shaderSpaceEnabled)
          /* Attach once — re-applying orientation every frame fought Billboard and
           * left the panel 90° off / covering the hand. */
          if !handMenuConfigured, let menuEntity = attachments.entity(for: "handMenu") {
            configureHandMenuEntity(menuEntity)
          }
      } attachments: {
        Attachment(id: "handMenu") {
          BlenderImmersiveHandMenuPanel(
            mode: $handMenuMode,
            radius: $handMenuRadius)
        }
      }
      /* Stable id: do NOT include modelRevision — remaking the RealityView on
       * every USD refresh tears down Muse and races Edit/Sculpt interaction. */
      .id("BlenderImmersiveSpace")
      .gesture(
        DragGesture()
          .targetedToAnyEntity()
          .onChanged { value in
            /* Material board nodes take priority while Mat overlay is interactive. */
            if shaderSpaceEnabled && shaderOverlay.isInteractive {
              let location = value.convert(
                value.location3D, from: .local, to: shaderOverlay.graphRoot)
              if shaderOverlay.dragChanged(hitEntity: value.entity, locationInRoot: location) {
                return
              }
            }
            /* Object Mode = view-only. Anim/Pose = bone grab only (no mesh drag). */
            guard handMenuMode != 0 && handMenuMode != 4 else { return }
            guard let parent = objectSync.dragParent(for: value.entity) else { return }
            let location = value.convert(value.location3D, from: .local, to: parent)
            objectSync.dragChanged(hitEntity: value.entity, locationInParent: location)
          }
          .onEnded { value in
            if shaderSpaceEnabled && shaderOverlay.isInteractive {
              shaderOverlay.dragEnded(hitEntity: value.entity)
            }
            objectSync.dragEnded()
          })
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveModelPathChanged)) {
        note in
        modelPath = note.object as? String
        modelRevision = BlenderImmersiveState.shared.modelRevision
        /* GeometryLink-style: keep the old entity visible until the new USD is
         * fully loaded, then atomically swap (attach new → detach old). */
        let tipDown = musePen.isTipDown
        lightModelReload = tipDown
        if let worldRoot = objectSync.sharedWorldRoot {
          Task { @MainActor in
            await requestLoadModel(worldRoot: worldRoot)
          }
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: .blenderImmersiveActiveObjectChanged)
      ) { note in
        guard
          let name = note.userInfo?["name"] as? String,
          let xNumber = note.userInfo?["x"] as? NSNumber,
          let yNumber = note.userInfo?["y"] as? NSNumber,
          let zNumber = note.userInfo?["z"] as? NSNumber
        else {
          return
        }
        activeObjectName = name
        activeObjectLocation = SIMD3(
          xNumber.floatValue, yNumber.floatValue, zNumber.floatValue)
      }
      .onReceive(
        NotificationCenter.default.publisher(for: .blenderImmersiveObjectTransformsChanged)
      ) { _ in
        objectTransformNames = BlenderImmersiveState.shared.objectTransformNames
        objectTransformXYZ = BlenderImmersiveState.shared.objectTransformXYZ
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveHandMenuChanged)) { _ in
        handMenuMode = BlenderImmersiveState.shared.handMenuMode
        handMenuBrushKind = BlenderImmersiveState.shared.handMenuBrushKind
        handMenuStrength = BlenderImmersiveState.shared.handMenuStrength
        handMenuRadius = BlenderImmersiveState.shared.handMenuRadius
        handMenuBrushLabel = BlenderImmersiveState.shared.handMenuBrushLabel
        handMenuDyntopo = BlenderImmersiveState.shared.handMenuDyntopo
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveBonesChanged)) { _ in
        bonePacked = BlenderImmersiveState.shared.bonePacked
        boneCount = BlenderImmersiveState.shared.boneCount
        boneOverlay.update(
          packed: bonePacked, count: boneCount, visible: handMenuMode == 4)
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveShaderGraphChanged)) {
        _ in
        shaderSpaceEnabled = BlenderImmersiveState.shared.shaderSpaceEnabled
        shaderMaterialName = BlenderImmersiveState.shared.shaderMaterialName
        shaderNodePacked = BlenderImmersiveState.shared.shaderNodePacked
        shaderNodeCount = BlenderImmersiveState.shared.shaderNodeCount
        shaderNodeNames = BlenderImmersiveState.shared.shaderNodeNames
        shaderTypeNames = BlenderImmersiveState.shared.shaderTypeNames
        shaderLinkPacked = BlenderImmersiveState.shared.shaderLinkPacked
        shaderLinkCount = BlenderImmersiveState.shared.shaderLinkCount
        shaderSockTypes = BlenderImmersiveState.shared.shaderSockTypes
        shaderSockNames = BlenderImmersiveState.shared.shaderSockNames
        shaderOverlay.setSpatialBoardWanted(BlenderImmersiveState.shared.spatialBoardWanted)
        shaderOverlay.update(
          materialName: shaderMaterialName,
          nodePacked: shaderNodePacked,
          nodeCount: shaderNodeCount,
          names: shaderNodeNames,
          typeNames: shaderTypeNames,
          linkPacked: shaderLinkPacked,
          linkCount: shaderLinkCount,
          sockTypes: shaderSockTypes,
          sockNames: shaderSockNames,
          visible: shaderSpaceEnabled)
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveSpatialBoardChanged)) {
        _ in
        shaderOverlay.setSpatialBoardWanted(BlenderImmersiveState.shared.spatialBoardWanted)
        shaderOverlay.update(
          materialName: shaderMaterialName,
          nodePacked: shaderNodePacked,
          nodeCount: shaderNodeCount,
          names: shaderNodeNames,
          typeNames: shaderTypeNames,
          linkPacked: shaderLinkPacked,
          linkCount: shaderLinkCount,
          sockTypes: shaderSockTypes,
          sockNames: shaderSockNames,
          visible: shaderSpaceEnabled)
      }
      .onReceive(
        NotificationCenter.default.publisher(for: .blenderImmersiveRemotePresenceChanged)
      ) { _ in
        refreshRemotePresence()
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersivePlacementChanged)) {
        _ in
        originX = BlenderImmersiveState.shared.placementX
        originHeight = BlenderImmersiveState.shared.placementY
        originDepth = BlenderImmersiveState.shared.placementZ
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveHandAsPenChanged)) {
        _ in
        useHandAsPen = BlenderImmersiveState.shared.useHandAsPen
        handPen.refreshStatus()
      }
      .onAppear {
        BlenderImmersiveState.shared.markActive(true)
        BlenderImmersiveState.shared.sharedAnchor = sharedAnchor
        /* Immersive Space often pauses the 2D MTKView; keep Muse→View3D sync alive. */
        GHOST_IOS_immersive_muse_tick_set_enabled(true)
        useHandAsPen = BlenderImmersiveState.shared.useHandAsPen
        modelRevision = BlenderImmersiveState.shared.modelRevision
        activeObjectName = BlenderImmersiveState.shared.activeObjectName ?? ""
        activeObjectLocation = SIMD3(
          BlenderImmersiveState.shared.activeObjectX,
          BlenderImmersiveState.shared.activeObjectY,
          BlenderImmersiveState.shared.activeObjectZ)
        objectTransformNames = BlenderImmersiveState.shared.objectTransformNames
        objectTransformXYZ = BlenderImmersiveState.shared.objectTransformXYZ
        originX = BlenderImmersiveState.shared.placementX
        originHeight = BlenderImmersiveState.shared.placementY
        originDepth = BlenderImmersiveState.shared.placementZ
      }
      .onDisappear {
        musePen.detach()
        handPen.detach()
        visionPlatform.detach()
        worldMesh.stop()
        viewerPose.detach()
        sharedAnchor.stop()
        if BlenderImmersiveState.shared.sharedAnchor === sharedAnchor {
          BlenderImmersiveState.shared.sharedAnchor = nil
        }
        BlenderImmersiveMultiuserSession.shared.onRemoteSharedAnchor = nil
        GHOST_IOS_immersive_muse_tick_set_enabled(false)
        BlenderImmersiveState.shared.markActive(false)
      }
    }

    /** Blender → RealityKit local (inverse of MusePen conversion). */
    private func blenderToRealityKit(_ blender: SIMD3<Float>) -> SIMD3<Float> {
      BlenderImmersiveCoords.blenderToRealityKit(blender)
    }

    private func refreshRemotePresence() {
      let snapshots = BlenderImmersiveMultiuserSession.shared.remotePresenceSnapshot()
      var seen = Set<String>()
      for presence in snapshots {
        seen.insert(presence.peerId)
        let entity: Entity
        if let existing = remotePresenceRoot.children.first(where: { $0.name == presence.peerId })
        {
          entity = existing
        }
        else {
          let mesh = MeshResource.generateSphere(radius: 0.012)
          let material = SimpleMaterial(
            color: UIColor(
              red: CGFloat(presence.colorR),
              green: CGFloat(presence.colorG),
              blue: CGFloat(presence.colorB),
              alpha: 0.95),
            isMetallic: false)
          let model = ModelEntity(mesh: mesh, materials: [material])
          model.name = presence.peerId
          remotePresenceRoot.addChild(model)
          entity = model
        }
        entity.position = blenderToRealityKit(
          SIMD3(presence.x, presence.y, presence.z))
        entity.scale = SIMD3(repeating: presence.tipDown ? 1.35 : 1.0)
      }
      for child in remotePresenceRoot.children where !seen.contains(child.name) {
        child.removeFromParent()
      }
    }

    private var placementOffset: SIMD3<Float> {
      SIMD3(originX, originHeight, originDepth)
    }

    /** Flat [x0,y0,z0, x1,y1,z1, ...] → [SIMD3] for `objectSync.updateObjectTransforms`. */
    private var objectTransformLocations: [SIMD3<Float>] {
      var result: [SIMD3<Float>] = []
      result.reserveCapacity(objectTransformXYZ.count / 3)
      var i = 0
      while i + 2 < objectTransformXYZ.count {
        result.append(
          SIMD3(objectTransformXYZ[i], objectTransformXYZ[i + 1], objectTransformXYZ[i + 2]))
        i += 3
      }
      return result
    }

    /**
     * Coalesce overlapping reload requests (GeometryLink also replaces only
     * after a complete load). While a load is in flight, mark pending and
     * run once more with the latest path.
     */
    @MainActor
    private func requestLoadModel(worldRoot: Entity) async {
      if isLoadingModel {
        pendingModelReload = true
        return
      }
      isLoadingModel = true
      defer { isLoadingModel = false }

      repeat {
        pendingModelReload = false
        await loadModel(worldRoot: worldRoot)
      } while pendingModelReload
    }

    /**
     * Flicker-free USD swap (inspired by GeometryLink ContentView):
     * 1. Keep the current USD entity visible
     * 2. Fully load the next USD off-parent
     * 3. Attach the new entity, then remove the old one in the same turn
     * Never remove-first — that blank gap is the Immersive flicker.
     * See https://github.com/daniloc/GeometryLink/
     */
    @MainActor
    private func loadModel(worldRoot: Entity) async {
      loadGeneration &+= 1
      let generation = loadGeneration
      let path = modelPath ?? BlenderImmersiveState.shared.modelPath

      let newEntity: Entity
      if let path, !path.isEmpty {
        do {
          /* Load while the previous USD stays on-screen. */
          newEntity = try await Entity(contentsOf: URL(fileURLWithPath: path))
        }
        catch {
          /* Keep the previous model if this revision failed. */
          print("[immersive] Failed to load USDZ \(path): \(error)")
          return
        }
      }
      else {
        let placeholder = ModelEntity(
          mesh: .generateBox(size: 0.2),
          materials: [SimpleMaterial(color: .systemBlue, isMetallic: true)])
        placeholder.position = SIMD3(0, 1.2, 0)
        newEntity = placeholder
      }

      /* A newer reload started while we were awaiting — discard this result. */
      guard generation == loadGeneration else {
        return
      }

      newEntity.name = "BlenderImmersiveUSD"
      /* USD exports Blender units as meters. Keep the authored scale exactly:
       * the default 2x2x2 cube must appear as a 2-meter cube in visionOS.
       * Placement lives on worldRoot — leave the USD file root at identity. */

      let oldUSD = worldRoot.children.filter { $0.name == "BlenderImmersiveUSD" }
      worldRoot.addChild(newEntity)
      for old in oldUSD {
        old.removeFromParent()
      }

      objectSync.configure(
        worldRoot: worldRoot,
        sceneRoot: newEntity,
        placementOffset: placementOffset,
        generateCollisions: !lightModelReload)
      lightModelReload = false
    }

  }

#endif
