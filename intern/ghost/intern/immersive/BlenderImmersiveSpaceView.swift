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
import simd

#if os(visionOS)

  @_silgen_name("WM_IOS_immersive_set_object_z")
  private func WM_IOS_immersive_set_object_z(
    _ objectName: UnsafePointer<CChar>, _ z: Float)

  @MainActor
  private final class BlenderImmersiveObjectSync: ObservableObject {
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

    func configure(root: Entity, placementOffset: SIMD3<Float>) {
      rootEntity = root
      updatePlacement(offset: placementOffset)
      activeEntity = nil
      dragStartLocation = nil
      if !activeObjectName.isEmpty {
        selectActiveEntity(name: activeObjectName, blenderLocation: blenderBaseLocation)
      }
    }

    func updatePlacement(offset: SIMD3<Float>) {
      /* RealityKit is Y-up. Keep Blender's floor origin at Y=0 by default,
       * with the scene placed 1.2 meters in front of the wearer. */
      rootEntity?.position = SIMD3(offset.x, offset.y, -1.2 + offset.z)
    }

    func updateActiveObject(name: String, blenderLocation: SIMD3<Float>) {
      guard !name.isEmpty else { return }
      if name != activeObjectName || activeEntity == nil {
        activeObjectName = name
        selectActiveEntity(name: name, blenderLocation: blenderLocation)
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

    private func selectActiveEntity(name: String, blenderLocation: SIMD3<Float>) {
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
      entity.generateCollisionShapes(recursive: true)
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
    @StateObject private var objectSync = BlenderImmersiveObjectSync()

    public init() {}

    public var body: some View {
      ZStack(alignment: .bottom) {
        RealityView { content in
          await loadModel(into: content)
        } update: { _ in
          objectSync.updatePlacement(offset: placementOffset)
          objectSync.updateActiveObject(
            name: activeObjectName, blenderLocation: activeObjectLocation)
        }
        .id("\(modelPath ?? "")#\(modelRevision)")
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

        placementControls
          .padding(.bottom, 28)
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveModelPathChanged)) {
        note in
        modelPath = note.object as? String
        modelRevision = BlenderImmersiveState.shared.modelRevision
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
      .onAppear {
        BlenderImmersiveState.shared.markActive(true)
        modelRevision = BlenderImmersiveState.shared.modelRevision
        activeObjectName = BlenderImmersiveState.shared.activeObjectName ?? ""
        activeObjectLocation = SIMD3(
          BlenderImmersiveState.shared.activeObjectX,
          BlenderImmersiveState.shared.activeObjectY,
          BlenderImmersiveState.shared.activeObjectZ)
      }
      .onDisappear {
        BlenderImmersiveState.shared.markActive(false)
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

    @MainActor
    private func loadModel(into content: RealityViewContent) async {
      content.entities.removeAll()

      let path = modelPath ?? BlenderImmersiveState.shared.modelPath
      guard let path, !path.isEmpty else {
        let placeholder = ModelEntity(
          mesh: .generateBox(size: 0.2),
          materials: [SimpleMaterial(color: .systemBlue, isMetallic: true)])
        placeholder.position = SIMD3(0, 1.2, -1.0)
        content.add(placeholder)
        return
      }

      let url = URL(fileURLWithPath: path)
      do {
        let entity = try await Entity(contentsOf: url)
        /* USD exports Blender units as meters. Keep the authored scale exactly:
         * the default 2x2x2 cube must appear as a 2-meter cube in visionOS. */
        objectSync.configure(root: entity, placementOffset: placementOffset)
        content.add(entity)
      }
      catch {
        let placeholder = ModelEntity(
          mesh: .generateBox(size: 0.2),
          materials: [SimpleMaterial(color: .systemOrange, isMetallic: false)])
        placeholder.position = SIMD3(0, 1.2, -1.0)
        content.add(placeholder)
        print("[immersive] Failed to load USDZ \(path): \(error)")
      }
    }

  }

#endif
