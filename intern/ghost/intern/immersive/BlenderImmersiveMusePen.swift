/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Logitech Muse (spatial stylus) tracking for Immersive Space.
 *
 * Phase 1: tip cursor via GameController + RealityKit accessory anchors.
 * Phase 2 MVP: sample tip/pressure/pose and push Blender-space coords to C so
 * the main loop can project into View3D and drive sculpt strokes.
 */

import ARKit
import Foundation
import GameController
import RealityKit
import SwiftUI
import UIKit

#if os(visionOS)

  @_silgen_name("WM_IOS_immersive_muse_sample")
  private func WM_IOS_immersive_muse_sample(
    _ x: Float, _ y: Float, _ z: Float, _ pressure: Float, _ tipPressed: Int32)

  @_silgen_name("WM_IOS_immersive_muse_cycle_brush")
  private func WM_IOS_immersive_muse_cycle_brush()

  @_silgen_name("WM_IOS_immersive_muse_toggle_inflate_direction")
  private func WM_IOS_immersive_muse_toggle_inflate_direction()

  @_silgen_name("WM_IOS_immersive_muse_toggle_vpaint_erase")
  private func WM_IOS_immersive_muse_toggle_vpaint_erase()

  @MainActor
  final class BlenderImmersiveMusePenController: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var statusText = "Muse: 未接続"
    /** Live tip contact — used to choose light Immersive USD reloads mid-stroke. */
    @Published private(set) var isTipDown = false
    /** Live tip force 0–1 for ornament feedback. */
    @Published private(set) var tipPressure: Float = 0

    private var rootEntity: Entity?
    private var trackingSession: SpatialTrackingSession?
    private var arSession = ARKitSession()
    /** Set immediately when a session start begins — prevents concurrent run() races. */
    private var sessionLifecycle: SessionLifecycle = .idle
    private var stylusObservers: [NSObjectProtocol] = []
    private var cursorByStylus: [ObjectIdentifier: AnchorEntity] = [:]
    private var stylusByKey: [ObjectIdentifier: GCStylus] = [:]
    private var tipPressureByStylus: [ObjectIdentifier: Float] = [:]
    private var tipPressedByStylus: [ObjectIdentifier: Bool] = [:]
    private var primaryPressedByStylus: [ObjectIdentifier: Bool] = [:]
    private var secondaryPressedByStylus: [ObjectIdentifier: Bool] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?
    private var attachGeneration: UInt = 0
    private var lastLoggedTipDown = false

    private enum SessionLifecycle {
      case idle
      case starting
      case running
    }

    func attach(to root: Entity) {
      rootEntity = root
      attachGeneration &+= 1
      let generation = attachGeneration
      Task { await start(generation: generation) }
    }

    func detach() {
      attachGeneration &+= 1
      discoveryTask?.cancel()
      discoveryTask = nil
      sampleTask?.cancel()
      sampleTask = nil

      for observer in stylusObservers {
        NotificationCenter.default.removeObserver(observer)
      }
      stylusObservers.removeAll()
      for (_, anchor) in cursorByStylus {
        anchor.removeFromParent()
      }
      cursorByStylus.removeAll()
      stylusByKey.removeAll()
      tipPressureByStylus.removeAll()
      tipPressedByStylus.removeAll()
      primaryPressedByStylus.removeAll()
      secondaryPressedByStylus.removeAll()
      lastLoggedTipDown = false

      let session = trackingSession
      trackingSession = nil
      sessionLifecycle = .idle
      if let session {
        Task { await session.stop() }
      }

      /* Release any in-flight sculpt tip so Blender does not leave a stroke open. */
      WM_IOS_immersive_muse_sample(0, 0, 0, 0, 0)

      isConnected = false
      isTipDown = false
      tipPressure = 0
      statusText = "Muse: 未接続"
      rootEntity = nil
    }

    private func start(generation: UInt) async {
      guard rootEntity != nil, generation == attachGeneration else { return }

      observeStylusConnections()
      statusText = "Muse: 権限確認中…"
      let authorized = await requestTrackingAuthorization()
      guard generation == attachGeneration else { return }
      if !authorized {
        statusText = "Muse: 権限が拒否されました（設定で許可）"
        return
      }

      statusText = "Muse: 検索中…"
      await discoverExistingStyluses()
      guard generation == attachGeneration else { return }
      if !cursorByStylus.isEmpty {
        await startTrackingSessionOnce()
        return
      }

      discoveryTask?.cancel()
      discoveryTask = Task { @MainActor [weak self] in
        guard let self else { return }
        for attempt in 1...60 {
          guard !Task.isCancelled, generation == self.attachGeneration else { return }
          if !self.cursorByStylus.isEmpty {
            await self.startTrackingSessionOnce()
            return
          }
          try? await Task.sleep(nanoseconds: 500_000_000)
          guard generation == self.attachGeneration else { return }
          print("[immersive] Muse: rediscover attempt \(attempt)")
          await self.discoverExistingStyluses()
        }
        if self.cursorByStylus.isEmpty {
          self.statusText = "Muse: 未接続（ペアリング待ち）"
        }
      }
    }

    private func requestTrackingAuthorization() async -> Bool {
      let types: [ARKitSession.AuthorizationType] = [
        .accessoryTracking, .handTracking, .worldSensing,
      ]
      let current = await arSession.queryAuthorization(for: types)
      print("[immersive] Muse auth query: \(current)")
      let needRequest = types.filter { current[$0] != .allowed }
      if needRequest.isEmpty {
        return true
      }
      statusText = "Muse: 権限ダイアログ待ち…"
      let results = await arSession.requestAuthorization(for: needRequest)
      print("[immersive] Muse auth request: \(results)")
      let accessoryOK = results[.accessoryTracking] == .allowed
        || current[.accessoryTracking] == .allowed
      if !accessoryOK {
        print("[immersive] Muse: accessoryTracking not allowed")
      }
      return accessoryOK
    }

    /**
     * Start SpatialTrackingSession exactly once after a Muse AnchorEntity exists.
     * Concurrent callers must not call session.run() in parallel — that breaks
     * ARKit accessory providers ("provider is not running" / dual sessions).
     */
    private func startTrackingSessionOnce() async {
      guard sessionLifecycle == .idle else { return }
      guard !cursorByStylus.isEmpty else { return }

      sessionLifecycle = .starting
      let capabilities: Set<SpatialTrackingSession.Configuration.AnchorCapability> = [
        .world, .hand, .accessory,
      ]
      let configuration = SpatialTrackingSession.Configuration(tracking: capabilities)
      let session = SpatialTrackingSession()
      print("[immersive] Muse: starting SpatialTrackingSession…")
      if let unavailable = await session.run(configuration) {
        print("[immersive] Muse SpatialTrackingSession unavailable: \(unavailable)")
        if unavailable.anchor.contains(.accessory) {
          statusText = "Muse: トラッキング不可（権限を確認）"
          sessionLifecycle = .idle
          await session.stop()
          return
        }
      }

      trackingSession = session
      sessionLifecycle = .running
      print(
        "[immersive] Muse SpatialTrackingSession running caps=\(capabilities) anchors=\(cursorByStylus.count)"
      )
      refreshStatus()
      startPoseSampling()
    }

    private func discoverExistingStyluses() async {
      let styli = GCStylus.styli
      print("[immersive] Muse: GCStylus.styli count=\(styli.count)")
      for stylus in styli {
        await connectIfSpatial(stylus)
      }
      refreshStatus()
    }

    private func observeStylusConnections() {
      guard stylusObservers.isEmpty else { return }

      let connect = NotificationCenter.default.addObserver(
        forName: .GCStylusDidConnect, object: nil, queue: .main
      ) { [weak self] note in
        guard let stylus = note.object as? GCStylus else { return }
        Task { @MainActor in
          await self?.connectIfSpatial(stylus)
          await self?.startTrackingSessionOnce()
          self?.refreshStatus()
        }
      }
      let disconnect = NotificationCenter.default.addObserver(
        forName: .GCStylusDidDisconnect, object: nil, queue: .main
      ) { [weak self] note in
        guard let stylus = note.object as? GCStylus else { return }
        Task { @MainActor in
          self?.disconnect(stylus)
          self?.refreshStatus()
        }
      }
      stylusObservers = [connect, disconnect]
    }

    private func connectIfSpatial(_ stylus: GCStylus) async {
      let category = stylus.productCategory
      print(
        "[immersive] Muse candidate: vendor=\(stylus.vendorName ?? "?") category=\(category)"
      )
      guard category == GCProductCategorySpatialStylus else { return }
      let key = ObjectIdentifier(stylus)
      guard cursorByStylus[key] == nil else { return }
      guard let root = rootEntity else { return }

      do {
        let source = try await AnchoringComponent.AccessoryAnchoringSource(device: stylus)
        print(
          "[immersive] Muse locations: \(source.accessoryLocations.map { String(describing: $0) })"
        )
        let locationName =
          source.locationName(named: "aim")
          ?? source.accessoryLocations.first
        guard let locationName else {
          print("[immersive] Muse: no accessory locations on \(stylus.vendorName ?? "?")")
          return
        }

        let anchor = AnchorEntity(
          .accessory(from: source, location: locationName),
          trackingMode: .continuous,
          physicsSimulation: .none)
        anchor.name = "BlenderMuseCursor"
        anchor.addChild(makeCursorVisual())
        root.addChild(anchor)
        cursorByStylus[key] = anchor
        stylusByKey[key] = stylus
        tipPressureByStylus[key] = 0
        tipPressedByStylus[key] = false
        configureStylusInputs(stylus)
        print(
          "[immersive] Muse connected: \(stylus.vendorName ?? "stylus") @ \(String(describing: locationName))"
        )

        discoveryTask?.cancel()
        discoveryTask = nil
        await startTrackingSessionOnce()
      }
      catch {
        print("[immersive] Muse accessory setup failed: \(error)")
        statusText = "Muse: セットアップ失敗"
      }
    }

    private func configureStylusInputs(_ stylus: GCStylus) {
      guard let input = stylus.input else {
        print("[immersive] Muse: stylus.input is nil")
        BlenderIOSDiagnosticLog.bootSwiftOnly("muse: stylus.input is nil")
        return
      }
      let key = ObjectIdentifier(stylus)
      let tipBtn = input.buttons[.stylusTip] != nil
      let primBtn = input.buttons[.stylusPrimaryButton] != nil
      let secBtn = input.buttons[.stylusSecondaryButton] != nil
      let btnSummary = "tip=\(tipBtn) primary=\(primBtn) secondary=\(secBtn)"
      print("[immersive] Muse buttons: \(btnSummary)")
      BlenderIOSDiagnosticLog.bootSwiftOnly("muse buttons: \(btnSummary)")

      input.inputStateQueueDepth = 20
      /* Drain nextInputState() synchronously in the handler. Deferring the drain
       * to Task { @MainActor } can drop presses before they are applied. */
      input.inputStateAvailableHandler = { [weak self] input in
        var pressed = false
        var pressure: Float = 0
        var saw = false
        while let state = input.nextInputState() {
          saw = true
          let draw = Self.drawState(
            tip: state.buttons[.stylusTip],
            primary: state.buttons[.stylusPrimaryButton],
            secondary: state.buttons[.stylusSecondaryButton])
          pressed = draw.pressed
          pressure = draw.pressure
        }
        guard saw else { return }
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.tipPressureByStylus[key] = pressure
          self.tipPressedByStylus[key] = pressed
          self.logTipTransitionIfNeeded(pressed: pressed, pressure: pressure, source: "handler")
        }
      }
      print("[immersive] Muse: tip/primary/secondary handlers attached")
    }

    private func disconnect(_ stylus: GCStylus) {
      let key = ObjectIdentifier(stylus)
      if let anchor = cursorByStylus.removeValue(forKey: key) {
        anchor.removeFromParent()
      }
      stylusByKey.removeValue(forKey: key)
      tipPressureByStylus.removeValue(forKey: key)
      tipPressedByStylus.removeValue(forKey: key)
      if let input = stylus.input {
        input.inputStateAvailableHandler = nil
      }
    }

    private func refreshStatus() {
      isConnected = !cursorByStylus.isEmpty
      switch (isConnected, sessionLifecycle) {
      case (true, .running):
        let brush = BlenderImmersiveState.shared.handMenuBrushKind
        let brushName: String
        switch brush {
        case 4: brushName = "Inflate+"
        case 5: brushName = "Inflate−"
        case 3: brushName = "Smooth"
        case 2: brushName = "Grab"
        default: brushName = BlenderImmersiveState.shared.handMenuBrushLabel
        }
        if isTipDown {
          statusText = String(
            format: "Muse: %@  筆圧 %.0f%%", brushName, tipPressure * 100)
        }
        else {
          statusText = "Muse: \(brushName)  tip描画 / 前=切替 / 中=加減算"
        }
      case (true, .starting):
        statusText = "Muse: トラッキング開始中…"
      case (true, .idle):
        statusText = "Muse: アンカー作成済"
      case (false, _):
        statusText = "Muse: 未接続（ペアリング待ち）"
      }
    }

    /**
     * Push Muse aim pose + tip state to Blender at ~90 Hz.
     * Coordinates are converted from RealityKit world space into Blender
     * object space using the same axes as BlenderImmersiveObjectSync.
     */
    private func startPoseSampling() {
      sampleTask?.cancel()
      sampleTask = Task { @MainActor [weak self] in
        var ticks = 0
        while !Task.isCancelled {
          guard let self else { return }
          if let (key, anchor) = self.cursorByStylus.first {
            let blender: SIMD3<Float>
            if let root = self.rootEntity {
              let m = anchor.transformMatrix(relativeTo: root)
              let local = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
              /* Blender X = RK X, Blender Y = -RK Z, Blender Z = RK Y. */
              blender = SIMD3(local.x, -local.z, local.y)
            }
            else {
              let m = anchor.transformMatrix(relativeTo: nil)
              let world = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
              blender = self.realityKitWorldToBlender(world)
            }

            /* Prefer live button poll — handler cache alone was stuck at tip=0. */
            let live: (tip: Bool, tipPressure: Float, primary: Bool, secondary: Bool)
            if let stylus = self.stylusByKey[key] {
              live = Self.buttonState(fromStylus: stylus)
            }
            else {
              live = (
                self.tipPressedByStylus[key] ?? false,
                self.tipPressureByStylus[key] ?? 0,
                self.primaryPressedByStylus[key] ?? false,
                self.secondaryPressedByStylus[key] ?? false)
            }

            let wasPrimary = self.primaryPressedByStylus[key] ?? false
            let wasSecondary = self.secondaryPressedByStylus[key] ?? false
            /* Rising edges while tip is up: front cycles brush, middle toggles add/sub. */
            if !live.tip {
              if live.primary && !wasPrimary {
                WM_IOS_immersive_muse_cycle_brush()
                print("[immersive] Muse primary → cycle brush")
              }
              if live.secondary && !wasSecondary {
                if BlenderImmersiveState.shared.handMenuMode == 3 {
                  WM_IOS_immersive_muse_toggle_vpaint_erase()
                  print("[immersive] Muse secondary → toggle vpaint erase")
                }
                else {
                  WM_IOS_immersive_muse_toggle_inflate_direction()
                  print("[immersive] Muse secondary → toggle inflate add/sub")
                }
              }
            }

            self.tipPressedByStylus[key] = live.tip
            self.tipPressureByStylus[key] = live.tipPressure
            self.primaryPressedByStylus[key] = live.primary
            self.secondaryPressedByStylus[key] = live.secondary
            self.isTipDown = live.tip
            self.tipPressure = live.tipPressure
            self.logTipTransitionIfNeeded(
              pressed: live.tip, pressure: live.tipPressure, source: "poll")
            if ticks % 6 == 0 {
              self.refreshStatus()
            }

            let tipPressure = live.tip ? max(live.tipPressure, 0.05) : 0
            WM_IOS_immersive_muse_sample(
              blender.x, blender.y, blender.z, tipPressure, live.tip ? 1 : 0)

            if ticks % 30 == 0 {
              print(
                String(
                  format:
                    "[immersive] Muse sample tracked=%@ tip=%@ p=%.2f blender=(%.3f, %.3f, %.3f)",
                  anchor.isAnchored ? "yes" : "no",
                  live.tip ? "down" : "up",
                  tipPressure,
                  blender.x,
                  blender.y,
                  blender.z)
              )
            }
            ticks += 1
          }
          /* ~90 Hz pose/pressure for smoother Immersive sculpt strokes. */
          try? await Task.sleep(nanoseconds: 11_111_111)
        }
      }
    }

    private func logTipTransitionIfNeeded(pressed: Bool, pressure: Float, source: String) {
      guard pressed != lastLoggedTipDown else { return }
      lastLoggedTipDown = pressed
      let msg = String(
        format: "muse tip %@ (%@) p=%.2f", pressed ? "DOWN" : "UP", source, pressure)
      print("[immersive] \(msg)")
      BlenderIOSDiagnosticLog.bootSwiftOnly(msg)
    }

    /** Tip = sculpt. Front/middle buttons are used for brush switching, not draw. */
    private static func buttonState(fromStylus stylus: GCStylus) -> (
      tip: Bool, tipPressure: Float, primary: Bool, secondary: Bool
    ) {
      guard let buttons = stylus.input?.buttons else {
        return (false, 0, false, false)
      }
      let tip = buttons[.stylusTip]
      let primary = buttons[.stylusPrimaryButton]
      let secondary = buttons[.stylusSecondaryButton]
      let tipP = max(tip?.pressedInput.value ?? 0, tip?.forceInput?.value ?? 0)
      let primP = max(primary?.pressedInput.value ?? 0, primary?.forceInput?.value ?? 0)
      let secP = max(secondary?.pressedInput.value ?? 0, secondary?.forceInput?.value ?? 0)
      let tipDown = (tip?.pressedInput.isPressed ?? false) || tipP > 0.02
      let primDown = (primary?.pressedInput.isPressed ?? false) || primP > 0.35
      let secDown = (secondary?.pressedInput.isPressed ?? false) || secP > 0.02
      return (tipDown, tipDown ? max(tipP, 0.05) : tipP, primDown, secDown)
    }

    private static func drawState(fromStylus stylus: GCStylus) -> (pressed: Bool, pressure: Float)
    {
      let s = buttonState(fromStylus: stylus)
      return (s.tip, s.tipPressure)
    }

    private static func drawState(
      tip: (any GCButtonElement)?,
      primary: (any GCButtonElement)?,
      secondary: (any GCButtonElement)?
    ) -> (pressed: Bool, pressure: Float)
    {
      let tipP = max(tip?.pressedInput.value ?? 0, tip?.forceInput?.value ?? 0)
      let tipDown = (tip?.pressedInput.isPressed ?? false) || tipP > 0.02
      /* Primary/secondary no longer paint — tip only. */
      _ = primary
      _ = secondary
      return (tipDown, tipDown ? max(tipP, 0.05) : tipP)
    }

    private func realityKitWorldToBlender(_ world: SIMD3<Float>) -> SIMD3<Float> {
      /* Prefer converting into the shared immersive root (USD + Muse parent).
       * Falling back to placement subtraction keeps older sessions working. */
      let local: SIMD3<Float>
      if let root = rootEntity {
        local = root.convert(position: world, from: nil)
      }
      else {
        let placement = BlenderImmersiveState.shared.placementOffset
        let root = SIMD3(placement.x, placement.y, -1.2 + placement.z)
        local = world - root
      }
      /* Blender X = RK X, Blender Y = -RK Z, Blender Z = RK Y. */
      return SIMD3(local.x, -local.z, local.y)
    }

    private func makeCursorVisual() -> Entity {
      /* Large unlit tip so it stays obvious even if tracking is coarse. */
      let tip = ModelEntity(
        mesh: .generateSphere(radius: 0.04),
        materials: [
          UnlitMaterial(color: .systemPink)
        ])
      tip.name = "MuseTip"

      let rayLength: Float = 0.25
      let ray = ModelEntity(
        mesh: .generateBox(size: [0.008, 0.008, rayLength]),
        materials: [
          UnlitMaterial(color: .cyan)
        ])
      ray.name = "MuseAimRay"
      ray.position = SIMD3(0, 0, -rayLength / 2)

      let root = Entity()
      root.addChild(tip)
      root.addChild(ray)
      return root
    }
  }

#endif
