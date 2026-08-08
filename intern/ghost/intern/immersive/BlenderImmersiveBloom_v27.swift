/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * visionOS 27 BloomComponent wiring (compiled only with XROS 27+ SDK).
 *
 * https://developer.apple.com/documentation/realitykit/bloomcomponent
 */

import Foundation
import RealityKit
import UIKit

#if os(visionOS)

  @MainActor
  enum BlenderImmersiveBloom {
    private static let defaultStrength: Float = 0.9
    private static let defaultThreshold: Float = 0.55
    private static let defaultBlurRadius: Float = 8

    static func apply(worldRoot: Entity, sceneRoot: Entity) {
      if #available(visionOS 27.0, *) {
        applyV27(worldRoot: worldRoot, sceneRoot: sceneRoot)
      }
    }

    @available(visionOS 27.0, *)
    private static func applyV27(worldRoot: Entity, sceneRoot: Entity) {
      var options = BloomOptionsComponent()
      options.strength = strengthForThermalState(ProcessInfo.processInfo.thermalState)
      options.threshold = defaultThreshold
      options.blurRadius = defaultBlurRadius
      worldRoot.components.set(options)
      worldRoot.components.remove(BloomComponent.self)

      var bloomCount = 0
      visit(sceneRoot) { entity in
        guard entityHasEmissiveMaterial(entity) else {
          entity.components.remove(BloomComponent.self)
          return
        }
        entity.components.set(BloomComponent(scope: .hierarchical))
        bloomCount += 1
      }

      print(
        "[immersive] BloomComponent hierarchical on \(bloomCount) emissive "
          + "entities (strength=\(options.strength))")
    }

    @available(visionOS 27.0, *)
    private static func strengthForThermalState(_ state: ProcessInfo.ThermalState) -> Float {
      switch state {
      case .nominal: return defaultStrength
      case .fair: return defaultStrength * 0.75
      case .serious: return defaultStrength * 0.4
      case .critical: return 0
      @unknown default: return defaultStrength * 0.5
      }
    }

    private static func visit(_ entity: Entity, _ body: (Entity) -> Void) {
      body(entity)
      for child in entity.children {
        visit(child, body)
      }
    }

    private static func entityHasEmissiveMaterial(_ entity: Entity) -> Bool {
      guard let model = entity.components[ModelComponent.self] else {
        return false
      }
      for material in model.materials {
        if materialLooksEmissive(material) {
          return true
        }
      }
      return false
    }

    private static func materialLooksEmissive(_ material: any Material) -> Bool {
      guard let pbr = material as? PhysicallyBasedMaterial else {
        return false
      }
      if pbr.emissiveIntensity > 0.01 {
        return true
      }
      if pbr.emissiveColor.texture != nil {
        return true
      }
      return colorLooksEmissive(pbr.emissiveColor.__color)
    }

    private static func colorLooksEmissive(_ cg: CGColor) -> Bool {
      guard let comps = cg.components, !comps.isEmpty else {
        return false
      }
      let r: CGFloat
      let g: CGFloat
      let b: CGFloat
      if comps.count >= 3 {
        r = comps[0]
        g = comps[1]
        b = comps[2]
      }
      else {
        r = comps[0]
        g = comps[0]
        b = comps[0]
      }
      let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
      return luma > 0.02
    }
  }

#endif
