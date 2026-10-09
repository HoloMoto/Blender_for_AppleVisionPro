/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Muse primary-button pie menu — brush picker when tip is away from the mesh.
 */

import SwiftUI

#if os(visionOS)

  @_silgen_name("WM_IOS_immersive_hand_menu_set_brush")
  private func WM_IOS_immersive_hand_menu_set_brush(
    _ toolId: UnsafePointer<CChar>, _ kind: Int32)

  @_silgen_name("WM_IOS_immersive_hand_menu_set_dyntopo")
  private func WM_IOS_immersive_hand_menu_set_dyntopo(_ enabled: Int32)

  @_silgen_name("WM_IOS_immersive_hand_menu_set_mode")
  private func WM_IOS_immersive_hand_menu_set_mode(_ mode: Int32)

  struct BlenderImmersiveMusePieMenu: View {
    @Binding var visible: Bool
    @State private var brushKind = BlenderImmersiveState.shared.handMenuBrushKind
    @State private var dyntopoOn = BlenderImmersiveState.shared.handMenuDyntopo

    private struct Slice: Identifiable {
      let id: Int
      let title: String
      let kind: Int
      let toolId: String
      let angleDeg: Double
    }

    /* Even ring around the tip — Blender Immersive Muse brush kinds. */
    private let slices: [Slice] = [
      .init(id: 0, title: "Inflate+", kind: 4, toolId: "builtin.brush", angleDeg: -90),
      .init(id: 1, title: "Inflate−", kind: 5, toolId: "builtin.brush", angleDeg: -30),
      .init(id: 2, title: "Smooth", kind: 3, toolId: "builtin.brush", angleDeg: 30),
      .init(id: 3, title: "Grab", kind: 2, toolId: "builtin.brush", angleDeg: 90),
      .init(id: 4, title: "Clay", kind: 1, toolId: "builtin.brush", angleDeg: 150),
      .init(id: 5, title: "Mask", kind: 6, toolId: "builtin.brush", angleDeg: 210),
    ]

    var body: some View {
      ZStack {
        Circle()
          .fill(.ultraThinMaterial)
          .frame(width: 268, height: 268)
          .opacity(0.92)

        ForEach(slices) { slice in
          pieButton(slice)
        }

        VStack(spacing: 6) {
          Button(dyntopoOn ? "Dyntopo●" : "Dyntopo") {
            dyntopoOn.toggle()
            WM_IOS_immersive_hand_menu_set_dyntopo(dyntopoOn ? 1 : 0)
          }
          .buttonStyle(.borderedProminent)
          .tint(dyntopoOn ? .cyan.opacity(0.9) : .gray.opacity(0.5))
          .controlSize(.small)

          Button("閉じる") {
            visible = false
            BlenderImmersiveState.shared.setMusePieVisible(false, x: 0, y: 0, z: 0)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .frame(width: 300, height: 300)
      .opacity(visible ? 1 : 0)
      .allowsHitTesting(visible)
      .onReceive(NotificationCenter.default.publisher(for: .blenderImmersiveHandMenuChanged)) { _ in
        brushKind = BlenderImmersiveState.shared.handMenuBrushKind
        dyntopoOn = BlenderImmersiveState.shared.handMenuDyntopo
      }
    }

    @ViewBuilder
    private func pieButton(_ slice: Slice) -> some View {
      let rad = slice.angleDeg * .pi / 180.0
      let r: CGFloat = 96
      let x = CGFloat(cos(rad)) * r
      let y = CGFloat(sin(rad)) * r
      Button(slice.title) {
        brushKind = slice.kind
        /* Ensure Sculpt sticky mode so Muse tip draws after picking. */
        if BlenderImmersiveState.shared.handMenuMode == 0 {
          WM_IOS_immersive_hand_menu_set_mode(2)
        }
        slice.toolId.withCString {
          WM_IOS_immersive_hand_menu_set_brush($0, Int32(slice.kind))
        }
        visible = false
        BlenderImmersiveState.shared.setMusePieVisible(false, x: 0, y: 0, z: 0)
        let msg = "muse pie pick \(slice.title) kind=\(slice.kind)"
        print("[immersive] \(msg)")
        BlenderIOSDiagnosticLog.bootSwiftOnly(msg)
      }
      .buttonStyle(.borderedProminent)
      .tint(brushKind == slice.kind ? .orange.opacity(0.95) : .gray.opacity(0.55))
      .controlSize(.regular)
      .frame(width: 88, height: 40)
      .offset(x: x, y: y)
    }
  }

#endif
