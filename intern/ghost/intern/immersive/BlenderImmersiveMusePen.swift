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

  @MainActor
  final class BlenderImmersiveMusePenController: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var statusText = "Muse: 未接続"
    /** Live tip contact — used to choose light Immersive USD reloads mid-stroke. */
    @Published private(set) var isTipDown = false
    /** Live tip force 0–1 for ornament feedback. */
    @Published private(set) var tipPressure: Float = 0

    private var rootEntity: Entity?
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
    private var primaryPressureByStylus: [ObjectIdentifier: Float] = [:]
    private var secondaryPressureByStylus: [ObjectIdentifier: Float] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?
    private var attachGeneration: UInt = 0
    private var lastLoggedTipDown = false
    /** Counts inputStateAvailableHandler wakes (diagnostics). */
    private var handlerWakeCount = 0
    private var queuedStateCount = 0

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
      primaryPressureByStylus.removeAll()
      secondaryPressureByStylus.removeAll()
      lastLoggedTipDown = false
      handlerWakeCount = 0
      queuedStateCount = 0

      sessionLifecycle = .idle

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
     * Uses the shared Immersive session so HandPen can also enable .hand without
     * racing a second SpatialTrackingSession.run().
     */
    private func startTrackingSessionOnce() async {
      guard sessionLifecycle == .idle else { return }
      guard !cursorByStylus.isEmpty else { return }

      sessionLifecycle = .starting
      let capabilities: Set<SpatialTrackingSession.Configuration.AnchorCapability> = [
        .world, .hand, .accessory,
      ]
      print("[immersive] Muse: ensuring SpatialTrackingSession…")
      let ok = await BlenderImmersiveSpatialTracking.ensure(capabilities: capabilities)
      if !ok {
        statusText = "Muse: トラッキング不可（権限を確認）"
        sessionLifecycle = .idle
        return
      }

      sessionLifecycle = .running
      print(
        "[immersive] Muse SpatialTrackingSession ready anchors=\(cursorByStylus.count)"
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
      BlenderIOSDiagnosticLog.bootSwiftOnly(
        "muse: drain nextInputState each frame (Apple Drawing). Mid=air pressure.")

      /* Default queue depth is 1 — buffer between ~90 Hz pose samples. */
      input.inputStateQueueDepth = 30
      /*
       * Apple "Handling input events": optionally wake when states arrive; drain
       * nextInputState() in the game/pose loop (see Drawing with a spatial stylus).
       * Live-polling input.buttons stays at 0 on device — do not use that path.
       */
      input.inputStateAvailableHandler = { [weak self] input in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.handlerWakeCount += 1
          _ = self.drainAndApplyStylusInput(input, key: key, source: "handler")
        }
      }
      input.elementValueDidChangeHandler = { [weak self] input, _ in
        Task { @MainActor [weak self] in
          guard let self else { return }
          /* Snapshot current physical values when an element changes. */
          self.applyStylusSnapshot(Self.readStylusButtons(from: input), key: key, source: "element")
        }
      }
      print("[immersive] Muse: nextInputState drain + element handler attached")
      BlenderIOSDiagnosticLog.bootSwiftOnly("muse: nextInputState + element handlers ready")
    }

    /** Apple Drawing sample: pressure = max(tip, primary, secondary). */
    private struct StylusButtonRead {
      var tipDown = false
      var tipP: Float = 0
      var primDown = false
      var primP: Float = 0
      var secDown = false
      var secP: Float = 0

      var drawDown: Bool { tipDown || primDown || secDown }
      var drawPressure: Float { max(tipP, primP, secP) }
    }

    private static func readStylusButtons(from input: any GCDevicePhysicalInput) -> StylusButtonRead {
      var r = StylusButtonRead()
      let tip = input.buttons[.stylusTip]
      let prim = input.buttons[.stylusPrimaryButton]
      let sec = input.buttons[.stylusSecondaryButton]
      r.tipP = max(tip?.pressedInput.value ?? 0, tip?.forceInput?.value ?? 0)
      r.primP = max(prim?.pressedInput.value ?? 0, prim?.forceInput?.value ?? 0)
      r.secP = max(sec?.pressedInput.value ?? 0, sec?.forceInput?.value ?? 0)
      r.tipDown = (tip?.pressedInput.isPressed ?? false) || r.tipP > 0.001
      r.primDown = (prim?.pressedInput.isPressed ?? false) || r.primP > 0.02
      r.secDown = (sec?.pressedInput.isPressed ?? false) || r.secP > 0.02
      return r
    }

    private static func readStylusButtons(fromState state: any GCDevicePhysicalInputState)
      -> StylusButtonRead
    {
      var r = StylusButtonRead()
      let tip = state.buttons[.stylusTip]
      let prim = state.buttons[.stylusPrimaryButton]
      let sec = state.buttons[.stylusSecondaryButton]
      r.tipP = max(tip?.pressedInput.value ?? 0, tip?.forceInput?.value ?? 0)
      r.primP = max(prim?.pressedInput.value ?? 0, prim?.forceInput?.value ?? 0)
      r.secP = max(sec?.pressedInput.value ?? 0, sec?.forceInput?.value ?? 0)
      r.tipDown = (tip?.pressedInput.isPressed ?? false) || r.tipP > 0.001
      r.primDown = (prim?.pressedInput.isPressed ?? false) || r.primP > 0.02
      r.secDown = (sec?.pressedInput.isPressed ?? false) || r.secP > 0.02
      return r
    }

    @discardableResult
    private func drainAndApplyStylusInput(
      _ input: any GCDevicePhysicalInput, key: ObjectIdentifier, source: String
    ) -> Bool {
      var last: StylusButtonRead?
      var events = 0
      while let state = input.nextInputState() {
        events += 1
        last = Self.readStylusButtons(fromState: state)
      }
      guard let read = last else { return false }
      queuedStateCount += events
      applyStylusSnapshot(read, key: key, source: "\(source):\(events)")
      return true
    }

    private func applyStylusSnapshot(_ read: StylusButtonRead, key: ObjectIdentifier, source: String)
    {
      tipPressedByStylus[key] = read.tipDown
      tipPressureByStylus[key] = read.tipP
      primaryPressedByStylus[key] = read.primDown
      primaryPressureByStylus[key] = read.primP
      secondaryPressedByStylus[key] = read.secDown
      secondaryPressureByStylus[key] = read.secP

      let drawDown = read.drawDown
      /* Prefer secondary for air drawing (Apple), then tip, then primary. */
      let pressure: Float = {
        if read.secP > 0.001 { return read.secP }
        if read.tipP > 0.001 { return read.tipP }
        if read.primDown { return max(read.primP, 0.75) }
        return read.drawPressure
      }()
      let outP: Float = drawDown ? max(pressure, 0.15) : 0
      let changed = drawDown != isTipDown || abs(outP - tipPressure) > 0.04
      isTipDown = drawDown
      tipPressure = outP
      logTipTransitionIfNeeded(pressed: drawDown, pressure: tipPressure, source: source)

      if changed || source.hasPrefix("handler") || source.hasPrefix("element") {
        let msg = String(
          format: "muse \(source) t=%d/%.3f p=%d/%.3f s=%d/%.3f draw=%d outP=%.2f",
          read.tipDown ? 1 : 0,
          read.tipP,
          read.primDown ? 1 : 0,
          read.primP,
          read.secDown ? 1 : 0,
          read.secP,
          drawDown ? 1 : 0,
          tipPressure)
        print("[immersive] \(msg)")
        BlenderIOSDiagnosticLog.bootSwiftOnly(msg)
        refreshStatus()
      }
    }

    private func disconnect(_ stylus: GCStylus) {
      let key = ObjectIdentifier(stylus)
      if let anchor = cursorByStylus.removeValue(forKey: key) {
        anchor.removeFromParent()
      }
      stylusByKey.removeValue(forKey: key)
      tipPressureByStylus.removeValue(forKey: key)
      tipPressedByStylus.removeValue(forKey: key)
      primaryPressedByStylus.removeValue(forKey: key)
      secondaryPressedByStylus.removeValue(forKey: key)
      primaryPressureByStylus.removeValue(forKey: key)
      secondaryPressureByStylus.removeValue(forKey: key)
      if let input = stylus.input {
        input.inputStateAvailableHandler = nil
        input.elementValueDidChangeHandler = nil
      }
    }

    private func refreshStatus() {
      isConnected = !cursorByStylus.isEmpty
      /* Object Mode = Immersive view-only (no tip strokes). */
      if BlenderImmersiveState.shared.handMenuMode == 0 {
        statusText = isConnected ? "Muse: 閲覧専用（Obj）" : "Muse: 未接続（閲覧専用）"
        return
      }
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
            format: "Muse: %@  描画中 筆圧 %.0f%%", brushName, tipPressure * 100)
        }
        else {
          statusText = "Muse: \(brushName)  中ボタン押し=筆圧描画 / 球が赤く膨らむ"
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
              blender = BlenderImmersiveCoords.realityKitToBlender(local)
            }
            else {
              let m = anchor.transformMatrix(relativeTo: nil)
              let world = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
              blender = self.realityKitWorldToBlender(world)
            }

            /*
             * Drain nextInputState every pose tick (Apple Drawing sample).
             * Do NOT live-poll input.buttons — those stay 0 on device.
             */
            if let stylus = self.stylusByKey[key], let input = stylus.input {
              if !self.drainAndApplyStylusInput(input, key: key, source: "tick") {
                /* Sync release / sticky values via capture when queue was empty. */
                if ticks % 3 == 0 {
                  self.applyStylusSnapshot(
                    Self.readStylusButtons(fromState: input.capture()), key: key, source: "capture")
                }
              }
            }

            let tipSensor = self.tipPressedByStylus[key] ?? false
            let tipSensorP = self.tipPressureByStylus[key] ?? 0
            let primary = self.primaryPressedByStylus[key] ?? false
            let primP = self.primaryPressureByStylus[key] ?? 0
            let secondary = self.secondaryPressedByStylus[key] ?? false
            let secP = self.secondaryPressureByStylus[key] ?? 0
            /* Object Mode is view-only — ignore tip / middle-button draw. */
            let viewOnly = BlenderImmersiveState.shared.handMenuMode == 0
            let drawDown = viewOnly ? false : self.isTipDown
            let drawPressure = viewOnly ? Float(0) : self.tipPressure

            self.updateTipVisual(on: anchor, tipDown: drawDown, rawPressure: drawPressure)
            if ticks % 6 == 0 {
              self.refreshStatus()
            }
            if ticks % 45 == 0 {
              let msg = String(
                format:
                  "muse raw t=%d/%.3f p=%d/%.3f s=%d/%.3f draw=%d outP=%.2f wake=%d q=%d",
                tipSensor ? 1 : 0,
                tipSensorP,
                primary ? 1 : 0,
                primP,
                secondary ? 1 : 0,
                secP,
                drawDown ? 1 : 0,
                drawPressure,
                self.handlerWakeCount,
                self.queuedStateCount)
              print("[immersive] \(msg)")
              BlenderIOSDiagnosticLog.bootSwiftOnly(msg)
            }

            let tipPressure = drawDown ? max(drawPressure, 0.15) : 0
            /* When hand-as-pen is on, HandPen owns the muse_sample pipe. */
            if !BlenderImmersiveState.shared.useHandAsPen {
              WM_IOS_immersive_muse_sample(
                blender.x, blender.y, blender.z, tipPressure, drawDown ? 1 : 0)
              if BlenderImmersiveMultiuserSession.shared.isActive {
                BlenderImmersiveMultiuserSession.shared.sendLocalPresence(
                  x: blender.x, y: blender.y, z: blender.z, tipDown: drawDown)
              }
            }

            if ticks % 30 == 0 {
              print(
                String(
                  format:
                    "[immersive] Muse sample tracked=%@ draw=%@ p=%.2f blender=(%.3f, %.3f, %.3f)",
                  anchor.isAnchored ? "yes" : "no",
                  drawDown ? "down" : "up",
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
      return BlenderImmersiveCoords.realityKitToBlender(local)
    }

    private func makeCursorVisual() -> Entity {
      /* Pink tip sphere — scale/color update with pressure in updateTipVisual.
       * Kept translucent so the hand / work surface stays visible underneath. */
      let tip = ModelEntity(
        mesh: .generateSphere(radius: 0.04),
        materials: [
          Self.translucentTipMaterial(color: .systemPink, alpha: 0.28)
        ])
      tip.name = "MuseTip"
      tip.scale = SIMD3(repeating: 0.6)
      /* Faint overall — see-through cursor so fine detail work is not occluded. */
      tip.components.set(OpacityComponent(opacity: 0.35))

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

    /** Grow + redden the tip sphere with stylus force so pressure is obvious in Immersive. */
    private func updateTipVisual(on anchor: Entity, tipDown: Bool, rawPressure: Float) {
      guard let tip = anchor.findEntity(named: "MuseTip") as? ModelEntity else { return }
      let p = tipDown ? max(0, min(1, rawPressure)) : 0
      /* Idle ~0.6×; tip-down starts ~1.0× and grows to ~2.8× at full pressure. */
      let scale: Float = tipDown ? (1.0 + p * 1.8) : 0.6
      tip.scale = SIMD3(repeating: scale)
      let color: UIColor
      /* Keep the cursor faint so the hand stays visible; alpha stays low even at
       * full pressure (opacity ramps only slightly with force). */
      let alpha: CGFloat
      if tipDown {
        /* Soft pink → vivid red as pressure rises. */
        color = UIColor(
          red: CGFloat(1.0),
          green: CGFloat(0.55 - p * 0.45),
          blue: CGFloat(0.55 - p * 0.45),
          alpha: 1.0)
        alpha = CGFloat(0.30 + Double(p) * 0.25)
      }
      else {
        color = UIColor.systemPink
        alpha = 0.28
      }
      tip.model?.materials = [Self.translucentTipMaterial(color: color, alpha: Float(alpha))]
      tip.components.set(OpacityComponent(opacity: Float(alpha)))
    }

    /** UnlitMaterial that actually blends (alpha color alone does not enable transparency). */
    private static func translucentTipMaterial(color: UIColor, alpha: Float) -> UnlitMaterial {
      var material = UnlitMaterial(color: color)
      material.color = .init(tint: color.withAlphaComponent(CGFloat(alpha)))
      material.blending = .transparent(opacity: .init(floatLiteral: alpha))
      return material
    }
  }

#endif
