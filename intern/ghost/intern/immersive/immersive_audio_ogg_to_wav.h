/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Convert an Ogg Vorbis file to 16-bit PCM WAV.
 * \return 0 on success, negative on failure.
 */
int GHOST_immersive_ogg_to_wav(const char *ogg_path, const char *wav_path);

/** True if the file starts with the OggS magic (regardless of extension). */
int GHOST_immersive_file_looks_like_ogg(const char *path);

#ifdef __cplusplus
}
#endif
