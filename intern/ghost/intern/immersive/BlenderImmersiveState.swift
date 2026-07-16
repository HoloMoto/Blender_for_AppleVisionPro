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
}

@objc public final class BlenderImmersiveState: NSObject {
  @objc public static let shared = BlenderImmersiveState()

  @objc public private(set) var modelPath: String?
  @objc public private(set) var isActive: Bool = false

  private override init() {
    super.init()
  }

  @objc public func setModelPath(_ path: String?) {
    modelPath = path
    NotificationCenter.default.post(
      name: .blenderImmersiveModelPathChanged, object: path)
  }

  @objc public func markActive(_ active: Bool) {
    isActive = active
  }
}
