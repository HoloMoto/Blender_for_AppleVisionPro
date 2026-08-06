/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Co-located Immersive origin via ARKit WorldAnchor.
 *
 * Host places a WorldAnchor at the shared scene origin and broadcasts its UUID
 * over Multipeer. Guests:
 *   1) Prefer ARKit shared anchors (same UUID) when SharePlay-nearby enables
 *      worldAnchorSharingAvailability, or
 *   2) Fall back to "Align here" — create a local WorldAnchor at the guest's
 *      current placement (stand where the host's content should sit).
 *
 * Content (USD + Muse) is reparented under AnchorEntity(WorldAnchor).
 */

import ARKit
import Foundation
import RealityKit
import simd

#if os(visionOS)

  public extension Notification.Name {
    static let blenderImmersiveSharedAnchorChanged = Notification.Name(
      "blender.immersiveSharedAnchorChanged")
  }

  @MainActor
  final class BlenderImmersiveSharedAnchorController: ObservableObject {
    @Published private(set) var statusText = "Anchor: 未設定"
    @Published private(set) var isRunning = false
    @Published private(set) var hasWorldOrigin = false
    @Published private(set) var sharingAvailable = false
    @Published private(set) var anchorIDString: String?

    private var arSession = ARKitSession()
    private var worldProvider = WorldTrackingProvider()
    private var updatesTask: Task<Void, Never>?
    private var sharingTask: Task<Void, Never>?
    /** Scene container that owns either free-floating worldRoot or the WorldAnchor entity. */
    private weak var sceneContainer: Entity?
    private weak var worldRoot: Entity?
    private var worldAnchorEntity: AnchorEntity?
    private var activeWorldAnchor: WorldAnchor?
    private var pendingAdoptID: UUID?
    private var knownAnchors: [UUID: WorldAnchor] = [:]

    func attach(sceneContainer: Entity, worldRoot: Entity) {
      self.sceneContainer = sceneContainer
      self.worldRoot = worldRoot
    }

    func start() async {
      guard !isRunning else { return }
      do {
        let auth = await arSession.requestAuthorization(for: [.worldSensing])
        if auth[.worldSensing] != .allowed {
          statusText = "Anchor: World Sensing 権限が必要"
          publish()
          return
        }
        try await arSession.run([worldProvider])
        isRunning = true
        statusText = "Anchor: トラッキング中"
        listenForAnchorUpdates()
        listenForSharingAvailability()
        publish()
      }
      catch {
        statusText = "Anchor: 開始失敗 \(error.localizedDescription)"
        publish()
      }
    }

    func stop() {
      updatesTask?.cancel()
      updatesTask = nil
      sharingTask?.cancel()
      sharingTask = nil
      if let anchor = activeWorldAnchor {
        Task { try? await worldProvider.removeAnchor(anchor) }
      }
      detachWorldRootFromAnchor()
      worldAnchorEntity?.removeFromParent()
      worldAnchorEntity = nil
      activeWorldAnchor = nil
      knownAnchors.removeAll()
      pendingAdoptID = nil
      anchorIDString = nil
      hasWorldOrigin = false
      isRunning = false
      statusText = "Anchor: 停止"
      publish()
    }

    /**
     * Host: pin current worldRoot transform as the shared physical origin.
     * Tries sharedWithNearbyParticipants when ARKit reports sharing available.
     */
    func placeHostOrigin() async -> UUID? {
      await start()
      guard isRunning, let root = worldRoot else {
        statusText = "Anchor: Immersive 未準備"
        publish()
        return nil
      }
      let transform = root.transformMatrix(relativeTo: nil)
      do {
        let share = sharingAvailable
        let anchor = WorldAnchor(
          originFromAnchorTransform: transform,
          sharedWithNearbyParticipants: share)
        try await worldProvider.addAnchor(anchor)
        knownAnchors[anchor.id] = anchor
        activeWorldAnchor = anchor
        bindContent(to: anchor)
        anchorIDString = anchor.id.uuidString
        hasWorldOrigin = true
        statusText =
          share
          ? "Anchor: 共有原点 OK (SharePlay)"
          : "Anchor: 原点固定（ゲストは『ここに合わせる』）"
        publish()
        BlenderImmersiveMultiuserSession.shared.broadcastSharedAnchor(
          id: anchor.id.uuidString, shared: share)
        return anchor.id
      }
      catch {
        statusText = "Anchor: 設置失敗 \(error.localizedDescription)"
        publish()
        return nil
      }
    }

    /** Guest: wait for ARKit shared anchor with this UUID (SharePlay path). */
    func adoptRemoteAnchor(idString: String, shared: Bool) async {
      guard let id = UUID(uuidString: idString) else { return }
      await start()
      pendingAdoptID = id
      if let existing = knownAnchors[id] {
        activeWorldAnchor = existing
        bindContent(to: existing)
        anchorIDString = existing.id.uuidString
        hasWorldOrigin = true
        statusText = "Anchor: 共有原点を受信"
        publish()
        return
      }
      statusText =
        shared
        ? "Anchor: 共有原点待ち…"
        : "Anchor: ID受信 — 同じ場所で『ここに合わせる』"
      publish()
    }

    /**
     * Guest fallback: stand where host content should appear, then pin a local
     * WorldAnchor at the current worldRoot pose.
     */
    func alignHere() async {
      await start()
      guard isRunning, let root = worldRoot else {
        statusText = "Anchor: Immersive 未準備"
        publish()
        return
      }
      let transform = root.transformMatrix(relativeTo: nil)
      do {
        let anchor = WorldAnchor(originFromAnchorTransform: transform)
        try await worldProvider.addAnchor(anchor)
        knownAnchors[anchor.id] = anchor
        activeWorldAnchor = anchor
        bindContent(to: anchor)
        anchorIDString = anchor.id.uuidString
        hasWorldOrigin = true
        pendingAdoptID = nil
        statusText = "Anchor: ここに合わせた"
        publish()
      }
      catch {
        statusText = "Anchor: 合わせ失敗 \(error.localizedDescription)"
        publish()
      }
    }

    private func listenForAnchorUpdates() {
      updatesTask?.cancel()
      updatesTask = Task { [weak self] in
        guard let self else { return }
        for await update in self.worldProvider.anchorUpdates {
          guard !Task.isCancelled else { return }
          let anchor = update.anchor
          switch update.event {
          case .added, .updated:
            self.knownAnchors[anchor.id] = anchor
            if let pending = self.pendingAdoptID, pending == anchor.id {
              self.activeWorldAnchor = anchor
              self.bindContent(to: anchor)
              self.anchorIDString = anchor.id.uuidString
              self.hasWorldOrigin = true
              self.pendingAdoptID = nil
              self.statusText = "Anchor: 共有原点に接続"
              self.publish()
            }
          case .removed:
            self.knownAnchors.removeValue(forKey: anchor.id)
            if self.anchorIDString == anchor.id.uuidString {
              self.detachWorldRootFromAnchor()
              self.worldAnchorEntity?.removeFromParent()
              self.worldAnchorEntity = nil
              self.activeWorldAnchor = nil
              self.hasWorldOrigin = false
              self.anchorIDString = nil
              self.statusText = "Anchor: 原点が削除された"
              self.publish()
            }
          @unknown default:
            break
          }
        }
      }
    }

    private func listenForSharingAvailability() {
      sharingTask?.cancel()
      sharingTask = Task { [weak self] in
        guard let self else { return }
        for await availability in self.worldProvider.worldAnchorSharingAvailability {
          guard !Task.isCancelled else { return }
          switch availability {
          case .available:
            self.sharingAvailable = true
            if self.statusText.contains("トラッキング") || self.statusText.contains("手動") {
              self.statusText = "Anchor: SharePlay共有が利用可能"
            }
          case .unavailable:
            self.sharingAvailable = false
          @unknown default:
            self.sharingAvailable = false
          }
          self.publish()
        }
      }
    }

    private func bindContent(to anchor: WorldAnchor) {
      guard let container = sceneContainer, let root = worldRoot else { return }
      worldAnchorEntity?.removeFromParent()
      let entity = AnchorEntity(anchor)
      entity.name = anchor.id.uuidString
      container.addChild(entity)
      worldAnchorEntity = entity

      if root.parent != entity {
        root.removeFromParent()
        root.position = .zero
        root.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        entity.addChild(root)
      }
      hasWorldOrigin = true
    }

    private func detachWorldRootFromAnchor() {
      guard let root = worldRoot, let container = sceneContainer else { return }
      guard root.parent === worldAnchorEntity else { return }
      root.removeFromParent()
      container.addChild(root)
      let p = BlenderImmersiveState.shared.placementOffset
      root.position = SIMD3(p.x, p.y, -1.2 + p.z)
    }

    private func publish() {
      NotificationCenter.default.post(name: .blenderImmersiveSharedAnchorChanged, object: nil)
    }
  }

#endif
