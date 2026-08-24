/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * iOS builds force WITH_USD=OFF, but the host makesrna used for codegen may
 * still emit references to RNA_USDHook from rna_ui / rna_userdef. Provide a
 * minimal definition so the app links. VisionOS/macOS paths are unaffected
 * (this file is only compiled when WITH_APPLE_CROSSPLATFORM && !WITH_USD).
 */

struct StructRNA {
  void *pad[64];
};

StructRNA RNA_USDHook{};
