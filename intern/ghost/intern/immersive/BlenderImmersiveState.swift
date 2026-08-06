/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Shared identifiers / notifications for Vision Pro Immersive Space.
 */

import Foundation
import simd

public let BlenderImmersiveSpaceID = "blender.scene.immersive"
/** Independent visionOS window for the Immersive studio panel (not an ornament). */
public let BlenderStudioPanelWindowID = "blender.studio.panel"

public extension Notification.Name {
  static let blenderOpenImmersiveSpace = Notification.Name("blender.openImmersiveSpace")
  static let blenderDismissImmersiveSpace = Notification.Name("blender.dismissImmersiveSpace")
  static let blenderImmersiveModelPathChanged = Notification.Name(
    "blender.immersiveModelPathChanged")
  static let blenderImmersiveActiveObjectChanged = Notification.Name(
    "blender.immersiveActiveObjectChanged")
  static let blenderImmersiveHandMenuChanged = Notification.Name(
    "blender.immersiveHandMenuChanged")
  static let blenderImmersiveHandAsPenChanged = Notification.Name(
    "blender.immersiveHandAsPenChanged")
  static let blenderImmersiveHandProximityChanged = Notification.Name(
    "blender.immersiveHandProximityChanged")
  static let blenderImmersiveBonesChanged = Notification.Name("blender.immersiveBonesChanged")
  static let blenderImmersiveShaderGraphChanged = Notification.Name(
    "blender.immersiveShaderGraphChanged")
  static let blenderImmersiveSpatialBoardChanged = Notification.Name(
    "blender.immersiveSpatialBoardChanged")
  static let blenderImmersiveAnimTimelineChanged = Notification.Name(
    "blender.immersiveAnimTimelineChanged")
  static let blenderImmersivePlacementChanged = Notification.Name(
    "blender.immersivePlacementChanged")
  static let blenderImmersiveActiveChanged = Notification.Name(
    "blender.immersiveActiveChanged")
  /** Open / dismiss the independent Immersive studio WindowGroup (manual). */
  static let blenderOpenStudioPanel = Notification.Name("blender.openStudioPanel")
  static let blenderDismissStudioPanel = Notification.Name("blender.dismissStudioPanel")
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
  /** Immersive scene placement offset (meters). Used by Muse → Blender projection. */
  @objc public private(set) var placementX: Float = 0
  @objc public private(set) var placementY: Float = 0
  @objc public private(set) var placementZ: Float = 0

  /** 0 object / 1 edit / 2 sculpt */
  @objc public private(set) var handMenuMode: Int = 0
  @objc public private(set) var handMenuStrength: Float = 0.5
  @objc public private(set) var handMenuRadius: Float = 0.25
  /** 0 Draw / 1 Clay / 2 Grab / 3 Smooth / 4 Inflate+ / 5 Inflate− */
  @objc public private(set) var handMenuBrushKind: Int = 4
  @objc public private(set) var handMenuBrushLabel: String = "Inflate+"
  /** Immersive DynTopo (desktop Dynamic Topology) — default ON. */
  @objc public private(set) var handMenuDyntopo: Bool = true
  /** Right-hand pinch substitutes for Muse stylus. */
  @objc public private(set) var useHandAsPen: Bool = false
  /** Hand input trigger mode: true = proximity, false = pinch. */
  @objc public private(set) var handProximitySculpt: Bool = false

  /** Anim overlay: packed bones [hx,hy,hz,tx,ty,tz,selected] * N (Blender space). */
  @objc public private(set) var bonePacked: [Float] = []
  @objc public private(set) var boneCount: Int = 0

  /** Shader graph overlay: spatial Shading editor. */
  @objc public private(set) var shaderMaterialName: String = ""
  @objc public private(set) var shaderNodePacked: [Float] = []
  @objc public private(set) var shaderNodeCount: Int = 0
  @objc public private(set) var shaderNodeNames: [String] = []
  @objc public private(set) var shaderTypeNames: [String] = []
  @objc public private(set) var shaderLinkPacked: [Int] = []
  @objc public private(set) var shaderLinkCount: Int = 0
  @objc public private(set) var shaderSockTypes: [Int] = []
  @objc public private(set) var shaderSockNames: [String] = []
  @objc public private(set) var shaderSockCount: Int = 0
  @objc public private(set) var shaderSpaceEnabled: Bool = false
  /** Opt-in RealityKit node board (Mat ON alone does not spawn entities). */
  @objc public private(set) var spatialBoardWanted: Bool = false
  @objc public private(set) var shaderSelectedName: String = ""
  @objc public private(set) var shaderSelectedType: String = ""
  @objc public private(set) var shaderPropPacked: [Float] = []
  @objc public private(set) var shaderPropNames: [String] = []
  @objc public private(set) var shaderPropCount: Int = 0

