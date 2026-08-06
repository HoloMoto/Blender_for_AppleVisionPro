/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Shared SpatialTrackingSession for Immersive Space.
 * One session per Immersive — concurrent run() breaks ARKit providers.
 * Muse (accessory) and HandPen (hand) both call ensure(capabilities:).
 */

import Foundation
import RealityKit

#if os(visionOS)

  @MainActor
  enum BlenderImmersiveSpatialTracking {
    private static var session: SpatialTrackingSession?
    private static var lifecycle: Lifecycle = .idle
    private static var activeCapabilities:
      Set<SpatialTrackingSession.Configuration.AnchorCapability> = []

    private enum Lifecycle {
      case idle
      case starting
      case running
    }

    /** Ensure a SpatialTrackingSession covering at least `capabilities` is running. */
    static func ensure(
      capabilities: Set<SpatialTrackingSession.Configuration.AnchorCapability>
    ) async -> Bool {
      if lifecycle == .running, capabilities.isSubset(of: activeCapabilities) {
        return true
      }
      if lifecycle == .starting {
        /* Wait briefly for in-flight start. */
        for _ in 0..<40 {
          try? await Task.sleep(nanoseconds: 50_000_000)
          if lifecycle == .running, capabilities.isSubset(of: activeCapabilities) {
            return true
          }
          if lifecycle == .idle {
            break
          }
        }
        if lifecycle == .running, capabilities.isSubset(of: activeCapabilities) {
          return true
        }
      }

      lifecycle = .starting
      let merged = activeCapabilities.union(capabilities)
      if let existing = session {
        await existing.stop()
        session = nil
      }

      let configuration = SpatialTrackingSession.Configuration(tracking: merged)
      let next = SpatialTrackingSession()
      print("[immersive] SpatialTracking ensure caps=\(merged)")
      if let unavailable = await next.run(configuration) {
        print("[immersive] SpatialTracking unavailable: \(unavailable)")
        /* Still usable if required caps are not among unavailable. */
        let missing = capabilities.intersection(unavailable.anchor)
        if !missing.isEmpty {
          lifecycle = .idle
          activeCapabilities = []
          await next.stop()
          return false
        }
      }

      session = next
      activeCapabilities = merged
      lifecycle = .running
      print("[immersive] SpatialTracking running caps=\(merged)")
      return true
    }

    static func stop() async {
      lifecycle = .idle
      activeCapabilities = []
      if let existing = session {
        session = nil
        await existing.stop()
      }
    }
  }

#endif
