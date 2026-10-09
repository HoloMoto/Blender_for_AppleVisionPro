#!/usr/bin/env bash
# Pre-build libmpdec objects then finish Python for Apple cross-compiles.
# Usage: python_cross_build.sh <python_src_dir> <jobs>
set -euo pipefail
PY_SRC="${1:?python src dir}"
JOBS="${2:-1}"
cd "${PY_SRC}"
for o in basearith constants context convolute crt difradix2 fnt fourstep io mpalloc mpdecimal numbertheory sixstep transpose; do
  make -j1 "Modules/_decimal/libmpdec/${o}.o" || true
done
ar rcs Modules/_decimal/libmpdec/libmpdec.a \
  Modules/_decimal/libmpdec/basearith.o \
  Modules/_decimal/libmpdec/constants.o \
  Modules/_decimal/libmpdec/context.o \
  Modules/_decimal/libmpdec/convolute.o \
  Modules/_decimal/libmpdec/crt.o \
  Modules/_decimal/libmpdec/difradix2.o \
  Modules/_decimal/libmpdec/fnt.o \
  Modules/_decimal/libmpdec/fourstep.o \
  Modules/_decimal/libmpdec/io.o \
  Modules/_decimal/libmpdec/mpalloc.o \
  Modules/_decimal/libmpdec/mpdecimal.o \
  Modules/_decimal/libmpdec/numbertheory.o \
  Modules/_decimal/libmpdec/sixstep.o \
  Modules/_decimal/libmpdec/transpose.o
make -j"${JOBS}"
