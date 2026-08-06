/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Immersive-only studio panel (independent WindowGroup).
 * Opens with Immersive Space — brushes, anim, material/shader, placement.
 * Not an ornament on the 2D/3D Blender viewport.
 */

import SwiftUI
import UIKit

#if os(visionOS)

  @_silgen_name("WM_IOS_immersive_hand_menu_set_mode")
  private func WM_IOS_immersive_hand_menu_set_mode(_ mode: Int32)
  @_silgen_name("WM_IOS_immersive_hand_menu_set_brush")
  private func WM_IOS_immersive_hand_menu_set_brush(
    _ toolId: UnsafePointer<CChar>, _ kind: Int32)
  @_silgen_name("WM_IOS_immersive_hand_menu_set_strength")
  private func WM_IOS_immersive_hand_menu_set_strength(_ strength: Float)
  @_silgen_name("WM_IOS_immersive_hand_menu_set_radius")
  private func WM_IOS_immersive_hand_menu_set_radius(_ radius: Float)
  @_silgen_name("WM_IOS_immersive_muse_toggle_vpaint_erase")
  private func WM_IOS_immersive_muse_toggle_vpaint_erase()
  @_silgen_name("WM_IOS_immersive_hand_menu_remesh")
  private func WM_IOS_immersive_hand_menu_remesh()
  @_silgen_name("WM_IOS_immersive_hand_menu_set_dyntopo")
  private func WM_IOS_immersive_hand_menu_set_dyntopo(_ enabled: Int32)
  @_silgen_name("WM_IOS_immersive_anim_insert_key")
  private func WM_IOS_immersive_anim_insert_key()
  @_silgen_name("WM_IOS_immersive_anim_delete_key")
  private func WM_IOS_immersive_anim_delete_key()
  @_silgen_name("WM_IOS_immersive_anim_play")
  private func WM_IOS_immersive_anim_play()
  @_silgen_name("WM_IOS_immersive_anim_stop")
  private func WM_IOS_immersive_anim_stop()
  @_silgen_name("WM_IOS_immersive_anim_frame_delta")
  private func WM_IOS_immersive_anim_frame_delta(_ delta: Int32)
  @_silgen_name("WM_IOS_immersive_anim_set_frame")
  private func WM_IOS_immersive_anim_set_frame(_ frame: Int32)
  @_silgen_name("WM_IOS_immersive_anim_set_pose_xform")
  private func WM_IOS_immersive_anim_set_pose_xform(_ mode: Int32)
  @_silgen_name("WM_IOS_immersive_anim_set_target")
  private func WM_IOS_immersive_anim_set_target(_ target: Int32)
  @_silgen_name("WM_IOS_immersive_camera_key_from_viewer")
  private func WM_IOS_immersive_camera_key_from_viewer()
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

  struct BlenderImmersiveViewportPanel: View {
    private enum StudioTab: String, CaseIterable, Identifiable {
      case brush = "ブラシ"
      case anim = "アニメ"
      case material = "マテリアル"
      case space = "空間"
      var id: String { rawValue }
    }

    @State private var tab: StudioTab = .brush
    @State private var mode = BlenderImmersiveState.shared.handMenuMode
    @State private var brushKind = BlenderImmersiveState.shared.handMenuBrushKind
    @State private var strength = BlenderImmersiveState.shared.handMenuStrength
    @State private var radius = BlenderImmersiveState.shared.handMenuRadius
    @State private var brushLabel = BlenderImmersiveState.shared.handMenuBrushLabel
    @State private var dyntopoOn = BlenderImmersiveState.shared.handMenuDyntopo
    @State private var immersiveActive = BlenderImmersiveState.shared.isActive
    @State private var poseXformMode = BlenderImmersiveState.shared.animPoseXformMode
    @State private var animTargetMode = BlenderImmersiveState.shared.animTargetMode
    @State private var animFrame = Float(BlenderImmersiveState.shared.animFrame)
    @State private var animFrameStart = Float(BlenderImmersiveState.shared.animFrameStart)
    @State private var animFrameEnd = Float(BlenderImmersiveState.shared.animFrameEnd)
    @State private var animKeyFrames = BlenderImmersiveState.shared.animKeyFrames
    @State private var animActiveBone = BlenderImmersiveState.shared.animActiveBone
    @State private var sliderEditing = false
    @State private var originX = BlenderImmersiveState.shared.placementX
    @State private var originHeight = BlenderImmersiveState.shared.placementY
    @State private var originDepth = BlenderImmersiveState.shared.placementZ
    @State private var multiuserStatus = "Idle"
    @State private var multiuserActive = false
    @State private var multiuserHost = false
    @State private var anchorStatus = "Anchor: 未設定"
    @State private var shaderSpace = BlenderImmersiveState.shared.shaderSpaceEnabled
    @State private var shaderMaterialName = BlenderImmersiveState.shared.shaderMaterialName
    @State private var shaderNodeCount = BlenderImmersiveState.shared.shaderNodeCount
    @State private var shaderLinkCount = BlenderImmersiveState.shared.shaderLinkCount
    @State private var shaderSelectedName = BlenderImmersiveState.shared.shaderSelectedName
    @State private var shaderSelectedType = BlenderImmersiveState.shared.shaderSelectedType
    @State private var shaderPropPacked = BlenderImmersiveState.shared.shaderPropPacked
    @State private var shaderPropNames = BlenderImmersiveState.shared.shaderPropNames
    @State private var shaderPropCount = BlenderImmersiveState.shared.shaderPropCount
    @State private var shaderEditFloats: [String: Float] = [:]
    @State private var shaderEditColors: [String: (Float, Float, Float, Float)] = [:]

    private let brushes: [(title: String, toolId: String, kind: Int)] = [
      ("Inflate+", "builtin.brush", 4),
      ("Inflate−", "builtin.brush", 5),
      ("Smooth", "builtin.brush", 3),
      ("Grab", "builtin.brush", 2),
    ]

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text("没入スタジオ")
            .font(.title3.weight(.semibold))
          Spacer()
          Text(immersiveActive ? "連動中" : "待機")
            .font(.caption)
            .foregroundStyle(immersiveActive ? .green : .secondary)
        }

        Picker("", selection: $tab) {
          ForEach(StudioTab.allCases) { item in
            Text(item.rawValue).tag(item)
          }
        }
        .pickerStyle(.segmented)

        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            switch tab {
            case .brush: brushTab
            case .anim: animTab
            case .material: materialTab
            case .space: spaceTab
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.bottom, 8)
        }
      }
      .padding(16)
      .frame(minWidth: 360, idealWidth: 380, minHeight: 440)
      .onAppear(perform: refreshAll)
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveHandMenuChanged)) { _ in
        syncHandMenu()
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveAnimTimelineChanged)) {
        _ in
        syncAnim()
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersivePlacementChanged)) { _ in
        originX = BlenderImmersiveState.shared.placementX
        originHeight = BlenderImmersiveState.shared.placementY
        originDepth = BlenderImmersiveState.shared.placementZ
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveMultiuserChanged)) { _ in
        refreshMultiuser()
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveSharedAnchorChanged)) {
        _ in
        refreshAnchor()
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveActiveChanged)) { _ in
        immersiveActive = BlenderImmersiveState.shared.isActive
      }
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveShaderGraphChanged)) {
        _ in
        shaderSpace = BlenderImmersiveState.shared.shaderSpaceEnabled
        /* Only refresh graph UI when Material tab is visible — avoids thrashing Studio. */
        guard tab == .material else { return }
        shaderMaterialName = BlenderImmersiveState.shared.shaderMaterialName
        shaderNodeCount = BlenderImmersiveState.shared.shaderNodeCount
        shaderLinkCount = BlenderImmersiveState.shared.shaderLinkCount
        shaderSelectedName = BlenderImmersiveState.shared.shaderSelectedName
        shaderSelectedType = BlenderImmersiveState.shared.shaderSelectedType
        shaderPropPacked = BlenderImmersiveState.shared.shaderPropPacked
        shaderPropNames = BlenderImmersiveState.shared.shaderPropNames
        shaderPropCount = BlenderImmersiveState.shared.shaderPropCount
        var floats: [String: Float] = [:]
        var colors: [String: (Float, Float, Float, Float)] = [:]
        for i in 0..<shaderPropCount {
          let o = i * 8
          guard shaderPropPacked.count >= o + 8, i < shaderPropNames.count else { continue }
          let name = shaderPropNames[i]
          if Int(shaderPropPacked[o].rounded()) == 2 {
            colors[name] = (
              shaderPropPacked[o + 2], shaderPropPacked[o + 3], shaderPropPacked[o + 4],
              shaderPropPacked[o + 5]
            )
          }
          else {
            floats[name] = shaderPropPacked[o + 2]
          }
        }
        shaderEditFloats = floats
        shaderEditColors = colors
      }
    }

    @ViewBuilder private var brushTab: some View {
      Text(modeLabel)
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 6) {
        modeChip("Obj", 0)
        modeChip("Edit", 1)
        modeChip("Sculpt", 2)
        modeChip("VPaint", 3)
        modeChip("Anim", 4)
      }

      if mode == 2 {
        Text("ブラシ — \(brushLabel)")
          .font(.caption2)
          .foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
          ForEach(brushes, id: \.kind) { brush in
            Button(brush.title) {
              brushKind = brush.kind
              brush.toolId.withCString {
                WM_IOS_immersive_hand_menu_set_brush($0, Int32(brush.kind))
              }
            }
            .buttonStyle(.borderedProminent)
            .tint(brushKind == brush.kind ? .orange : .gray.opacity(0.4))
            .frame(minHeight: 40)
          }
        }
        Button(dyntopoOn ? "Dyntopo ON" : "Dyntopo OFF") {
          dyntopoOn.toggle()
          WM_IOS_immersive_hand_menu_set_dyntopo(dyntopoOn ? 1 : 0)
        }
        .buttonStyle(.borderedProminent)
        .tint(dyntopoOn ? .cyan.opacity(0.9) : .gray.opacity(0.45))
        .frame(maxWidth: .infinity, minHeight: 40)
      }

      if mode == 3 {
        Button("消去 ON/OFF") { WM_IOS_immersive_muse_toggle_vpaint_erase() }
          .buttonStyle(.bordered)
          .frame(maxWidth: .infinity, minHeight: 40)
      }

      if mode == 2 || mode == 3 {
        Text(String(format: "Strength %.0f%%", strength * 100))
          .font(.caption2)
        Slider(
          value: Binding(
            get: { strength },
            set: {
              strength = $0
              WM_IOS_immersive_hand_menu_set_strength($0)
            }),
          in: 0.05...1.0,
          step: 0.05)
      }

      Text(String(format: "Radius %.2f m", radius))
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

      Button("リメッシュ（DualCon）") { WM_IOS_immersive_hand_menu_remesh() }
        .buttonStyle(.borderedProminent)
        .tint(.blue.opacity(0.9))
        .frame(maxWidth: .infinity, minHeight: 40)
        .disabled(mode == 0 || mode == 4)
    }

    private var modeLabel: String {
      switch mode {
      case 0: return "現在: Object（閲覧）"
      case 1: return "現在: Edit"
      case 2: return "現在: Sculpt"
      case 3: return "現在: VPaint"
      case 4: return "現在: Anim"
      default: return "現在: —"
      }
    }

    @ViewBuilder private var materialTab: some View {
      Text("Shading エディタ")
        .font(.caption.weight(.semibold))
      Text("Mat後に「空間ボード ON」。色付き箱を掴んで移動、重ねると自動配線。ノード名はHandに大きく表示。")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Button {
        let next = !shaderSpace
        shaderSelectedName = ""
        shaderSelectedType = ""
        shaderPropCount = 0
        shaderPropPacked = []
        shaderPropNames = []
        shaderEditFloats = [:]
        shaderEditColors = [:]
        shaderSpace = next
        WM_IOS_immersive_set_shader_space(next ? 1 : 0)
      } label: {
        Text(shaderSpace ? "シェーダ ON" : "シェーダ OFF")
      }
      .buttonStyle(.borderedProminent)
      .tint(shaderSpace ? .yellow.opacity(0.95) : .gray.opacity(0.45))
      .frame(maxWidth: .infinity, minHeight: 44)

      Button("材質修復（ピンク直し）") {
        WM_IOS_immersive_shader_repair_materials(1)
      }
      .buttonStyle(.borderedProminent)
      .tint(.pink.opacity(0.85))
      .frame(maxWidth: .infinity, minHeight: 40)

      if shaderSpace {
        Group {
          if shaderMaterialName.isEmpty {
            Text("材質なし / ノードツリーなし")
          }
          else {
            Text(shaderMaterialName)
              .font(.body.weight(.medium))
            Text("\(shaderNodeCount) nodes · \(shaderLinkCount) links")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Text("ノード追加")
          .font(.caption.weight(.semibold))
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(
              [
                ("Principled", "ShaderNodeBsdfPrincipled"),
                ("RGB", "ShaderNodeRGB"),
                ("Value", "ShaderNodeValue"),
                ("Noise", "ShaderNodeTexNoise"),
                ("Image", "ShaderNodeTexImage"),
                ("Math", "ShaderNodeMath"),
                ("Mix", "ShaderNodeMix"),
                ("Emission", "ShaderNodeEmission"),
              ], id: \.1
            ) { label, idname in
              Button(label) {
                var x: Float = 0
                var y: Float = 300
                let packed = BlenderImmersiveState.shared.shaderNodePacked
                let names = BlenderImmersiveState.shared.shaderNodeNames
                if let idx = names.firstIndex(of: shaderSelectedName),
                  packed.count >= (idx + 1) * 6
                {
                  x = packed[idx * 6] + 220
                  y = packed[idx * 6 + 1]
                }
                idname.withCString { WM_IOS_immersive_shader_add_node($0, x, y) }
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }
          }
        }

        let names = BlenderImmersiveState.shared.shaderNodeNames
        if !names.isEmpty {
          Text("ノード一覧")
            .font(.caption.weight(.semibold))
          ForEach(Array(names.prefix(12).enumerated()), id: \.offset) { _, name in
            Button {
              shaderSelectedName = name
              name.withCString { WM_IOS_immersive_shader_select_node($0) }
            } label: {
              HStack {
                Text(name).font(.caption2).lineLimit(1)
                Spacer(minLength: 0)
                if name == shaderSelectedName {
                  Text("●").font(.caption2).foregroundStyle(.yellow)
                }
              }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(name == shaderSelectedName ? .yellow.opacity(0.85) : .gray.opacity(0.35))
          }
        }

        if !shaderSelectedName.isEmpty {
          Divider()
          Text(shaderSelectedType.replacingOccurrences(of: "ShaderNode", with: ""))
            .font(.caption.weight(.semibold))
          Button("ノード削除") {
            shaderSelectedName.withCString { WM_IOS_immersive_shader_delete_node($0) }
            shaderSelectedName = ""
            shaderSelectedType = ""
            shaderPropCount = 0
            shaderPropPacked = []
            shaderPropNames = []
          }
          .buttonStyle(.bordered)
          .tint(.red)

          ForEach(0..<min(shaderPropCount, 4), id: \.self) { i in
            if shaderPropPacked.count >= (i + 1) * 8, i < shaderPropNames.count {
              studioPropStepper(index: i)
            }
          }
        }
      }
    }

    @ViewBuilder private func studioPropStepper(index: Int) -> some View {
      let o = index * 8
      let type = Int(shaderPropPacked[o].rounded())
      let linked = shaderPropPacked[o + 1] > 0.5
      let name = shaderPropNames[index]
      let rawMin = shaderPropPacked[o + 6]
      let rawMax = shaderPropPacked[o + 7]
      let minV = rawMin.isFinite ? rawMin : 0
      let maxV = (rawMax.isFinite && rawMax > minV) ? rawMax : (minV + 1)
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(name).font(.caption2.weight(.medium))
          if linked { Text("接続済").font(.caption2).foregroundStyle(.secondary) }
        }
        if type == 2 {
          let c0 = shaderEditColors[name]?.0 ?? shaderPropPacked[o + 2]
          let c1 = shaderEditColors[name]?.1 ?? shaderPropPacked[o + 3]
          let c2 = shaderEditColors[name]?.2 ?? shaderPropPacked[o + 4]
          let r = c0.isFinite ? min(max(c0, 0), 1) : 0.8
          let g = c1.isFinite ? min(max(c1, 0), 1) : 0.8
          let b = c2.isFinite ? min(max(c2, 0), 1) : 0.8
          Text(String(format: "RGB %.2f %.2f %.2f", r, g, b)).font(.caption2)
          HStack(spacing: 4) {
            Button("R−") { nudgeStudioColor(name, 0, -0.05) }.disabled(linked)
            Button("R+") { nudgeStudioColor(name, 0, 0.05) }.disabled(linked)
            Button("G−") { nudgeStudioColor(name, 1, -0.05) }.disabled(linked)
            Button("G+") { nudgeStudioColor(name, 1, 0.05) }.disabled(linked)
            Button("B−") { nudgeStudioColor(name, 2, -0.05) }.disabled(linked)
            Button("B+") { nudgeStudioColor(name, 2, 0.05) }.disabled(linked)
          }
          .buttonStyle(.bordered)
          .controlSize(.mini)
        }
        else if type == 1 || type == 3 {
          let cur = shaderEditFloats[name] ?? shaderPropPacked[o + 2]
          let safe = cur.isFinite ? min(max(cur, minV), maxV) : minV
          HStack {
            Text(String(format: "%.2f", safe)).font(.caption2).frame(width: 40, alignment: .leading)
            Button("−") { nudgeStudioFloat(name, -(maxV - minV) * 0.05, minV, maxV) }
              .disabled(linked)
            Button("+") { nudgeStudioFloat(name, (maxV - minV) * 0.05, minV, maxV) }
              .disabled(linked)
          }
          .buttonStyle(.bordered)
          .controlSize(.mini)
        }
      }
      .opacity(linked ? 0.55 : 1)
    }

    private func nudgeStudioColor(_ name: String, _ channel: Int, _ delta: Float) {
      var c = shaderEditColors[name] ?? (0.8, 0.8, 0.8, 1.0)
      func ch(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0.8 }
      c = (ch(c.0), ch(c.1), ch(c.2), ch(c.3))
      switch channel {
      case 0: c.0 = min(max(c.0 + delta, 0), 1)
      case 1: c.1 = min(max(c.1 + delta, 0), 1)
      default: c.2 = min(max(c.2 + delta, 0), 1)
      }
      shaderEditColors[name] = c
      pushStudioColor(name)
    }

    private func nudgeStudioFloat(_ name: String, _ delta: Float, _ minV: Float, _ maxV: Float) {
      let cur = shaderEditFloats[name] ?? 0
      let base = cur.isFinite ? cur : minV
      let next = min(max(base + delta, minV), maxV)
      shaderEditFloats[name] = next
      pushStudioFloat(name)
    }

    @ViewBuilder private func studioPropEditor(index: Int) -> some View {
      studioPropStepper(index: index)
    }

    private func pushStudioFloat(_ sock: String) {
      guard !shaderSelectedName.isEmpty, let v = shaderEditFloats[sock] else { return }
      shaderSelectedName.withCString { n in
        sock.withCString { s in WM_IOS_immersive_shader_set_socket_float(n, s, v) }
      }
    }

    private func pushStudioColor(_ sock: String) {
      guard !shaderSelectedName.isEmpty, let c = shaderEditColors[sock] else { return }
      shaderSelectedName.withCString { n in
        sock.withCString { s in
          WM_IOS_immersive_shader_set_socket_rgba(n, s, c.0, c.1, c.2, c.3)
        }
      }
    }

    private func legendDot(_ color: UIColor, _ title: String) -> some View {
      HStack(spacing: 4) {
        Circle()
          .fill(Color(uiColor: color))
          .frame(width: 10, height: 10)
        Text(title).font(.caption2)
      }
    }

    @ViewBuilder private var animTab: some View {
      Text("フレーム \(Int(animFrame.rounded()))  (\(Int(animFrameStart))…\(Int(animFrameEnd)))")
        .font(.caption)
      Slider(
        value: Binding(
          get: { animFrame },
          set: {
            animFrame = $0
            sliderEditing = true
          }),
        in: animFrameStart...max(animFrameEnd, animFrameStart + 1),
        step: 1,
        onEditingChanged: { editing in
          sliderEditing = editing
          if !editing {
            WM_IOS_immersive_anim_set_frame(Int32(animFrame.rounded()))
          }
        })
      .disabled(mode != 4)

      HStack(spacing: 6) {
        frameChip("◀◀") { WM_IOS_immersive_anim_frame_delta(-10) }
        frameChip("◀") { WM_IOS_immersive_anim_frame_delta(-1) }
        frameChip("▶") { WM_IOS_immersive_anim_frame_delta(1) }
        frameChip("▶▶") { WM_IOS_immersive_anim_frame_delta(10) }
        frameChip("▶︎") { WM_IOS_immersive_anim_play() }
        frameChip("■") { WM_IOS_immersive_anim_stop() }
      }

      if animKeyFrames.isEmpty {
        Text(mode == 4 ? "キーなし" : "Anim モードで編集")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      else {
        Text("キー: " + animKeyFrames.prefix(10).map(String.init).joined(separator: ", "))
          .font(.caption2)
          .lineLimit(2)
      }

      HStack(spacing: 8) {
        Button("キー登録") { WM_IOS_immersive_anim_insert_key() }
          .buttonStyle(.borderedProminent)
          .tint(.yellow.opacity(0.9))
          .disabled(mode != 4)
        Button("キー解除") { WM_IOS_immersive_anim_delete_key() }
          .buttonStyle(.borderedProminent)
          .tint(.red.opacity(0.75))
          .disabled(mode != 4)
      }

      Button("視点→カメラにキー") { WM_IOS_immersive_camera_key_from_viewer() }
        .buttonStyle(.borderedProminent)
        .tint(.cyan.opacity(0.9))
        .frame(maxWidth: .infinity, minHeight: 40)
        .disabled(mode != 4)

      HStack(spacing: 8) {
        targetChip("ボーン", 0)
        targetChip("オブジェクト", 1)
      }
      .disabled(mode != 4)
      .opacity(mode == 4 ? 1 : 0.45)

      if animTargetMode == 0 {
        HStack(spacing: 6) {
          xformChip("回転", 0)
          xformChip("移動", 1)
          xformChip("スケール", 2)
        }
        .disabled(mode != 4)
        Text(animActiveBone.isEmpty ? "ボーン: （未選択）" : "ボーン: \(animActiveBone)")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      if mode != 4 {
        Button("Anim モードへ") {
          mode = 4
          WM_IOS_immersive_hand_menu_set_mode(4)
        }
        .buttonStyle(.borderedProminent)
        .tint(.pink.opacity(0.9))
        .frame(maxWidth: .infinity, minHeight: 40)
      }
    }

    @ViewBuilder private var spaceTab: some View {
      Text("モデル原点")
        .font(.caption.weight(.semibold))
      placementSlider("左右", $originX, -3...3) { String(format: "%+.2f m", $0) }
      placementSlider("高さ", $originHeight, -1...3) { String(format: "%+.2f m", $0) }
      placementSlider("奥行き", $originDepth, -3...1) { String(format: "%+.2f m", $0) }
      Button("床に戻す") {
        originX = 0
        originHeight = 0
        originDepth = 0
        publishPlacement()
      }
      .buttonStyle(.bordered)
      .frame(maxWidth: .infinity, minHeight: 36)

      Divider()

      Text("体験シェア")
        .font(.caption.weight(.semibold))
      Text(multiuserStatus)
        .font(.caption2)
        .lineLimit(2)
      HStack(spacing: 6) {
        Button("Host") {
          _ = BlenderImmersiveMultiuserSession.shared.hostSession(displayName: nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(multiuserActive && multiuserHost ? .green : .gray.opacity(0.45))
        .disabled(multiuserActive)
        Button("Join") {
          _ = BlenderImmersiveMultiuserSession.shared.joinSession(displayName: nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(multiuserActive && !multiuserHost ? .blue : .gray.opacity(0.45))
        .disabled(multiuserActive)
        Button("Leave") {
          BlenderImmersiveMultiuserSession.shared.leaveSession()
          BlenderImmersiveState.shared.sharedAnchor?.stop()
        }
        .buttonStyle(.bordered)
        .disabled(!multiuserActive)
      }

      Text(anchorStatus)
        .font(.caption2)
        .lineLimit(2)
      HStack(spacing: 6) {
        Button("原点固定") {
          Task { _ = await BlenderImmersiveState.shared.sharedAnchor?.placeHostOrigin() }
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(!(multiuserActive && multiuserHost))
        Button("ここに合わせる") {
          Task { await BlenderImmersiveState.shared.sharedAnchor?.alignHere() }
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .disabled(!multiuserActive || multiuserHost)
      }
    }

    private func placementSlider(
      _ title: String,
      _ value: Binding<Float>,
      _ range: ClosedRange<Float>,
      text: @escaping (Float) -> String
    ) -> some View {
      HStack {
        Text(title).frame(width: 44, alignment: .leading).font(.caption2)
        Slider(
          value: Binding(
            get: { value.wrappedValue },
            set: {
              value.wrappedValue = $0
              publishPlacement()
            }),
          in: range,
          step: 0.05)
        Text(text(value.wrappedValue))
          .font(.caption2.monospacedDigit())
          .frame(width: 64, alignment: .trailing)
      }
    }

    private func publishPlacement() {
      BlenderImmersiveState.shared.updatePlacement(
        x: originX, y: originHeight, z: originDepth)
      NotificationCenter.default.post(name: .blenderImmersivePlacementChanged, object: nil)
    }

    private func modeChip(_ title: String, _ value: Int) -> some View {
      Button(title) {
        mode = value
        WM_IOS_immersive_hand_menu_set_mode(Int32(value))
      }
      .buttonStyle(.borderedProminent)
      .tint(mode == value ? .blue : .gray.opacity(0.4))
      .controlSize(.small)
      .frame(minHeight: 34)
    }

    private func frameChip(_ title: String, _ action: @escaping () -> Void) -> some View {
      Button(title, action: action)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(minWidth: 36, minHeight: 36)
    }

    private func targetChip(_ title: String, _ value: Int) -> some View {
      Button(title) {
        animTargetMode = value
        WM_IOS_immersive_anim_set_target(Int32(value))
      }
      .buttonStyle(.borderedProminent)
      .tint(animTargetMode == value ? .mint : .gray.opacity(0.4))
      .controlSize(.small)
      .frame(maxWidth: .infinity, minHeight: 36)
    }

    private func xformChip(_ title: String, _ value: Int) -> some View {
      Button(title) {
        poseXformMode = value
        WM_IOS_immersive_anim_set_pose_xform(Int32(value))
      }
      .buttonStyle(.borderedProminent)
      .tint(poseXformMode == value ? .pink.opacity(0.95) : .gray.opacity(0.4))
      .controlSize(.small)
      .frame(minHeight: 36)
    }

    private func refreshAll() {
      syncHandMenu()
      syncAnim()
      refreshMultiuser()
      refreshAnchor()
      immersiveActive = BlenderImmersiveState.shared.isActive
      originX = BlenderImmersiveState.shared.placementX
      originHeight = BlenderImmersiveState.shared.placementY
      originDepth = BlenderImmersiveState.shared.placementZ
    }

    private func syncHandMenu() {
      let s = BlenderImmersiveState.shared
      if mode == s.handMenuMode && brushKind == s.handMenuBrushKind
        && abs(strength - s.handMenuStrength) < 0.0005 && abs(radius - s.handMenuRadius) < 0.0005
        && brushLabel == s.handMenuBrushLabel && dyntopoOn == s.handMenuDyntopo
      {
        return
      }
      mode = s.handMenuMode
      brushKind = s.handMenuBrushKind
      strength = s.handMenuStrength
      radius = s.handMenuRadius
      brushLabel = s.handMenuBrushLabel
      dyntopoOn = s.handMenuDyntopo
    }

    private func syncAnim() {
      let s = BlenderImmersiveState.shared
      poseXformMode = s.animPoseXformMode
      animTargetMode = s.animTargetMode
      animActiveBone = s.animActiveBone
      animKeyFrames = s.animKeyFrames
      animFrameStart = Float(s.animFrameStart)
      animFrameEnd = Float(s.animFrameEnd)
      if !sliderEditing {
        animFrame = Float(s.animFrame)
      }
    }

    private func refreshMultiuser() {
      multiuserStatus = BlenderImmersiveMultiuserSession.shared.statusCopy()
      multiuserActive = BlenderImmersiveMultiuserSession.shared.isActive
      multiuserHost = BlenderImmersiveMultiuserSession.shared.isHost
    }

    private func refreshAnchor() {
      if let anchor = BlenderImmersiveState.shared.sharedAnchor {
        anchorStatus = anchor.statusText
      }
    }
  }

#endif
