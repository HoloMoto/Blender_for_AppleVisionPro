/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * SwiftUI application entry for visionOS.
 * Hosts the existing UIKit Blender UI and declares ImmersiveSpace for RealityKit.
 * Studio panel opens as its own WindowGroup while Immersive Space is active.
 */

import SwiftUI
import UIKit

#if os(visionOS)

  /* GHOST_SystemIOS.mm: kicks off Blender's main initialization (main_ios_callback).
   * Under the SwiftUI lifecycle the Info.plist scene delegate (IOSSceneDelegate)
   * never connects, so Blender must be started explicitly from here. */
  @_silgen_name("GHOST_IOS_StartBlenderFromSwiftUI")
  private func GHOST_IOS_StartBlenderFromSwiftUI()

  @main
  struct BlenderVisionApp: App {
    @UIApplicationDelegateAdaptor(BlenderUIKitAppDelegate.self) private var appDelegate
    @State private var immersionStyle: ImmersionStyle = .mixed

    init() {
      /* Pure Swift only — do not call into GHOST/C++ here.
       * TestFlight often kills the process before ObjC++ is safe; if Documents
       * never appears, the crash was before this bootstrap completed. */
      BlenderIOSDiagnosticLog.installSwiftBootstrap()
      BlenderIOSDiagnosticLog.bootSwiftOnly("BlenderVisionApp init")
    }

    var body: some Scene {
      /* Main 2D/3D Blender viewport host — GHOST windows cover this after start. */
      WindowGroup {
        BlenderUIKitRootRepresentable()
          .ignoresSafeArea()
          /* Coordinator only. All controls stay in Blender's existing
           * 3D Viewport > Immersive N-panel. */
          .background(BlenderImmersiveCoordinator())
      }

      /* Immersive-only studio panel — auto-opens with Immersive Space. */
      WindowGroup(id: BlenderStudioPanelWindowID) {
        BlenderImmersiveViewportPanel()
      }
      .defaultSize(width: 380, height: 520)
      .windowResizability(.automatic)

      /* Immersive content stays lazy: the view body runs when the space opens,
       * not during the initial WindowGroup paint. */
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
      BlenderIOSDiagnosticLog.bootSwiftOnly("UIApplication didFinishLaunching begin")
      BlenderIOSDiagnosticLog.installCHandlers()
      BlenderIOSDiagnosticLog.boot("swift: UIApplication didFinishLaunching")
      return true
    }
  }

  /// Host view controller: starts Blender once its window is attached to a scene.
  final class BlenderHostViewController: UIViewController {
    private var startedBlender = false
    private let statusLabel = UILabel()

    override func viewDidLoad() {
      super.viewDidLoad()
      BlenderIOSDiagnosticLog.boot("swift: BlenderHostViewController viewDidLoad")
      view.backgroundColor = .black
      statusLabel.text = "Blender を起動しています…"
      statusLabel.textColor = .white
      statusLabel.textAlignment = .center
      statusLabel.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(statusLabel)
      NSLayoutConstraint.activate([
        statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      ])
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      BlenderIOSDiagnosticLog.boot("swift: BlenderHostViewController viewDidAppear")
      /* Give visionOS launch transition + first compositor frames time to land
       * before Blender monopolizes the main thread (TestFlight watchdog). */
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
        self?.startBlenderWhenSceneReady()
      }
    }

    private func startBlenderWhenSceneReady() {
      guard !startedBlender else { return }
      if view.window?.windowScene != nil {
        startedBlender = true
        BlenderIOSDiagnosticLog.boot("swift: calling GHOST_IOS_StartBlenderFromSwiftUI")
        /* One more main-queue hop so the status label can paint first. */
        DispatchQueue.main.async {
          GHOST_IOS_StartBlenderFromSwiftUI()
        }
      }
      else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
          self?.startBlenderWhenSceneReady()
        }
      }
    }

  }

  /// Placeholder root until the UIKit MTKView hierarchy is attached into the WindowGroup.
  struct BlenderUIKitRootRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
      /* Do not put 「合わせ」 only on this host — GHOST covers it after start. */
      return BlenderHostViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
  }

  /// UI-free coordinator. User controls live in Blender's existing
  /// 3D Viewport > Immersive N-panel, not in another SwiftUI overlay/window.
  private struct BlenderImmersiveCoordinator: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
      Color.clear
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
      .onReceive(NotificationCenter.default.publisher(for: .blenderOpenImmersiveSpace)) { _ in
        Task {
          let result = await openImmersiveSpace(id: BlenderImmersiveSpaceID)
          if case .opened = result {
            BlenderImmersiveState.shared.markActive(true)
          }
          else {
            BlenderImmersiveState.shared.markActive(false)
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
