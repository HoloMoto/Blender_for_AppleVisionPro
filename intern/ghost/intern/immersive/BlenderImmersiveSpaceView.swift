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

#if os(visionOS)

  public struct BlenderImmersiveSpaceView: View {
    @State private var modelPath: String? = BlenderImmersiveState.shared.modelPath

    public init() {}

    public var body: some View {
      RealityView { content in
        await loadModel(into: content)
      } update: { content in
        Task {
          await loadModel(into: content)
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveModelPathChanged)) {
        note in
        modelPath = note.object as? String
      }
      .onAppear {
        BlenderImmersiveState.shared.markActive(true)
      }
      .onDisappear {
        BlenderImmersiveState.shared.markActive(false)
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
        normalizeForRoomScale(entity)
        entity.position = SIMD3(0, 0, -1.2)
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

    private func normalizeForRoomScale(_ entity: Entity) {
      let bounds = entity.visualBounds(relativeTo: nil)
      let extents = bounds.extents
      let largest = max(extents.x, max(extents.y, extents.z))
      let target: Float = 0.6
      if largest > 1.0e-4 {
        let scale = target / largest
        entity.scale = SIMD3(repeating: scale)
      }
      /* Sit the model on the floor plane of its bounds. */
      let minY = bounds.min.y * entity.scale.y
      entity.position.y -= minY
    }
  }

#endif
