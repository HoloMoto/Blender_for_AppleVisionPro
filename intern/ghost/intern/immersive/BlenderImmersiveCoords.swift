/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Shared RealityKit ↔ Blender axis conversion for Immersive Space.
 *
 * Blender is Z-up. RealityKit / USD (convert_orientation) is Y-up:
 *   Blender (x, y, z) → RK/USD (x, z, -y)
 *   RK/USD  (x, y, z) → Blender (x, -z, y)
 *
 * Immersive gravity-up (RK +Y) MUST map to Blender +Z (not +Y).
 */

import simd

#if os(visionOS)

  enum BlenderImmersiveCoords {
    /** RealityKit / USD local → Blender world. */
    static func realityKitToBlender(_ v: SIMD3<Float>) -> SIMD3<Float> {
      SIMD3(v.x, -v.z, v.y)
    }

    /** Blender world → RealityKit / USD local. */
    static func blenderToRealityKit(_ v: SIMD3<Float>) -> SIMD3<Float> {
      SIMD3(v.x, v.z, -v.y)
    }

    /**
     * Map a RealityKit transform (relative to Immersive worldRoot) into a
     * Blender world matrix. Linear map M is applied to basis + translation:
     *   T_blender = M ∘ T_rk
     */
    static func realityKitMatrixToBlender(_ m: simd_float4x4) -> simd_float4x4 {
      let c0 = realityKitToBlender(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
      let c1 = realityKitToBlender(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
      let c2 = realityKitToBlender(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
      let t = realityKitToBlender(SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z))
      return simd_float4x4(
        SIMD4(c0.x, c0.y, c0.z, 0),
        SIMD4(c1.x, c1.y, c1.z, 0),
        SIMD4(c2.x, c2.y, c2.z, 0),
        SIMD4(t.x, t.y, t.z, 1))
    }
  }

#endif
