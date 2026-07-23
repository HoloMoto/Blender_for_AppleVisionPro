/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Local-network Immersive session sharing for multiple Vision Pros.
 *
 * Inspired by Blender Multiuser (client/server collaborative session), but scoped
 * to Immersive experience sharing:
 *   - Host advertises a Multipeer session and broadcasts USDZ scene snapshots
 *   - Guests browse/join and load the shared USD into Immersive Space
 *   - All peers exchange Muse tip presence for shared cursors
 *
 * When no session is active, the existing single-user Immersive path is unchanged.
 */

import Foundation
import MultipeerConnectivity
import simd
#if canImport(UIKit)
  import UIKit
#endif

public extension Notification.Name {
  static let blenderImmersiveMultiuserChanged = Notification.Name(
    "blender.immersiveMultiuserChanged")
  static let blenderImmersiveRemotePresenceChanged = Notification.Name(
    "blender.immersiveRemotePresenceChanged")
  static let blenderImmersiveRemoteUSDReceived = Notification.Name(
    "blender.immersiveRemoteUSDReceived")
}

@objc public final class BlenderImmersiveRemotePresence: NSObject {
  @objc public let peerId: String
  @objc public let displayName: String
  @objc public var x: Float
  @objc public var y: Float
  @objc public var z: Float
  @objc public var tipDown: Bool
  @objc public var colorR: Float
  @objc public var colorG: Float
  @objc public var colorB: Float

  init(
    peerId: String,
    displayName: String,
    x: Float,
    y: Float,
    z: Float,
    tipDown: Bool,
    colorR: Float,
    colorG: Float,
    colorB: Float
  ) {
    self.peerId = peerId
    self.displayName = displayName
    self.x = x
    self.y = y
    self.z = z
    self.tipDown = tipDown
    self.colorR = colorR
    self.colorG = colorG
    self.colorB = colorB
  }
}

@objc(BlenderImmersiveMultiuserSession)
public final class BlenderImmersiveMultiuserSession: NSObject {
  @objc public static let shared = BlenderImmersiveMultiuserSession()

  private static let serviceType = "blender-imu"
  private static let protocolVersion = 1

  private let syncQueue = DispatchQueue(label: "blender.immersive.multiuser")
  private var peerId: MCPeerID!
  private var session: MCSession?
  private var advertiser: MCNearbyServiceAdvertiser?
  private var browser: MCNearbyServiceBrowser?

  @objc public private(set) var isActive = false
  @objc public private(set) var isHost = false
  @objc public private(set) var displayName = "VisionPro"
  @objc public private(set) var statusText = "Idle"
  @objc public private(set) var peerCount: Int = 0
  @objc public private(set) var localPeerUUID = UUID().uuidString

  private var colorSeed: SIMD3<Float> = SIMD3(0.2, 0.7, 1.0)
  private var remotePresence: [String: BlenderImmersiveRemotePresence] = [:]
  private var lastPresenceSend: TimeInterval = 0

  private override init() {
    super.init()
    #if os(visionOS) || os(iOS)
      let device = UIDevice.current.name
      displayName = String(device.prefix(20))
      peerId = MCPeerID(displayName: displayName)
      colorSeed = Self.color(for: localPeerUUID)
    #endif
  }

