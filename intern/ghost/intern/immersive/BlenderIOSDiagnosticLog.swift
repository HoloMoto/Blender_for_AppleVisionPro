/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Swift-side hooks for Documents diagnostic logging (no USB / no TestFlight feedback).
 *
 * Important: the first boot line MUST be pure Swift (no @_silgen_name / C).
 * TestFlight launch crashes often happen before ObjC++ is safe; if Documents
 * never appears in Files, the process died before any successful write.
 */

import Foundation

#if os(visionOS)

  enum BlenderIOSDiagnosticLog {
    @_silgen_name("GHOST_IOS_diag_log")
    private static func ghostDiagLog(_ message: UnsafePointer<CChar>)

    @_silgen_name("GHOST_IOS_diag_install_handlers")
    private static func ghostDiagInstallHandlers()

    @_silgen_name("GHOST_IOS_diag_write_readme")
    private static func ghostDiagWriteReadme()

    private static let bootFileName = "boot.log"
    private static let startupFileName = "startup.log"

    /** Pure-Swift write — safe before any GHOST/C++ entry. */
    static func bootSwiftOnly(_ message: String) {
      append(to: bootFileName, message: "swift-only: \(message)")
      append(to: startupFileName, message: "swift-only: \(message)")
    }

    static func boot(_ message: String) {
      bootSwiftOnly(message)
      message.withCString { ghostDiagLog($0) }
    }

    /**
     * Call as early as possible from App.init — Swift only, no C bridge.
     * C handlers are installed later from didFinishLaunching.
     */
    static func installSwiftBootstrap() {
      bootSwiftOnly("App.init bootstrap begin")
      writeReadmeSwift()
      bootSwiftOnly("App.init bootstrap Documents ready")
    }

    static func installCHandlers() {
      bootSwiftOnly("installCHandlers begin")
      ghostDiagWriteReadme()
      ghostDiagInstallHandlers()
      boot("swift: diagnostic C handlers ready")
    }

    private static func documentsURL() -> URL? {
      FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static func append(to filename: String, message: String) {
      guard let dir = documentsURL() else { return }
      let fm = FileManager.default
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let url = dir.appendingPathComponent(filename)
      let stamp = ISO8601DateFormatter().string(from: Date())
      let line = "\(stamp) \(message)\n"
      guard let data = line.data(using: .utf8) else { return }
      if !fm.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: nil)
      }
      else if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.synchronize()
      }
      /* tmp fallback so we can still see crumbs if Documents is blocked. */
      let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
      if !fm.fileExists(atPath: tmp.path) {
        fm.createFile(atPath: tmp.path, contents: data, attributes: nil)
      }
      else if let handle = try? FileHandle(forWritingTo: tmp) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.synchronize()
      }
    }

    private static func writeReadmeSwift() {
      append(
        to: "README-logs.txt",
        message:
          "Blender visionOS diagnostic logs (TestFlight).\n"
          + "premain.log = dyld constructor (before C++/Swift)\n"
          + "boot.log = Swift App.init timeline\n"
          + "startup.log = launch timeline\n"
          + "ios_crash.log = last fatal error\n"
          + "After a crash, open Files > On My Vision Pro > Blender and share these files.\n"
          + "If ONLY premain.log exists: crash during C++ static init / before App.init.\n"
          + "If no files at all: died in dyld (missing framework) before constructors.\n")
    }
  }

#endif
