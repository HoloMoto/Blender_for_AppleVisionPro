/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * ObjC-callable bridge into Immersive Space open/dismiss.
 * On non-visionOS builds these are stubs so the iPad AR path remains the fallback.
 */

import Foundation

@objc(BlenderImmersiveBridge)
public final class BlenderImmersiveBridge: NSObject {
  @objc public static func setModelPath(_ path: String?) {
    BlenderImmersiveState.shared.setModelPath(path)
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
    BlenderImmersiveState.shared.isActive
  }
}
