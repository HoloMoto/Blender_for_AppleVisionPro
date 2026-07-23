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
      let delta = blenderLocation - blenderBaseLocation
      activeEntity.position =
        entityBasePosition
        + xAxisInParent * delta.x
        + yAxisInParent * delta.y
        + verticalAxisInParent * delta.z
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
    /** Float above left hand — Muse is typically held in the right hand.
     * `.aboveHand` stays clear of the palm; Billboard keeps the panel facing the user
     * so eye+pinch selection works regardless of wrist tilt. */
    @State private var leftHandAnchor: Entity = AnchorEntity(
      .hand(.left, location: .aboveHand), trackingMode: .continuous)
    @State private var handMenuConfigured = false
    @StateObject private var objectSync = BlenderImmersiveObjectSync()
    @StateObject private var musePen = BlenderImmersiveMusePenController()
    @State private var remotePresenceRoot = Entity()

    public init() {}

    private func configureHandMenuEntity(_ menuEntity: Entity) {
      if menuEntity.parent != leftHandAnchor {
        leftHandAnchor.addChild(menuEntity)
      }
      /* Do not force a fixed Euler tilt — that left the panel edge-on / covering the hand. */
      menuEntity.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
      menuEntity.components.set(BillboardComponent())
      menuEntity.position = SIMD3(0, 0.04, 0)
      menuEntity.scale = SIMD3(repeating: 0.55)
      handMenuConfigured = true
    }

    public var body: some View {
      RealityView { content, attachments in
          /* One shared world root owns both Muse and the USD scene so tip
           * samples and mesh transforms share the same placement frame. */
          let worldRoot = Entity()
          worldRoot.name = "BlenderImmersiveWorld"
          content.add(worldRoot)
          worldRoot.position = SIMD3(
            placementOffset.x, placementOffset.y, -1.2 + placementOffset.z)

          objectSync.bindWorldRoot(worldRoot)
          musePen.attach(to: worldRoot)
          remotePresenceRoot.name = "BlenderRemotePresence"
          worldRoot.addChild(remotePresenceRoot)
          content.add(leftHandAnchor)
          if let menuEntity = attachments.entity(for: "handMenu") {
            configureHandMenuEntity(menuEntity)
          }
          await requestLoadModel(worldRoot: worldRoot)
      } update: { _, attachments in
          BlenderImmersiveState.shared.updatePlacement(
            x: placementOffset.x, y: placementOffset.y, z: placementOffset.z)
          objectSync.updatePlacement(offset: placementOffset)
          objectSync.updateActiveObject(
            name: activeObjectName, blenderLocation: activeObjectLocation)
          /* Attach once — re-applying orientation every frame fought Billboard and
           * left the panel 90° off / covering the hand. */
          if !handMenuConfigured, let menuEntity = attachments.entity(for: "handMenu") {
            configureHandMenuEntity(menuEntity)
          }
      } attachments: {
        Attachment(id: "handMenu") {
          BlenderImmersiveHandMenuPanel(
            mode: $handMenuMode,
            brushKind: $handMenuBrushKind,
            strength: $handMenuStrength,
            radius: $handMenuRadius,
            brushLabel: handMenuBrushLabel,
            compact: true)
        }
      }
      /* Stable id: do NOT include modelRevision — remaking the RealityView on
       * every USD refresh tears down Muse and races Edit/Sculpt interaction. */
      .id("BlenderImmersiveSpace")
      .gesture(
        DragGesture()
          .targetedToAnyEntity()
          .onChanged { value in
            guard let parent = objectSync.dragParent(for: value.entity) else { return }
            let location = value.convert(value.location3D, from: .local, to: parent)
            objectSync.dragChanged(hitEntity: value.entity, locationInParent: location)
          }
          .onEnded { _ in
            objectSync.dragEnded()
          })
      .ornament(visibility: .automatic, attachmentAnchor: .scene(.bottom)) {
        VStack(spacing: 12) {
          Text(musePen.statusText)
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassBackgroundEffect()
          Text("左手の上にも同じメニュー")
            .font(.caption2)
            .foregroundStyle(.secondary)
          BlenderImmersiveHandMenuPanel(
            mode: $handMenuMode,
            brushKind: $handMenuBrushKind,
            strength: $handMenuStrength,
            radius: $handMenuRadius,
            brushLabel: handMenuBrushLabel,
            compact: false)
          placementControls
        }
        .padding(.bottom, 28)
      }
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
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveHandMenuChanged)) { _ in
        handMenuMode = BlenderImmersiveState.shared.handMenuMode
        handMenuBrushKind = BlenderImmersiveState.shared.handMenuBrushKind
        handMenuStrength = BlenderImmersiveState.shared.handMenuStrength
        handMenuRadius = BlenderImmersiveState.shared.handMenuRadius
        handMenuBrushLabel = BlenderImmersiveState.shared.handMenuBrushLabel
      }
      .onReceive(
        NotificationCenter.default.publisher(for: .blenderImmersiveRemotePresenceChanged)
      ) { _ in
        refreshRemotePresence()
      }
      .onAppear {
        BlenderImmersiveState.shared.markActive(true)
        /* Immersive Space often pauses the 2D MTKView; keep Muse→View3D sync alive. */
        GHOST_IOS_immersive_muse_tick_set_enabled(true)
        modelRevision = BlenderImmersiveState.shared.modelRevision
        activeObjectName = BlenderImmersiveState.shared.activeObjectName ?? ""
        activeObjectLocation = SIMD3(
          BlenderImmersiveState.shared.activeObjectX,
          BlenderImmersiveState.shared.activeObjectY,
          BlenderImmersiveState.shared.activeObjectZ)
      }
      .onDisappear {
        musePen.detach()
        GHOST_IOS_immersive_muse_tick_set_enabled(false)
        BlenderImmersiveState.shared.markActive(false)
      }
    }

    /** Blender → RealityKit local (inverse of MusePen conversion). */
    private func blenderToRealityKit(_ blender: SIMD3<Float>) -> SIMD3<Float> {
      SIMD3(blender.x, blender.z, -blender.y)
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

    private var placementControls: some View {
      VStack(spacing: 10) {
        HStack {
          Label("モデルの原点", systemImage: "move.3d")
            .font(.headline)
          Spacer()
          Button("床に戻す") {
            originX = 0
            originHeight = 0
            originDepth = 0
          }
        }

        placementSlider(
          title: "左右", value: $originX, range: -3...3,
          valueText: String(format: "%+.2f m", originX))
        placementSlider(
          title: "高さ", value: $originHeight, range: -1...3,
          valueText: String(format: "%+.2f m", originHeight))
        placementSlider(
          title: "奥行き", value: $originDepth, range: -3...1,
          valueText: String(format: "%+.2f m", originDepth))
      }
      .padding(18)
      .frame(width: 460)
      .glassBackgroundEffect()
    }

    private func placementSlider(
      title: String,
      value: Binding<Float>,
      range: ClosedRange<Float>,
      valueText: String
    ) -> some View {
      HStack(spacing: 12) {
        Text(title)
          .frame(width: 48, alignment: .leading)
        Slider(value: value, in: range, step: 0.05)
        Text(valueText)
          .monospacedDigit()
          .frame(width: 80, alignment: .trailing)
      }
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
