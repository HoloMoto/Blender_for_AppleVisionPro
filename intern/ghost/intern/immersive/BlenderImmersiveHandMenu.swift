/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Palm Hand Menu — Immersive essentials + spatial Shading (material nodes).
 */

import SwiftUI

#if os(visionOS)

  @_silgen_name("WM_IOS_immersive_hand_menu_set_mode")
  private func WM_IOS_immersive_hand_menu_set_mode(_ mode: Int32)

  @_silgen_name("WM_IOS_immersive_hand_menu_set_radius")
  private func WM_IOS_immersive_hand_menu_set_radius(_ radius: Float)

  @_silgen_name("WM_IOS_immersive_set_hand_as_pen")
  private func WM_IOS_immersive_set_hand_as_pen(_ enabled: Int32)

  @_silgen_name("WM_IOS_immersive_set_hand_proximity_sculpt")
  private func WM_IOS_immersive_set_hand_proximity_sculpt(_ enabled: Int32)

  @_silgen_name("WM_IOS_immersive_set_shader_space")
  private func WM_IOS_immersive_set_shader_space(_ enabled: Int32)

  @_silgen_name("WM_IOS_immersive_shader_add_node")
  private func WM_IOS_immersive_shader_add_node(
    _ idname: UnsafePointer<CChar>, _ locx: Float, _ locy: Float)

  @_silgen_name("WM_IOS_immersive_shader_delete_node")
  private func WM_IOS_immersive_shader_delete_node(_ nodeName: UnsafePointer<CChar>)

  @_silgen_name("WM_IOS_immersive_shader_select_node")
  private func WM_IOS_immersive_shader_select_node(_ nodeName: UnsafePointer<CChar>?)

  @_silgen_name("WM_IOS_immersive_shader_repair_materials")
  private func WM_IOS_immersive_shader_repair_materials(_ forceAll: Int32)

  @_silgen_name("WM_IOS_immersive_shader_set_socket_float")
  private func WM_IOS_immersive_shader_set_socket_float(
    _ nodeName: UnsafePointer<CChar>, _ sockId: UnsafePointer<CChar>, _ value: Float)

  @_silgen_name("WM_IOS_immersive_shader_set_socket_rgba")
  private func WM_IOS_immersive_shader_set_socket_rgba(
    _ nodeName: UnsafePointer<CChar>,
    _ sockId: UnsafePointer<CChar>,
    _ r: Float,
    _ g: Float,
    _ b: Float,
    _ a: Float)

  private struct ShaderAddItem: Identifiable {
    let id: String
    let label: String
    var idname: String { id }
  }

  private let kShaderAddItems: [ShaderAddItem] = [
    .init(id: "ShaderNodeBsdfPrincipled", label: "Principled"),
    .init(id: "ShaderNodeEmission", label: "Emission"),
    .init(id: "ShaderNodeBsdfDiffuse", label: "Diffuse"),
    .init(id: "ShaderNodeBsdfGlass", label: "Glass"),
    .init(id: "ShaderNodeMixShader", label: "Mix Shader"),
    .init(id: "ShaderNodeTexImage", label: "Image Tex"),
    .init(id: "ShaderNodeTexNoise", label: "Noise"),
    .init(id: "ShaderNodeRGB", label: "RGB"),
    .init(id: "ShaderNodeValue", label: "Value"),
    .init(id: "ShaderNodeMath", label: "Math"),
    .init(id: "ShaderNodeMix", label: "Mix"),
    .init(id: "ShaderNodeValToRGB", label: "Ramp"),
    .init(id: "ShaderNodeMapping", label: "Mapping"),
    .init(id: "ShaderNodeBump", label: "Bump"),
    .init(id: "ShaderNodeNormalMap", label: "NormalMap"),
    .init(id: "ShaderNodeHueSaturation", label: "Hue/Sat"),
  ]

  struct BlenderImmersiveHandMenuPanel: View {
    @Binding var mode: Int
    @Binding var radius: Float

    @State private var useHandAsPen = BlenderImmersiveState.shared.useHandAsPen
    @State private var handProximitySculpt = BlenderImmersiveState.shared.handProximitySculpt
    @State private var matMode = BlenderImmersiveState.shared.shaderSpaceEnabled
    @State private var spatialBoard = BlenderImmersiveState.shared.spatialBoardWanted
    @State private var selectedName = BlenderImmersiveState.shared.shaderSelectedName
    @State private var selectedType = BlenderImmersiveState.shared.shaderSelectedType
    @State private var propPacked = BlenderImmersiveState.shared.shaderPropPacked
    @State private var propNames = BlenderImmersiveState.shared.shaderPropNames
    @State private var propCount = BlenderImmersiveState.shared.shaderPropCount
    @State private var matName = BlenderImmersiveState.shared.shaderMaterialName
    @State private var editFloats: [String: Float] = [:]
    @State private var editColors: [String: (Float, Float, Float, Float)] = [:]

    var body: some View {
      HStack(alignment: .top, spacing: 8) {
        VStack(spacing: 7) {
          modeButton("Obj", 0)
          modeButton("Edit", 1)
          modeButton("Sculpt", 2)
          modeButton("VPaint", 3)
          modeButton("Anim", 4)
          Button(matMode ? "Mat●" : "Mat") {
            let next = !matMode
            /* Clear local prop UI *before* Mat panel appears — stale Sliders crash. */
            selectedName = ""
            selectedType = ""
            propCount = 0
            propPacked = []
            propNames = []
            editFloats = [:]
            editColors = [:]
            matMode = next
            if !next { spatialBoard = false }
            WM_IOS_immersive_set_shader_space(next ? 1 : 0)
          }
          .buttonStyle(.borderedProminent)
          .tint(matMode ? .yellow.opacity(0.95) : .gray.opacity(0.45))
          .controlSize(.regular)
          .frame(maxWidth: .infinity, minHeight: 40)
          Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 78, height: matMode ? 360 : 300)
        .glassBackgroundEffect()

        VStack(alignment: .leading, spacing: 8) {
          if matMode {
            matPanel
          }
          else {
            sculptPanel
          }
          Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: matMode ? 240 : 210, height: matMode ? 360 : 300, alignment: .topLeading)
        .glassBackgroundEffect()
      }
      .onAppear(perform: syncFromState)
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveHandAsPenChanged)) {
        _ in
        useHandAsPen = BlenderImmersiveState.shared.useHandAsPen
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveHandProximityChanged)) {
        _ in
        handProximitySculpt = BlenderImmersiveState.shared.handProximitySculpt
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveShaderGraphChanged)) {
        _ in
        syncFromState()
      }
    }

    @ViewBuilder private var sculptPanel: some View {
      Text(modeTitle)
        .font(.caption.weight(.semibold))

      Button(useHandAsPen ? "入力: Palm" : "入力: Muse") {
        useHandAsPen.toggle()
        WM_IOS_immersive_set_hand_as_pen(useHandAsPen ? 1 : 0)
      }
      .buttonStyle(.borderedProminent)
      .tint(useHandAsPen ? .mint.opacity(0.9) : .orange.opacity(0.85))
      .controlSize(.regular)
      .frame(maxWidth: .infinity, minHeight: 44)
      .disabled(mode == 0)
      .opacity(mode == 0 ? 0.45 : 1)

      if useHandAsPen && mode != 0 {
        Button(handProximitySculpt ? "発火: 近接" : "発火: ピンチ") {
          handProximitySculpt.toggle()
          WM_IOS_immersive_set_hand_proximity_sculpt(handProximitySculpt ? 1 : 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(maxWidth: .infinity, minHeight: 40)
        .tint(handProximitySculpt ? .purple.opacity(0.85) : .gray.opacity(0.5))
      }

      if mode == 2 || mode == 3 || mode == 4 {
        Text(String(format: mode == 4 ? "掴み %.2f m" : "半径 %.2f m", radius))
          .font(.caption2)
        Slider(
          value: Binding(
            get: { radius },
            set: {
              radius = $0
              WM_IOS_immersive_hand_menu_set_radius($0)
            }),
          in: 0.02...0.80,
          step: 0.02)
      }
    }

    @ViewBuilder private var matPanel: some View {
      VStack(alignment: .leading, spacing: 8) {
        Text("Shading（Hand）")
          .font(.caption.weight(.semibold))
        Text(matName.isEmpty ? "材質なし（ノード材質を選択）" : matName)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        /* Selected node name lives here (not as spatial Attachments — those SIGTRAP). */
        Text(selectedName.isEmpty ? "ノード未選択" : selectedName)
          .font(.system(size: 17, weight: .bold, design: .rounded))
          .foregroundStyle(selectedName.isEmpty ? .secondary : .primary)
          .lineLimit(2)
          .minimumScaleFactor(0.7)
          .frame(maxWidth: .infinity, alignment: .leading)
        if !selectedType.isEmpty {
          Text(selectedType)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Button("材質修復（ピンク直し）") {
          WM_IOS_immersive_shader_repair_materials(1)
        }
        .buttonStyle(.borderedProminent)
        .tint(.pink.opacity(0.85))
        .controlSize(.small)
        .frame(maxWidth: .infinity, minHeight: 36)
        Button(spatialBoard ? "空間ボード ON" : "空間ボード OFF") {
          let next = !spatialBoard
          spatialBoard = next
          BlenderImmersiveState.shared.applySpatialBoardWanted(next)
        }
        .buttonStyle(.borderedProminent)
        .tint(spatialBoard ? .cyan.opacity(0.9) : .gray.opacity(0.45))
        .disabled(!matMode)
        .opacity(matMode ? 1 : 0.45)
        .controlSize(.small)
        .frame(maxWidth: .infinity, minHeight: 36)
        Text("ボードON後: 色付き箱を掴む（種類色）。重ねると緑点滅で自動配線。名前は上に表示。")
          .font(.caption2)
          .foregroundStyle(.secondary)

        Text("追加")
          .font(.caption2.weight(.semibold))
        HStack(spacing: 4) {
          ForEach(Array(kShaderAddItems.prefix(4))) { item in
            Button(item.label) { addNode(item.idname) }
              .buttonStyle(.bordered)
              .controlSize(.mini)
          }
        }
        HStack(spacing: 4) {
          ForEach(Array(kShaderAddItems.dropFirst(4).prefix(4))) { item in
            Button(item.label) { addNode(item.idname) }
              .buttonStyle(.bordered)
              .controlSize(.mini)
          }
        }

        Divider()

        let names = BlenderImmersiveState.shared.shaderNodeNames
        if names.isEmpty {
          Text("ノードなし — 追加するか、use_nodes 材質を選択")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        else {
          Text("ノード")
            .font(.caption2.weight(.semibold))
          ForEach(Array(names.prefix(10).enumerated()), id: \.offset) { _, name in
            Button {
              selectedName = name
              name.withCString { WM_IOS_immersive_shader_select_node($0) }
            } label: {
              HStack {
                Text(name)
                  .font(.caption2)
                  .lineLimit(1)
                Spacer(minLength: 0)
                if name == selectedName {
                  Text("●").font(.caption2).foregroundStyle(.yellow)
                }
              }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(name == selectedName ? .yellow.opacity(0.85) : .gray.opacity(0.4))
          }
        }

        if !selectedName.isEmpty {
          Button("削除") {
            selectedName.withCString { WM_IOS_immersive_shader_delete_node($0) }
            selectedName = ""
            selectedType = ""
            propCount = 0
            propPacked = []
            propNames = []
            editFloats = [:]
            editColors = [:]
          }
          .buttonStyle(.borderedProminent)
          .tint(.red.opacity(0.8))
          .controlSize(.small)

          /* No SwiftUI Slider — NaN/bad ranges crash visionOS. Use steppers only. */
          ForEach(0..<min(propCount, 4), id: \.self) { i in
            if propPacked.count >= (i + 1) * 8, i < propNames.count {
              propStepper(index: i)
            }
          }
        }
      }
    }

    @ViewBuilder private func propStepper(index: Int) -> some View {
      let o = index * 8
      let type = Int(propPacked[o].rounded())
      let linked = propPacked[o + 1] > 0.5
      let name = propNames[index]
      let rawMin = propPacked[o + 6]
      let rawMax = propPacked[o + 7]
      let minV = rawMin.isFinite ? rawMin : 0
      let maxV = (rawMax.isFinite && rawMax > minV) ? rawMax : (minV + 1)

      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(name).font(.caption2.weight(.medium))
          if linked { Text("接続済").font(.caption2).foregroundStyle(.secondary) }
        }
        if type == 2 {
          let c = sanitizedColor(editColors[name] ?? (propPacked[o + 2], propPacked[o + 3],
            propPacked[o + 4], propPacked[o + 5]))
          Text(String(format: "RGB %.2f %.2f %.2f", c.0, c.1, c.2))
            .font(.caption2)
          HStack(spacing: 4) {
            Button("R−") { nudgeColor(name, channel: 0, delta: -0.05) }.disabled(linked)
            Button("R+") { nudgeColor(name, channel: 0, delta: 0.05) }.disabled(linked)
            Button("G−") { nudgeColor(name, channel: 1, delta: -0.05) }.disabled(linked)
            Button("G+") { nudgeColor(name, channel: 1, delta: 0.05) }.disabled(linked)
            Button("B−") { nudgeColor(name, channel: 2, delta: -0.05) }.disabled(linked)
            Button("B+") { nudgeColor(name, channel: 2, delta: 0.05) }.disabled(linked)
          }
          .buttonStyle(.bordered)
          .controlSize(.mini)
        }
        else if type == 1 || type == 3 {
          let cur = editFloats[name] ?? propPacked[o + 2]
          let safeCur = cur.isFinite ? min(max(cur, minV), maxV) : minV
          HStack {
            Text(String(format: "%.2f", safeCur)).font(.caption2).frame(width: 40, alignment: .leading)
            Button("−") { nudgeFloat(name, delta: -(maxV - minV) * 0.05, minV: minV, maxV: maxV) }
              .disabled(linked)
            Button("+") { nudgeFloat(name, delta: (maxV - minV) * 0.05, minV: minV, maxV: maxV) }
              .disabled(linked)
          }
          .buttonStyle(.bordered)
          .controlSize(.mini)
        }
      }
      .opacity(linked ? 0.55 : 1)
    }

    private func sanitizedColor(_ c: (Float, Float, Float, Float)) -> (Float, Float, Float, Float) {
      func ch(_ v: Float) -> Float {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), 1)
      }
      return (ch(c.0), ch(c.1), ch(c.2), ch(c.3))
    }

    private func nudgeColor(_ name: String, channel: Int, delta: Float) {
      var c = sanitizedColor(editColors[name] ?? (0.8, 0.8, 0.8, 1))
      switch channel {
      case 0: c.0 = min(max(c.0 + delta, 0), 1)
      case 1: c.1 = min(max(c.1 + delta, 0), 1)
      default: c.2 = min(max(c.2 + delta, 0), 1)
      }
      editColors[name] = c
      pushColor(name, c.0, c.1, c.2, c.3)
    }

    private func nudgeFloat(_ name: String, delta: Float, minV: Float, maxV: Float) {
      let cur = editFloats[name] ?? 0
      let base = cur.isFinite ? cur : minV
      let next = min(max(base + delta, minV), maxV)
      editFloats[name] = next
      pushFloat(name, next)
    }

    private func pushFloat(_ sock: String, _ value: Float) {
      guard !selectedName.isEmpty else { return }
      selectedName.withCString { n in
        sock.withCString { s in
          WM_IOS_immersive_shader_set_socket_float(n, s, value)
        }
      }
    }

    private func pushColor(_ sock: String, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
      guard !selectedName.isEmpty else { return }
      selectedName.withCString { n in
        sock.withCString { s in
          WM_IOS_immersive_shader_set_socket_rgba(n, s, r, g, b, a)
        }
      }
    }

    private func addNode(_ idname: String) {
      /* Place near selected node, else at a default canvas spot. */
      var x: Float = 0
      var y: Float = 300
      let packed = BlenderImmersiveState.shared.shaderNodePacked
      let names = BlenderImmersiveState.shared.shaderNodeNames
      if let idx = names.firstIndex(of: selectedName), packed.count >= (idx + 1) * 6 {
        x = packed[idx * 6] + 220
        y = packed[idx * 6 + 1]
      }
      idname.withCString { WM_IOS_immersive_shader_add_node($0, x, y) }
    }

    private func shortType(_ typeId: String) -> String {
      _ = typeId
      return "Node"
    }

    private func syncFromState() {
      useHandAsPen = BlenderImmersiveState.shared.useHandAsPen
      handProximitySculpt = BlenderImmersiveState.shared.handProximitySculpt
      matMode = BlenderImmersiveState.shared.shaderSpaceEnabled
      spatialBoard = BlenderImmersiveState.shared.spatialBoardWanted
      selectedName = BlenderImmersiveState.shared.shaderSelectedName
      selectedType = BlenderImmersiveState.shared.shaderSelectedType
      propPacked = BlenderImmersiveState.shared.shaderPropPacked
      propNames = BlenderImmersiveState.shared.shaderPropNames
      propCount = BlenderImmersiveState.shared.shaderPropCount
      matName = BlenderImmersiveState.shared.shaderMaterialName

      var floats: [String: Float] = [:]
      var colors: [String: (Float, Float, Float, Float)] = [:]
      for i in 0..<propCount {
        let o = i * 8
        guard propPacked.count >= o + 8, i < propNames.count else { continue }
        let name = propNames[i]
        let type = Int(propPacked[o].rounded())
        if type == 2 {
          colors[name] = (propPacked[o + 2], propPacked[o + 3], propPacked[o + 4], propPacked[o + 5])
        }
        else {
          floats[name] = propPacked[o + 2]
        }
      }
      editFloats = floats
      editColors = colors
    }

    private var modeTitle: String {
      switch mode {
      case 0: return "Object"
      case 1: return "Edit"
      case 2: return "Sculpt"
      case 3: return "VPaint"
      case 4: return "Anim"
      default: return "Hand"
      }
    }

    private func modeButton(_ title: String, _ value: Int) -> some View {
      Button(title) {
        mode = value
        WM_IOS_immersive_hand_menu_set_mode(Int32(value))
        if matMode {
          matMode = false
          WM_IOS_immersive_set_shader_space(0)
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(mode == value && !matMode ? .blue : .gray.opacity(0.45))
      .controlSize(.regular)
      .frame(maxWidth: .infinity, minHeight: 40)
    }
  }

#endif
