/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/**
 * Decode Ogg Vorbis to PCM WAV for AVAudioFile (Apple has no Ogg support).
 */

#include "immersive_audio_ogg_to_wav.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(WITH_APPLE_CROSSPLATFORM)

/* Public-domain Ogg Vorbis decoder (Sean Barrett). */
#  include "stb_vorbis.c"

static int write_wav_pcm16(
    const char *wav_path, int channels, int sample_rate, const short *samples, int sample_count)
{
  FILE *out = fopen(wav_path, "wb");
  if (out == NULL) {
    return -1;
  }
  const long data_bytes = (long)sample_count * (long)sizeof(short);
  const int byte_rate = sample_rate * channels * 2;
  const int block_align = channels * 2;
  const long riff_size = 36 + data_bytes;
  unsigned char hdr[44];
  memset(hdr, 0, sizeof(hdr));
  memcpy(hdr + 0, "RIFF", 4);
  hdr[4] = (unsigned char)(riff_size & 255);
  hdr[5] = (unsigned char)((riff_size >> 8) & 255);
  hdr[6] = (unsigned char)((riff_size >> 16) & 255);
  hdr[7] = (unsigned char)((riff_size >> 24) & 255);
  memcpy(hdr + 8, "WAVEfmt ", 8);
  hdr[16] = 16; /* PCM chunk size */
  hdr[20] = 1;  /* PCM format */
  hdr[22] = (unsigned char)(channels & 255);
  hdr[24] = (unsigned char)(sample_rate & 255);
  hdr[25] = (unsigned char)((sample_rate >> 8) & 255);
  hdr[26] = (unsigned char)((sample_rate >> 16) & 255);
  hdr[27] = (unsigned char)((sample_rate >> 24) & 255);
  hdr[28] = (unsigned char)(byte_rate & 255);
  hdr[29] = (unsigned char)((byte_rate >> 8) & 255);
  hdr[30] = (unsigned char)((byte_rate >> 16) & 255);
  hdr[31] = (unsigned char)((byte_rate >> 24) & 255);
  hdr[32] = (unsigned char)(block_align & 255);
  hdr[34] = 16; /* bits per sample */
  memcpy(hdr + 36, "data", 4);
  hdr[40] = (unsigned char)(data_bytes & 255);
  hdr[41] = (unsigned char)((data_bytes >> 8) & 255);
  hdr[42] = (unsigned char)((data_bytes >> 16) & 255);
  hdr[43] = (unsigned char)((data_bytes >> 24) & 255);

  if (fwrite(hdr, 1, 44, out) != 44) {
    fclose(out);
    remove(wav_path);
    return -2;
  }
  if (fwrite(samples, 1, (size_t)data_bytes, out) != (size_t)data_bytes) {
    fclose(out);
    remove(wav_path);
    return -3;
  }
  fclose(out);
  return 0;
}

int GHOST_immersive_ogg_to_wav(const char *ogg_path, const char *wav_path)
{
  if (ogg_path == NULL || wav_path == NULL || ogg_path[0] == '\0' || wav_path[0] == '\0') {
    return -1;
  }

  int channels = 0;
  int sample_rate = 0;
  short *output = NULL;
  const int frames = stb_vorbis_decode_filename(ogg_path, &channels, &sample_rate, &output);
  if (frames <= 0 || output == NULL || channels < 1 || sample_rate < 1) {
    free(output);
    return -2;
  }

  const int sample_count = frames * channels;
  const int rc = write_wav_pcm16(wav_path, channels, sample_rate, output, sample_count);
  free(output);
  return rc;
}

int GHOST_immersive_file_looks_like_ogg(const char *path)
{
  if (path == NULL || path[0] == '\0') {
    return 0;
  }
  FILE *f = fopen(path, "rb");
  if (f == NULL) {
    return 0;
  }
  char magic[4] = {0};
  const size_t n = fread(magic, 1, 4, f);
  fclose(f);
  return (n == 4 && memcmp(magic, "OggS", 4) == 0) ? 1 : 0;
}

#else

int GHOST_immersive_ogg_to_wav(const char *ogg_path, const char *wav_path)
{
  (void)ogg_path;
  (void)wav_path;
  return -100;
}

int GHOST_immersive_file_looks_like_ogg(const char *path)
{
  (void)path;
  return 0;
}

#endif
