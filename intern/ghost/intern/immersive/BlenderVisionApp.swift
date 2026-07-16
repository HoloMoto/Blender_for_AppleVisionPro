/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * SwiftUI application entry for visionOS.
 * Hosts the existing UIKit Blender UI and declares ImmersiveSpace for RealityKit.
 */

import SwiftUI
import UIKit

#if os(visionOS)

  @main
  struct BlenderVisionApp: App {
    @UIApplicationDelegateAdaptor(BlenderUIKitAppDelegate.self) private var appDelegate
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some Scene {
      WindowGroup {
        BlenderUIKitRootRepresentable()
          .ignoresSafeArea()
      }

      ImmersiveSpace(id: BlenderImmersiveSpaceID) {
        BlenderImmersiveSpaceView()
      }
      .immersionStyle(selection: $immersionStyle, in: .mixed, .progressive, .full)
    }
  }

  /// Thin adaptor so SwiftUI owns the process while GHOST's UIKit delegate still runs.
  final class BlenderUIKitAppDelegate: NSObject, UIApplicationDelegate {
    func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
      /* Window / MTKView creation continues through the existing UIKit scene path
       * once Blender finishes GHOST init. */
      return true
    }
  }

  /// Placeholder root until the UIKit MTKView hierarchy is attached into the WindowGroup.
  struct BlenderUIKitRootRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
      let vc = UIViewController()
      vc.view.backgroundColor = .black
      /* Immersive open/dismiss is driven by notifications from GHOST. */
      let host = UIHostingController(rootView: BlenderImmersiveLauncher())
      host.view.backgroundColor = .clear
      vc.addChild(host)
      host.view.translatesAutoresizingMaskIntoConstraints = false
      vc.view.addSubview(host.view)
      NSLayoutConstraint.activate([
        host.view.trailingAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.trailingAnchor),
        host.view.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
        host.view.widthAnchor.constraint(equalToConstant: 1),
        host.view.heightAnchor.constraint(equalToConstant: 1),
      ])
      host.didMove(toParent: vc)
      return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
  }

  /// Hidden launcher that can call openImmersiveSpace / dismissImmersiveSpace.
  struct BlenderImmersiveLauncher: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .onReceive(NotificationCenter.default.publisher(for: .blenderOpenImmersiveSpace)) { _ in
          Task {
            let result = await openImmersiveSpace(id: BlenderImmersiveSpaceID)
            switch result {
            case .opened:
              BlenderImmersiveState.shared.markActive(true)
            default:
              BlenderImmersiveState.shared.markActive(false)
              print("[immersive] openImmersiveSpace failed: \(String(describing: result))")
            }
          }
        }
        .onReceive(NotificationCenter.default.publisher(for: .blenderDismissImmersiveSpace)) { _ in
          Task {
            await dismissImmersiveSpace()
            BlenderImmersiveState.shared.markActive(false)
          }
        }
    }
  }

#endif
