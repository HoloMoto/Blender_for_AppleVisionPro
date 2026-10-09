/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * visionOS Speaker playback via AVAudioEngine.
 *
 * WITH_AUDASPACE is forced OFF (CoreAudioClock missing on iOS/visionOS), so
 * Blender's mixer is silent. This module replaces it for Speaker objects.
 *
 * TF-155: Play through mainMixerNode (not AVAudioEnvironmentNode). Environment
 * + stereo files produced complete silence on device. Manual distance falloff
 * keeps a light spatial cue without the EnvironmentNode format trap.
 */

import AVFoundation
import Foundation
import simd

#if os(visionOS) || os(iOS)

  public struct BlenderImmersiveSpeakerPayload {
    public let name: String
    public let soundPath: String
    public let positionBlender: SIMD3<Float>
    public let volume: Float
    public let pitch: Float
    public let distanceMax: Float
    public let distanceRef: Float
    public let attenuation: Float
    public let muted: Bool
    public let playing: Bool
    public let seekSeconds: Double
  }

  @MainActor
  public final class BlenderVisionOSAudio {
    public static let shared = BlenderVisionOSAudio()

    private let engine = AVAudioEngine()
    private var started = false
    private var players: [String: AVAudioPlayerNode] = [:]
    private var files: [String: AVAudioFile] = [:]
    private var loadedPaths: [String: String] = [:]
    private var lastSeek: [String: Double] = [:]
    private var wasPlaying: [String: Bool] = [:]

    private init() {}

    private func log(_ msg: String) {
      print("[audio] \(msg)")
      BlenderIOSDiagnosticLog.bootSwiftOnly("audio: \(msg)")
    }

    private var sessionReady = false
    private var generation: [String: Int] = [:]
    private var lastStartFailure: TimeInterval = -1000
    private var playAnchor: [String: (seek: Double, time: TimeInterval)] = [:]

    private func ensureSession() {
      if sessionReady { return }
      sessionReady = true
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
          AVAudioSessionCategoryPlayback,
          mode: AVAudioSessionModeDefault,
          options: [.mixWithOthers])
        try session.setActive(true)
      }
      catch {
        log("AVAudioSession failed: \(error)")
      }
    }

    /**
     * AVAudioEngine.start() raises an uncaught NSException (not a Swift error)
     * when the graph has no output node, and AVAudioPlayerNode.play() raises
     * when the engine is not running. Only call once a player is attached.
     */
    private func ensureRunning() -> Bool {
      if engine.isRunning { return true }
      guard !players.isEmpty else { return false }
      let now = Date.timeIntervalSinceReferenceDate
      if now - lastStartFailure < 2.0 { return false }
      ensureSession()
      _ = engine.mainMixerNode
      _ = engine.outputNode
      engine.prepare()
      do {
        try engine.start()
        if !started {
          log("AVAudioEngine started (mainMixer)")
        }
        started = true
        return engine.isRunning
      }
      catch {
        lastStartFailure = now
        log("AVAudioEngine start failed: \(error)")
        return false
      }
    }

    /** Soft inverse-distance falloff in Blender meters (listener ≈ origin). */
    private static func gain(for payload: BlenderImmersiveSpeakerPayload) -> Float {
      let pos = payload.positionBlender
      let dist = max(0.05, sqrt(pos.x * pos.x + pos.y * pos.y + pos.z * pos.z))
      let ref = max(0.1, payload.distanceRef)
      let maxD = max(ref, payload.distanceMax > 0 ? payload.distanceMax : ref * 40)
      if dist >= maxD {
        return 0.02 * max(0, min(1, payload.volume))
      }
      let rolloff = max(0.1, payload.attenuation)
      let atten = ref / (ref + rolloff * max(0, dist - ref))
      return max(0, min(1, payload.volume * atten))
    }

    public func apply(payloads: [BlenderImmersiveSpeakerPayload]) {
      if payloads.isEmpty && players.isEmpty {
        return
      }

      var keep = Set<String>()
      for payload in payloads {
        keep.insert(payload.name)
        upsert(payload)
      }
      for name in players.keys where !keep.contains(name) {
        stopPlayer(name)
      }
    }

    public func clear() {
      for name in Array(players.keys) {
        stopPlayer(name)
      }
    }

    private func stopPlayer(_ name: String) {
      generation[name, default: 0] += 1
      wasPlaying[name] = false
      players[name]?.stop()
      if let node = players[name] {
        engine.detach(node)
      }
      players.removeValue(forKey: name)
      files.removeValue(forKey: name)
      loadedPaths.removeValue(forKey: name)
      lastSeek.removeValue(forKey: name)
      wasPlaying.removeValue(forKey: name)
      playAnchor.removeValue(forKey: name)
    }

    @discardableResult
    private func scheduleFrom(
      name: String, player: AVAudioPlayerNode, file: AVAudioFile, seekSeconds: Double
    ) -> Bool {
      let rate = file.processingFormat.sampleRate
      var start = AVAudioFramePosition(max(0, seekSeconds) * rate)
      if start >= file.length {
        start = 0
      }
      let count = AVAudioFrameCount(max(0, file.length - start))
      guard count > 0 else { return false }
      guard ensureRunning() else { return false }
      /* stop() fires the pending completion of the old segment; the bumped
       * generation makes that callback a no-op instead of a reschedule loop. */
      generation[name, default: 0] += 1
      let gen = generation[name]!
      player.stop()
      player.scheduleSegment(
        file, startingFrame: start, frameCount: count, at: nil,
        completionCallbackType: .dataPlayedBack
      ) { _ in
        Task { @MainActor in
          let audio = BlenderVisionOSAudio.shared
          guard audio.generation[name] == gen,
                audio.wasPlaying[name] == true,
                let p = audio.players[name],
                let f = audio.files[name]
          else {
            return
          }
          audio.lastSeek[name] = 0
          audio.scheduleFrom(name: name, player: p, file: f, seekSeconds: 0)
        }
      }
      if engine.isRunning && !player.isPlaying {
        player.play()
      }
      return true
    }

    private func upsert(_ payload: BlenderImmersiveSpeakerPayload) {
      if payload.muted || payload.soundPath.isEmpty {
        players[payload.name]?.pause()
        wasPlaying[payload.name] = false
        return
      }

      let pathChanged = loadedPaths[payload.name] != payload.soundPath
      if pathChanged || players[payload.name] == nil {
        do {
          let url = URL(fileURLWithPath: payload.soundPath)
          guard FileManager.default.fileExists(atPath: url.path) else {
            log("missing file \(payload.soundPath)")
            return
          }
          let file = try AVAudioFile(forReading: url)
          if let old = players[payload.name] {
            old.stop()
            engine.detach(old)
          }
          let player = AVAudioPlayerNode()
          engine.attach(player)
          /* Direct to mainMixer — EnvironmentNode + stereo was silent on VP. */
          engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
          players[payload.name] = player
          files[payload.name] = file
          loadedPaths[payload.name] = payload.soundPath
          lastSeek[payload.name] = -1
          wasPlaying[payload.name] = false
          log(
            "loaded \(payload.name) ch=\(file.processingFormat.channelCount) sr=\(Int(file.processingFormat.sampleRate))"
          )
        }
        catch {
          log("load failed \(payload.name): \(error)")
          return
        }
      }

      guard let player = players[payload.name], let file = files[payload.name] else {
        return
      }

      player.volume = Self.gain(for: payload)

      let seek = max(0.0, payload.seekSeconds)
      let prev = lastSeek[payload.name] ?? -1
      let playingNow = wasPlaying[payload.name] ?? false
      let now = Date.timeIntervalSinceReferenceDate
      /* While playing, compare against where the audio should be (anchor +
       * wall time) so slow/dropped UI frames are not mistaken for scrubs. */
      let expected: Double
      if playingNow, let anchor = playAnchor[payload.name] {
        expected = anchor.seek + (now - anchor.time)
      }
      else {
        expected = prev
      }
      let needSeek = abs(seek - expected) > (playingNow ? 0.5 : 0.25)

      if payload.playing {
        if !playingNow || needSeek || !engine.isRunning {
          wasPlaying[payload.name] = true
          lastSeek[payload.name] = seek
          playAnchor[payload.name] = (seek, now)
          guard scheduleFrom(name: payload.name, player: player, file: file, seekSeconds: seek)
          else {
            wasPlaying[payload.name] = false
            return
          }
          log(
            "play \(payload.name) seek=\(String(format: "%.2f", seek)) vol=\(String(format: "%.2f", player.volume)) spk_vol=\(payload.volume) pos=\(payload.positionBlender) ref=\(payload.distanceRef) max=\(payload.distanceMax) att=\(payload.attenuation)"
          )
        }
        else {
          /* Track the timeline so normal playback is not mistaken for a jump. */
          lastSeek[payload.name] = seek
        }
      }
      else {
        if playingNow {
          player.pause()
          wasPlaying[payload.name] = false
        }
        if needSeek {
          lastSeek[payload.name] = seek
        }
      }
    }
  }

#else

  public struct BlenderImmersiveSpeakerPayload {
    public let name: String
    public let soundPath: String
    public let positionBlender: SIMD3<Float>
    public let volume: Float
    public let pitch: Float
    public let distanceMax: Float
    public let distanceRef: Float
    public let attenuation: Float
    public let muted: Bool
    public let playing: Bool
    public let seekSeconds: Double
  }

#endif