  /** Anim timeline. */
  @objc public private(set) var animFrame: Int = 1
  @objc public private(set) var animFrameStart: Int = 1
  @objc public private(set) var animFrameEnd: Int = 250
  @objc public private(set) var animKeyFrames: [Int] = []
  /** 0 rotate / 1 move / 2 scale */
  @objc public private(set) var animPoseXformMode: Int = 0
  /** 0 bone / 1 object */
  @objc public private(set) var animTargetMode: Int = 0
  @objc public private(set) var animActiveBone: String = ""

  /**
   * Shared WorldAnchor controller while Immersive Space is open.
   * Viewport studio panel uses this for Host/Guest alignment buttons.
   */
  @MainActor weak var sharedAnchor: BlenderImmersiveSharedAnchorController?

  public var placementOffset: SIMD3<Float> {
    SIMD3(placementX, placementY, placementZ)
  }

  private override init() {
    super.init()
  }

  @objc public func updatePlacement(x: Float, y: Float, z: Float) {
    placementX = x
    placementY = y
    placementZ = z
  }

  @objc public func updateModelPath(_ path: String?) {
    modelPath = path
    modelRevision &+= 1
    NotificationCenter.default.post(
      name: .blenderImmersiveModelPathChanged, object: path)
  }

  @objc public func markActive(_ active: Bool) {
    if isActive == active { return }
    isActive = active
    NotificationCenter.default.post(name: .blenderImmersiveActiveChanged, object: nil)
  }

  @objc public func applyUseHandAsPen(_ enable: Bool) {
    useHandAsPen = enable
    NotificationCenter.default.post(name: .blenderImmersiveHandAsPenChanged, object: nil)
  }

  @objc public func updateActiveObject(_ name: String?, x: Float, y: Float, z: Float) {
    let next = name
    if activeObjectName == next && abs(activeObjectX - x) < 0.0001 && abs(activeObjectY - y) < 0.0001
      && abs(activeObjectZ - z) < 0.0001
    {
      return
    }
    activeObjectName = next
    activeObjectX = x
    activeObjectY = y
    activeObjectZ = z
    NotificationCenter.default.post(
      name: .blenderImmersiveActiveObjectChanged,
      object: nil,
      userInfo: ["name": name ?? "", "x": x, "y": y, "z": z])
  }

  @objc public func updateHandMenu(
    mode: Int, strength: Float, radius: Float, brushLabel: String?, brushKind: Int
  ) {
    let label = brushLabel ?? "Draw"
    let dyntopo = (brushKind & 0x100) != 0
    let proximity = (brushKind & 0x200) != 0
    let kind = brushKind & 0xFF
    /* Skip identical publishes — Studio/Hand re-renders were thrashing visionOS windows. */
    if handMenuMode == mode && abs(handMenuStrength - strength) < 0.0005
      && abs(handMenuRadius - radius) < 0.0005 && handMenuBrushLabel == label
      && handMenuBrushKind == kind && handMenuDyntopo == dyntopo
    {
      if handProximitySculpt != proximity {
        handProximitySculpt = proximity
        NotificationCenter.default.post(name: .blenderImmersiveHandProximityChanged, object: nil)
      }
      return
    }
    handMenuMode = mode
    handMenuStrength = strength
    handMenuRadius = radius
    handMenuBrushLabel = label
    handMenuDyntopo = dyntopo
    if handProximitySculpt != proximity {
      handProximitySculpt = proximity
      NotificationCenter.default.post(name: .blenderImmersiveHandProximityChanged, object: nil)
    }
    handMenuBrushKind = kind
    NotificationCenter.default.post(name: .blenderImmersiveHandMenuChanged, object: nil)
  }

  @objc public func updateBones(packed: [NSNumber]?, count: Int) {
    let n = max(0, count)
    let next: [Float]
    if let packed, n > 0 {
      next = packed.prefix(n * 7).map { $0.floatValue }
    }
    else {
      next = []
    }
    if boneCount == n && bonePacked == next {
      return
    }
    boneCount = n
    bonePacked = next
    NotificationCenter.default.post(name: .blenderImmersiveBonesChanged, object: nil)
  }

