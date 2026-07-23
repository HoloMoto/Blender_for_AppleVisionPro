/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Immersive hand / ornament menu for Muse sculpt controls.
 * Left-palm attachment + bottom ornament fallback share the same controls.
 */

import SwiftUI

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

  @_silgen_name("WM_IOS_immersive_hand_menu_dismiss")
  private func WM_IOS_immersive_hand_menu_dismiss()

  struct BlenderImmersiveHandMenuPanel: View {
    @Binding var mode: Int
    @Binding var brushKind: Int
    @Binding var strength: Float
    @Binding var radius: Float
    var brushLabel: String
    var compact: Bool = false

    private let brushes: [(title: String, toolId: String, kind: Int)] = [
      ("Inflate+", "builtin_brush.Inflate", 4),
      ("Inflate−", "builtin_brush.Inflate", 5),
      ("Smooth", "builtin_brush.Smooth", 3),
      ("Grab", "builtin_brush.Grab", 2),
    ]

    var body: some View {
      VStack(alignment: .leading, spacing: compact ? 8 : 12) {
        Text(compact ? "ハンドメニュー" : "Immersive コントロール")
          .font(compact ? .caption.weight(.semibold) : .headline)

        HStack(spacing: 6) {
          modeButton("Obj", 0)
          modeButton("Edit", 1)
          modeButton("Sculpt", 2)
          modeButton("VPaint", 3)
        }

        if mode == 2 {
          Text("ブラシ（ペン: 前=切替 / 中=加減算）")
            .font(.caption2)
            .foregroundStyle(.secondary)
          HStack(spacing: 6) {
            ForEach(brushes, id: \.kind) { brush in
              Button(brush.title) {
                brushKind = brush.kind
                brush.toolId.withCString {
                  WM_IOS_immersive_hand_menu_set_brush($0, Int32(brush.kind))
                }
              }
              .buttonStyle(.bordered)
              .tint(brushKind == brush.kind ? .orange : .secondary)
              .controlSize(.small)
            }
          }

          HStack(spacing: 8) {
            Button("加算") {
              brushKind = 4
              "builtin_brush.Inflate".withCString {
                WM_IOS_immersive_hand_menu_set_brush($0, 4)
              }
            }
            .buttonStyle(.borderedProminent)
            .tint(brushKind == 4 ? .green : .gray.opacity(0.4))
            .controlSize(.small)

            Button("減算") {
              brushKind = 5
              "builtin_brush.Inflate".withCString {
                WM_IOS_immersive_hand_menu_set_brush($0, 5)
              }
            }
            .buttonStyle(.borderedProminent)
            .tint(brushKind == 5 ? .red : .gray.opacity(0.4))
            .controlSize(.small)
          }
        }

        if mode == 3 {
          Text("頂点ペイント: tipで塗る / 中ボタン=消去")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text("色はアクティブブラシ色を使用")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        if mode == 2 || mode == 3 {
          VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "Strength %.0f%%  (%@)", strength * 100, brushLabel))
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
          }
        }

        multiuserSection

        Button(role: .destructive) {
          WM_IOS_immersive_hand_menu_dismiss()
        } label: {
          Label("Immersive 終了", systemImage: "xmark.circle")
        }
        .controlSize(.small)
      }
      .padding(compact ? 12 : 16)
      .frame(width: compact ? 300 : 380)
      .glassBackgroundEffect()
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveMultiuserChanged)) { _ in
        multiuserStatus = BlenderImmersiveMultiuserSession.shared.statusCopy()
        multiuserActive = BlenderImmersiveMultiuserSession.shared.isActive
        multiuserHost = BlenderImmersiveMultiuserSession.shared.isHost
      }
      .onAppear {
        multiuserStatus = BlenderImmersiveMultiuserSession.shared.statusCopy()
        multiuserActive = BlenderImmersiveMultiuserSession.shared.isActive
        multiuserHost = BlenderImmersiveMultiuserSession.shared.isHost
      }
    }

    @State private var multiuserStatus = "Idle"
    @State private var multiuserActive = false
    @State private var multiuserHost = false

    @ViewBuilder private var multiuserSection: some View {
      VStack(alignment: .leading, spacing: 6) {
        Text("体験シェア (Multiuser)")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(multiuserStatus)
          .font(.caption2)
          .lineLimit(2)
        HStack(spacing: 6) {
          Button("Host") {
            _ = BlenderImmersiveMultiuserSession.shared.hostSession(displayName: nil)
          }
          .buttonStyle(.borderedProminent)
          .tint(multiuserActive && multiuserHost ? .green : .gray.opacity(0.45))
          .controlSize(.small)
          .disabled(multiuserActive)

          Button("Join") {
            _ = BlenderImmersiveMultiuserSession.shared.joinSession(displayName: nil)
          }
          .buttonStyle(.borderedProminent)
          .tint(multiuserActive && !multiuserHost ? .blue : .gray.opacity(0.45))
          .controlSize(.small)
          .disabled(multiuserActive)

          Button("Leave") {
            BlenderImmersiveMultiuserSession.shared.leaveSession()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(!multiuserActive)
        }
      }
    }

    private func modeButton(_ title: String, _ value: Int) -> some View {
      Button(title) {
        mode = value
        WM_IOS_immersive_hand_menu_set_mode(Int32(value))
      }
      .buttonStyle(.borderedProminent)
      .tint(mode == value ? .blue : .gray.opacity(0.45))
      .controlSize(.small)
    }
  }

#endif
