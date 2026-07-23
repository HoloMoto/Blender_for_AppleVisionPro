/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * ObjC-callable bridge into Immersive Space open/dismiss (visionOS / Vision Pro).
 */

import Foundation

@objc(BlenderImmersiveBridge)
public final class BlenderImmersiveBridge: NSObject {
  @objc public static func setModelPath(_ path: String?) {
    BlenderImmersiveState.shared.updateModelPath(path)
  }

  @objc public static func openImmersiveSpace() -> Bool {
    #if os(visionOS)
      NotificationCenter.default.post(name: .blenderOpenImmersiveSpace, object: nil)
      return true
    #else
      return false
    #endif
  }

  @objc public static func dismissImmersiveSpace() -> Bool {
    #if os(visionOS)
      NotificationCenter.default.post(name: .blenderDismissImmersiveSpace, object: nil)
      return true
    #else
      return false
    #endif
  }

  @objc public static func isActive() -> Bool {
    #if os(visionOS)
      return BlenderImmersiveState.shared.isActive
    #else
      return false
    #endif
  }

  @objc(updateActiveObject:x:y:z:)
  public static func updateActiveObject(_ name: String?, x: Float, y: Float, z: Float) {
    #if os(visionOS)
      DispatchQueue.main.async {
        BlenderImmersiveState.shared.updateActiveObject(name, x: x, y: y, z: z)
      }
    #endif
  }

  @objc(updateHandMenuMode:strength:radius:brushLabel:brushKind:)
  public static func updateHandMenuMode(
    _ mode: Int32, strength: Float, radius: Float, brushLabel: String?, brushKind: Int32
  ) {
    #if os(visionOS)
      DispatchQueue.main.async {
        BlenderImmersiveState.shared.updateHandMenu(
          mode: Int(mode),
          strength: strength,
          radius: radius,
          brushLabel: brushLabel,
          brushKind: Int(brushKind))
      }
    #endif
  }
}