  @objc public func updateShaderGraph(
    materialName: String?,
    nodePacked: [NSNumber]?,
    nodeCount: Int,
    nodeNames: String?,
    typeNames: String?,
    linkPacked: [NSNumber]?,
    linkCount: Int,
    sockTypes: [NSNumber]?,
    sockCount: Int,
    sockNames: String?
  ) {
    let mat = materialName ?? ""
    let names = (nodeNames ?? "").split(separator: "|", omittingEmptySubsequences: false).map(
      String.init)
    let types = (typeNames ?? "").split(separator: "|", omittingEmptySubsequences: false).map(
      String.init)
    let socks = (sockNames ?? "").split(separator: "|", omittingEmptySubsequences: false).map(
      String.init)
    let nCount = max(0, nodeCount)
    let lCount = max(0, linkCount)
    let sCount = max(0, sockCount)
    let nodes: [Float] = (nodePacked ?? []).prefix(nCount * 6).map { $0.floatValue }
    let links: [Int] = (linkPacked ?? []).prefix(lCount * 4).map { $0.intValue }
    let stypes: [Int] = (sockTypes ?? []).prefix(sCount).map { $0.intValue }
    if shaderMaterialName == mat && shaderNodeCount == nCount && shaderLinkCount == lCount
      && shaderSockCount == sCount && shaderNodePacked == nodes && shaderLinkPacked == links
      && shaderSockTypes == stypes && shaderNodeNames == names && shaderTypeNames == types
      && shaderSockNames == socks
    {
      return
    }
    shaderMaterialName = mat
    shaderNodeCount = nCount
    shaderNodePacked = nodes
    shaderNodeNames = names
    shaderTypeNames = types
    shaderLinkCount = lCount
    shaderLinkPacked = links
    shaderSockCount = sCount
    shaderSockTypes = stypes
    shaderSockNames = socks
    NotificationCenter.default.post(name: .blenderImmersiveShaderGraphChanged, object: nil)
  }

  @objc public func applyShaderSpaceEnabled(_ enabled: Bool) {
    if shaderSpaceEnabled == enabled {
      /* Still clear selection on re-enable attempts so Hand Menu never rebuilds
       * stale Slider rows on Mat press. */
      if enabled {
        shaderSelectedName = ""
        shaderSelectedType = ""
        shaderPropCount = 0
        shaderPropPacked = []
        shaderPropNames = []
      }
      return
    }
    shaderSpaceEnabled = enabled
    /* Always clear prop editors on Mat toggle — stale NaN ranges crash visionOS. */
    shaderSelectedName = ""
    shaderSelectedType = ""
    shaderPropCount = 0
    shaderPropPacked = []
    shaderPropNames = []
    if !enabled {
      spatialBoardWanted = false
      shaderMaterialName = ""
      shaderNodeCount = 0
      shaderNodePacked = []
      shaderNodeNames = []
      shaderTypeNames = []
      shaderLinkCount = 0
      shaderLinkPacked = []
      shaderSockCount = 0
      shaderSockTypes = []
      shaderSockNames = []
      NotificationCenter.default.post(name: .blenderImmersiveSpatialBoardChanged, object: nil)
    }
    NotificationCenter.default.post(name: .blenderImmersiveShaderGraphChanged, object: nil)
  }

  @objc public func applySpatialBoardWanted(_ wanted: Bool) {
    let next = wanted && shaderSpaceEnabled
    if spatialBoardWanted == next { return }
    spatialBoardWanted = next
    NotificationCenter.default.post(name: .blenderImmersiveSpatialBoardChanged, object: nil)
    NotificationCenter.default.post(name: .blenderImmersiveShaderGraphChanged, object: nil)
  }

  @objc public func updateShaderProps(
    name: String?,
    typeIdname: String?,
    propCount: Int,
    propPacked: [NSNumber]?,
    propNames: String?
  ) {
    let n = name ?? ""
    let tid = typeIdname ?? ""
    let pnames = (propNames ?? "").split(separator: "|", omittingEmptySubsequences: false).map(
      String.init)
    let pCount = max(0, propCount)
    let props: [Float] = (propPacked ?? []).prefix(pCount * 8).map { $0.floatValue }
    if shaderSelectedName == n && shaderSelectedType == tid && shaderPropCount == pCount
      && shaderPropPacked == props && shaderPropNames == pnames
    {
      return
    }
    shaderSelectedName = n
    shaderSelectedType = tid
    shaderPropCount = pCount
    shaderPropPacked = props
    shaderPropNames = pnames
    NotificationCenter.default.post(name: .blenderImmersiveShaderGraphChanged, object: nil)
  }

  @objc public func updateAnimTimeline(
    frame: Int,
    frameStart: Int,
    frameEnd: Int,
    keyFrames: [NSNumber]?,
    xformMode: Int,
    targetMode: Int,
    activeBone: String?
  ) {
    let keys = (keyFrames ?? []).map { $0.intValue }
    let end = max(frameEnd, frameStart)
    let bone = activeBone ?? ""
    /* Skip identical publishes — Hand UI re-renders steal pinch presses. */
    if animFrame == frame && animFrameStart == frameStart && animFrameEnd == end &&
      animKeyFrames == keys && animPoseXformMode == xformMode && animTargetMode == targetMode &&
      animActiveBone == bone
    {
      return
    }
    animFrame = frame
    animFrameStart = frameStart
    animFrameEnd = end
    animKeyFrames = keys
    animPoseXformMode = xformMode
    animTargetMode = targetMode
    animActiveBone = bone
    NotificationCenter.default.post(name: .blenderImmersiveAnimTimelineChanged, object: nil)
  }
}
