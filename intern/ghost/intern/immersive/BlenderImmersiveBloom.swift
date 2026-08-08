/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Stub when building against XROS < 27 (BloomComponent unavailable).
 * Full implementation: BlenderImmersiveBloom_v27.swift (XROS 27+ only).
 */

import RealityKit

#if os(visionOS)

  @MainActor
  enum BlenderImmersiveBloom {
    static func apply(worldRoot: Entity, sceneRoot: Entity) {
      _ = worldRoot
      _ = sceneRoot
    }
  }

#endif
