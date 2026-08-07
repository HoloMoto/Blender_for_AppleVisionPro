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

  @objc(updateObjectTransformsNames:count:xyz:)
  public static func updateObjectTransformsNames(
    _ names: [String]?, count: Int32, xyz: [NSNumber]?
  ) {
    #if os(visionOS)
      DispatchQueue.main.async {
        BlenderImmersiveState.shared.updateObjectTransforms(
          names: names, count: Int(count), xyz: xyz)
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

  @objc(updateBones:count:)
  public static func updateBones(_ packed: [NSNumber]?, count: Int32) {
    #if os(visionOS)
      DispatchQueue.main.async {
        BlenderImmersiveState.shared.updateBones(packed: packed, count: Int(count))
      }
    #endif
  }

  @objc(
    updateShaderGraphMaterial:nodePacked:nodeCount:nodeNames:typeNames:linkPacked:linkCount:sockTypes:sockCount:sockNames:
  )
  public static func updateShaderGraphMaterial(
    _ materialName: String?,
    nodePacked: [NSNumber]?,
    nodeCount: Int32,
    nodeNames: String?,
    typeNames: String?,
    linkPacked: [NSNumber]?,
    linkCount: Int32,
    sockTypes: [NSNumber]?,
    sockCount: Int32,
    sockNames: String?
  ) {
    #if os(visionOS)
      DispatchQueue.main.async {
        BlenderImmersiveState.shared.updateShaderGraph(
          materialName: materialName,
          nodePacked: nodePacked,
          nodeCount: Int(nodeCount),
          nodeNames: nodeNames,
          typeNames: typeNames,
          linkPacked: linkPacked,
          linkCount: Int(linkCount),
          sockTypes: sockTypes,
          sockCount: Int(sockCount),
          sockNames: sockNames)
      }
    #endif
  }

  @objc public static func setShaderSpaceEnabled(_ enable: Bool) {
    #if os(visionOS)
      DispatchQueue.main.async {
        BlenderImmersiveState.shared.applyShaderSpaceEnabled(enable)
      }
    #endif
  }

  @objc(updateShaderProps:typeIdname:propCount:propPacked:propNames:)
  public static func updateShaderProps(
    _ name: String?,
    typeIdname: String?,
    propCount: Int32,
    propPacked: [NSNumber]?,
    propNames: String?
  ) {
    #if os(visionOS)
      DispatchQueue.main.async {
        BlenderImmersiveState.shared.updateShaderProps(
          name: name,
          typeIdname: typeIdname,
          propCount: Int(propCount),
          propPacked: propPacked,
          propNames: propNames)
      }
    #endif
  }

  @objc(updateAnimTimelineFrame:frameStart:frameEnd:keyFrames:xformMode:targetMode:activeBone:)
  public static func updateAnimTimelineFrame(
    _ frame: Int32,
    frameStart: Int32,
    frameEnd: Int32,
    keyFrames: [NSNumber]?,
    xformMode: Int32,
    targetMode: Int32,
    activeBone: String?
  ) {
    #if os(visionOS)
      DispatchQueue.main.async {
        BlenderImmersiveState.shared.updateAnimTimeline(
          frame: Int(frame),
          frameStart: Int(frameStart),
          frameEnd: Int(frameEnd),
          keyFrames: keyFrames,
          xformMode: Int(xformMode),
          targetMode: Int(targetMode),
          activeBone: activeBone)
      }
    #endif
  }

  @objc public static func setUseHandAsPen(_ enable: Bool) {
    #if os(visionOS)
      DispatchQueue.main.async {
        BlenderImmersiveState.shared.applyUseHandAsPen(enable)
      }
    #endif
  }

  @objc public static func multiuserHost(_ displayName: String?) -> Bool {
    #if os(visionOS)
      return BlenderImmersiveMultiuserSession.shared.hostSession(displayName: displayName)
    #else
      return false
    #endif
  }

  @objc public static func multiuserJoin(_ displayName: String?) -> Bool {
    #if os(visionOS)
      return BlenderImmersiveMultiuserSession.shared.joinSession(displayName: displayName)
    #else
      return false
    #endif
  }

  @objc public static func multiuserLeave() {
    #if os(visionOS)
      BlenderImmersiveMultiuserSession.shared.leaveSession()
    #endif
  }

  @objc public static func multiuserIsActive() -> Bool {
    #if os(visionOS)
      return BlenderImmersiveMultiuserSession.shared.isActive
    #else
      return false
    #endif
  }

  @objc public static func multiuserIsHost() -> Bool {
    #if os(visionOS)
      return BlenderImmersiveMultiuserSession.shared.isHost
    #else
      return false
    #endif
  }

  @objc public static func multiuserStatus() -> String {
    #if os(visionOS)
      return BlenderImmersiveMultiuserSession.shared.statusCopy()
    #else
      return "Unavailable"
    #endif
  }

  @objc public static func multiuserBroadcastUSD(_ path: String?) {
    #if os(visionOS)
      guard let path, !path.isEmpty else { return }
      BlenderImmersiveMultiuserSession.shared.broadcastUSD(at: path)
    #endif
  }
}
