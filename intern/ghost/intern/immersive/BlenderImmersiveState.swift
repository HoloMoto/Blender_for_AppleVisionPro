/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Shared identifiers / notifications for Vision Pro Immersive Space.
 */

import Foundation

public let BlenderImmersiveSpaceID = "blender.scene.immersive"

public extension Notification.Name {
  static let blenderOpenImmersiveSpace = Notification.Name("blender.openImmersiveSpace")
  static let blenderDismissImmersiveSpace = Notification.Name("blender.dismissImmersiveSpace")
  static let blenderImmersiveModelPathChanged = Notification.Name(
    "blender.immersiveModelPathChanged")
  static let blenderImmersiveActiveObjectChanged = Notification.Name(
    "blender.immersiveActiveObjectChanged")
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

  private override init() {
    super.init()
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
}
