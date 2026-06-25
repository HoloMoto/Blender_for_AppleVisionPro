/* SPDX-FileCopyrightText: 2019 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#pragma once

/** \file
 * \ingroup editor/io
 */

struct wmOperatorType;

void WM_OT_usd_export(wmOperatorType *ot);
void WM_OT_usd_import(wmOperatorType *ot);
/** Export using operator properties to \a filepath (synchronous, for iOS staging). */
bool ED_usd_export_operator_to_path(struct bContext *C,
                                    struct wmOperator *op,
                                    const char *filepath);
namespace blender::ed::io {
void usd_file_handler_add();
}