  @objc public func hostSession(displayName name: String?) -> Bool {
    #if os(visionOS)
      syncQueue.sync {
        tearDownLocked()
        if let name, !name.isEmpty {
          displayName = String(name.prefix(20))
          peerId = MCPeerID(displayName: displayName)
        }
        isHost = true
        isActive = true
        statusText = "Hosting…"
        startSessionLocked()
        advertiser = MCNearbyServiceAdvertiser(
          peer: peerId,
          discoveryInfo: [
            "role": "host",
            "uid": localPeerUUID,
            "v": "\(Self.protocolVersion)",
          ],
          serviceType: Self.serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        publishChanged()
      }
      return true
    #else
      return false
    #endif
  }

  @objc public func joinSession(displayName name: String?) -> Bool {
    #if os(visionOS)
      syncQueue.sync {
        tearDownLocked()
        if let name, !name.isEmpty {
          displayName = String(name.prefix(20))
          peerId = MCPeerID(displayName: displayName)
        }
        isHost = false
        isActive = true
        statusText = "Looking for host…"
        startSessionLocked()
        browser = MCNearbyServiceBrowser(peer: peerId, serviceType: Self.serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        publishChanged()
      }
      return true
    #else
      return false
    #endif
  }

  @objc public func leaveSession() {
    #if os(visionOS)
      syncQueue.sync {
        tearDownLocked()
        statusText = "Idle"
        publishChanged()
      }
    #endif
  }

  @objc public func statusCopy() -> String {
    syncQueue.sync { statusText }
  }

  @objc public func remotePresenceSnapshot() -> [BlenderImmersiveRemotePresence] {
    syncQueue.sync { Array(remotePresence.values) }
  }

  /** Host only: broadcast a USDZ snapshot to connected guests. No-op if inactive/guest. */
  @objc public func broadcastUSD(at path: String) {
    #if os(visionOS)
      syncQueue.async { [weak self] in
        guard let self, self.isActive, self.isHost else { return }
        guard let session = self.session else { return }
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        for peer in peers {
          session.sendResource(at: url, withName: "immersive_share.usdz", toPeer: peer) {
            error in
            if let error {
              print("[multiuser] USD send failed: \(error.localizedDescription)")
            }
            else {
              print("[multiuser] USD sent to \(peer.displayName)")
            }
          }
        }
      }
    #endif
  }

  /** Send local Muse tip presence (~10 Hz). Safe no-op when session inactive. */
  @objc public func sendLocalPresence(x: Float, y: Float, z: Float, tipDown: Bool) {
    #if os(visionOS)
      let now = Date().timeIntervalSinceReferenceDate
      syncQueue.async { [weak self] in
        guard let self, self.isActive, let session = self.session else { return }
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        if now - self.lastPresenceSend < 0.1 {
          return
        }
        self.lastPresenceSend = now
        let payload: [String: Any] = [
          "v": Self.protocolVersion,
          "t": "presence",
          "uid": self.localPeerUUID,
          "name": self.displayName,
          "x": x,
          "y": y,
          "z": z,
          "tip": tipDown ? 1 : 0,
          "col": [self.colorSeed.x, self.colorSeed.y, self.colorSeed.z],
        ]
        self.sendJSON(payload, to: peers, reliable: false)
      }
    #endif
  }

  private func startSessionLocked() {
    session = MCSession(peer: peerId, securityIdentity: nil, encryptionPreference: .required)
    session?.delegate = self
    remotePresence.removeAll()
    peerCount = 0
  }

  private func tearDownLocked() {
    advertiser?.stopAdvertisingPeer()
    advertiser?.delegate = nil
    advertiser = nil
    browser?.stopBrowsingForPeers()
    browser?.delegate = nil
    browser = nil
    session?.disconnect()
    session?.delegate = nil
    session = nil
    isActive = false
    isHost = false
    peerCount = 0
    remotePresence.removeAll()
    NotificationCenter.default.post(name: .blenderImmersiveRemotePresenceChanged, object: nil)
  }

  private func publishChanged() {
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .blenderImmersiveMultiuserChanged, object: nil)
    }
  }

  private func sendJSON(_ payload: [String: Any], to peers: [MCPeerID], reliable: Bool) {
    guard let session, !peers.isEmpty,
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
    else {
      return
    }
    try? session.send(
      data, toPeers: peers, with: reliable ? .reliable : .unreliable)
  }

  private func handleJSONData(_ data: Data, from peer: MCPeerID) {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = obj["t"] as? String
    else {
      return
    }
    switch type {
    case "hello":
      let name = (obj["name"] as? String) ?? peer.displayName
      statusText = isHost ? "Hosting (\(peerCount) peer)" : "Joined \(name)"
      publishChanged()
    case "presence":
      let uid = (obj["uid"] as? String) ?? peer.displayName
      if uid == localPeerUUID {
        return
      }
      let name = (obj["name"] as? String) ?? peer.displayName
      let x = floatValue(obj["x"])
      let y = floatValue(obj["y"])
      let z = floatValue(obj["z"])
      let tip = intValue(obj["tip"]) != 0
      var r: Float = 1
      var g: Float = 0.4
      var b: Float = 0.2
      if let col = obj["col"] as? [Any], col.count >= 3 {
        r = floatValue(col[0])
        g = floatValue(col[1])
        b = floatValue(col[2])
      }
      let presence = BlenderImmersiveRemotePresence(
        peerId: uid,
        displayName: name,
        x: x,
        y: y,
        z: z,
        tipDown: tip,
        colorR: r,
        colorG: g,
        colorB: b)
      remotePresence[uid] = presence
      DispatchQueue.main.async {
        NotificationCenter.default.post(
          name: .blenderImmersiveRemotePresenceChanged, object: nil)
      }
    default:
      break
    }
  }

  private func announceHello(to peers: [MCPeerID]) {
    let payload: [String: Any] = [
      "v": Self.protocolVersion,
      "t": "hello",
      "uid": localPeerUUID,
      "name": displayName,
      "role": isHost ? "host" : "guest",
    ]
    sendJSON(payload, to: peers, reliable: true)
  }

  private static func color(for seed: String) -> SIMD3<Float> {
    var hash: UInt64 = 5381
    for byte in seed.utf8 {
      hash = ((hash << 5) &+ hash) &+ UInt64(byte)
    }
    let r = Float((hash >> 0) & 255) / 255.0
    let g = Float((hash >> 8) & 255) / 255.0
    let b = Float((hash >> 16) & 255) / 255.0
    return SIMD3(0.35 + 0.65 * r, 0.35 + 0.65 * g, 0.35 + 0.65 * b)
  }

