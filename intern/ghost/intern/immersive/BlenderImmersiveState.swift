/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Shared identifiers / notifications for Vision Pro Immersive Space.
 */

import Foundation
import simd

public let BlenderImmersiveSpaceID = "blender.scene.immersive"

public extension Notification.Name {
  static let blenderOpenImmersiveSpace = Notification.Name("blender.openImmersiveSpace")
  static let blenderDismissImmersiveSpace = Notification.Name("blender.dismissImmersiveSpace")
  static let blenderImmersiveModelPathChanged = Notification.Name(
    "blender.immersiveModelPathChanged")
  static let blenderImmersiveActiveObjectChanged = Notification.Name(
    "blender.immersiveActiveObjectChanged")
  static let blenderImmersiveHandMenuChanged = Notification.Name(
    "blender.immersiveHandMenuChanged")
}

@objc public final class BlenderImmersiveState: NSObject {
  @objc public static let shared = BlenderImmersiveState()

  @objc public private(set) var modelPath: String?
  @objc public private(set) var modelRevision: UInt64 = 0
  @objc public private(set) var isActive: Bool = false
  @objc public private(set) var activeObjectName: String?
  @objc public private(set) var activeObjectX: Float = 0
  @objc public private(set) var activeObjectY: Float = 0
  @objc public private(set) var activeObjectZ: Float = 0
  /** Immersive scene placement offset (meters). Used by Muse → Blender projection. */
  @objc public private(set) var placementX: Float = 0
  @objc public private(set) var placementY: Float = 0
  @objc public private(set) var placementZ: Float = 0

  /** 0 object / 1 edit / 2 sculpt */
  @objc public private(set) var handMenuMode: Int = 0
  @objc public private(set) var handMenuStrength: Float = 0.5
  @objc public private(set) var handMenuRadius: Float = 0.25
  /** 0 Draw / 1 Clay / 2 Grab / 3 Smooth / 4 Inflate+ / 5 Inflate− */
  @objc public private(set) var handMenuBrushKind: Int = 4
  @objc public private(set) var handMenuBrushLabel: String = "Inflate+"

  public var placementOffset: SIMD3<Float> {
    SIMD3(placementX, placementY, placementZ)
  }

  private override init() {
    super.init()
  }

  @objc public func updatePlacement(x: Float, y: Float, z: Float) {
    placementX = x
    placementY = y
    placementZ = z
  }

  @objc public func updateModelPath(_ path: String?) {
    modelPath = path
    modelRevision &+= 1
    NotificationCenter.default.post(
      name: .blenderImmersiveModelPathChanged, object: path)
  }

  @objc public func markActive(_ active: Bool) {
    isActive = active
  }

  @objc public func updateActiveObject(_ name: String?, x: Float, y: Float, z: Float) {
    activeObjectName = name
    activeObjectX = x
    activeObjectY = y
    activeObjectZ = z
    NotificationCenter.default.post(
      name: .blenderImmersiveActiveObjectChanged,
      object: nil,
      userInfo: ["name": name ?? "", "x": x, "y": y, "z": z])
  }

  @objc public func updateHandMenu(
    mode: Int, strength: Float, radius: Float, brushLabel: String?, brushKind: Int
  ) {
    handMenuMode = mode
    handMenuStrength = strength
    handMenuRadius = radius
    handMenuBrushLabel = brushLabel ?? "Draw"
    handMenuBrushKind = brushKind
    NotificationCenter.default.post(name: .blenderImmersiveHandMenuChanged, object: nil)
  }
}