  private func floatValue(_ any: Any?) -> Float {
    if let n = any as? NSNumber {
      return n.floatValue
    }
    if let d = any as? Double {
      return Float(d)
    }
    if let f = any as? Float {
      return f
    }
    return 0
  }

  private func intValue(_ any: Any?) -> Int {
    if let n = any as? NSNumber {
      return n.intValue
    }
    if let i = any as? Int {
      return i
    }
    return 0
  }
}

#if os(visionOS)

  extension BlenderImmersiveMultiuserSession: MCSessionDelegate {
    public func session(
      _ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState
    ) {
      syncQueue.async { [weak self] in
        guard let self else { return }
        self.peerCount = session.connectedPeers.count
        switch state {
        case .connected:
          self.statusText =
            self.isHost
            ? "Hosting (\(self.peerCount) peer)" : "Connected to \(peerID.displayName)"
          self.announceHello(to: [peerID])
          /* Guest asks nothing; host will push USD on next Immersive refresh. */
        case .connecting:
          self.statusText = "Connecting to \(peerID.displayName)…"
        case .notConnected:
          self.statusText =
            self.isHost
            ? (self.isActive ? "Hosting (\(self.peerCount) peer)" : "Idle")
            : (self.isActive ? "Looking for host…" : "Idle")
          self.remotePresence = self.remotePresence.filter {
            !$0.key.contains(peerID.displayName)
          }
          NotificationCenter.default.post(
            name: .blenderImmersiveRemotePresenceChanged, object: nil)
        @unknown default:
          break
        }
        self.publishChanged()
      }
    }

    public func session(
      _ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID
    ) {
      syncQueue.async { [weak self] in
        self?.handleJSONData(data, from: peerID)
      }
    }

    public func session(
      _ session: MCSession,
      didReceive stream: InputStream,
      withName streamName: String,
      fromPeer peerID: MCPeerID
    ) {}

    public func session(
      _ session: MCSession,
      didStartReceivingResourceWithName resourceName: String,
      fromPeer peerID: MCPeerID,
      with progress: Progress
    ) {
      print("[multiuser] receiving \(resourceName) from \(peerID.displayName)")
    }

    public func session(
      _ session: MCSession,
      didFinishReceivingResourceWithName resourceName: String,
      fromPeer peerID: MCPeerID,
      at localURL: URL?,
      withError error: (any Error)?
    ) {
      if let error {
        print("[multiuser] resource error: \(error.localizedDescription)")
        return
      }
      guard let localURL else { return }
      /* Copy into session temp so Immersive reload can own the path. */
      let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent("immersive_remote_\(UUID().uuidString).usdz")
      do {
        if FileManager.default.fileExists(atPath: dest.path) {
          try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: localURL, to: dest)
        DispatchQueue.main.async {
          /* Guests apply shared USD; host ignores remote scene (host-authoritative). */
          if !BlenderImmersiveMultiuserSession.shared.isHost {
            BlenderImmersiveState.shared.updateModelPath(dest.path)
            NotificationCenter.default.post(
              name: .blenderImmersiveRemoteUSDReceived, object: dest.path)
          }
        }
      }
      catch {
        print("[multiuser] copy failed: \(error.localizedDescription)")
      }
    }

    public func session(
      _ session: MCSession,
      didReceiveCertificate certificate: [Any]?,
      fromPeer peerID: MCPeerID,
      certificateHandler: @escaping (Bool) -> Void
    ) {
      certificateHandler(true)
    }
  }

  extension BlenderImmersiveMultiuserSession: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(
      _ advertiser: MCNearbyServiceAdvertiser,
      didReceiveInvitationFromPeer peerID: MCPeerID,
      withContext context: Data?,
      invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
      invitationHandler(true, session)
    }

    public func advertiser(
      _ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error
    ) {
      syncQueue.async { [weak self] in
        self?.statusText = "Host failed: \(error.localizedDescription)"
        self?.publishChanged()
      }
    }
  }

  extension BlenderImmersiveMultiuserSession: MCNearbyServiceBrowserDelegate {
    public func browser(
      _ browser: MCNearbyServiceBrowser,
      foundPeer peerID: MCPeerID,
      withDiscoveryInfo info: [String: String]?
    ) {
      /* Prefer peers advertising as host. */
      if let role = info?["role"], role != "host" {
        return
      }
      guard let session else { return }
      browser.invitePeer(peerID, to: session, withContext: nil, timeout: 12)
      syncQueue.async { [weak self] in
        self?.statusText = "Inviting \(peerID.displayName)…"
        self?.publishChanged()
      }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    public func browser(
      _ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error
    ) {
      syncQueue.async { [weak self] in
        self?.statusText = "Join failed: \(error.localizedDescription)"
        self?.publishChanged()
      }
    }
  }

#endif
