#!/usr/bin/env bash
# Build minimal self-contained static FFmpeg (libavcodec.a, libavutil.a, libswscale.a)
# for NodeDeck Linux streaming client (H.264 / HEVC / AV1 + VAAPI + CUDA/NVDEC via dlopen).
# Eliminates all distro-volatile libavcodecXX / libavutilXX / libswscaleXX SONAME dependencies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FFMPEG_VER="${FFMPEG_VER:-7.1.1}"
NV_HEADERS_TAG="${NV_HEADERS_TAG:-n12.2.72.0}"
WORK_DIR="${WORK_DIR:-$ROOT/.build/ffmpeg-work}"
PREFIX="${PREFIX:-$ROOT/.build/ffmpeg-static}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

if [[ -f "$PREFIX/lib/libavcodec.a" && -f "$PREFIX/lib/libavutil.a" && -f "$PREFIX/lib/libswscale.a" && "${FORCE_REBUILD:-0}" != "1" ]]; then
  echo "Static FFmpeg already built at $PREFIX (set FORCE_REBUILD=1 to rebuild)."
  exit 0
fi

mkdir -p "$WORK_DIR" "$PREFIX"

# Ensure nasm is available (without requiring sudo if missing)
if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
  TOOLS_DIR="$WORK_DIR/tools"
  mkdir -p "$TOOLS_DIR"
  if command -v apt-get >/dev/null 2>&1 && command -v dpkg-deb >/dev/null 2>&1; then
    echo "=== Fetching nasm locally (no sudo needed) ==="
    (cd "$TOOLS_DIR" && apt-get download nasm >/dev/null 2>&1 && dpkg-deb -x nasm_*.deb "$TOOLS_DIR/root") || true
    export PATH="$TOOLS_DIR/root/usr/bin:$PATH"
  fi
fi

# 1. Install ffnvcodec (header-only dynamic loader for NVIDIA CUDA/NVDEC — zero libcuda link dep)
NV_DIR="$WORK_DIR/nv-codec-headers"
if [[ ! -f "$PREFIX/lib/pkgconfig/ffnvcodec.pc" ]]; then
  echo "=== Fetching nv-codec-headers ($NV_HEADERS_TAG) ==="
  rm -rf "$NV_DIR"
  curl -fsSL "https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/${NV_HEADERS_TAG}.tar.gz" \
    | tar -xz -C "$WORK_DIR"
  mv "$WORK_DIR"/nv-codec-headers-* "$NV_DIR"
  make -C "$NV_DIR" PREFIX="$PREFIX" install
fi

# 2. Fetch FFmpeg source tarball
FF_SRC="$WORK_DIR/ffmpeg-${FFMPEG_VER}"
if [[ ! -d "$FF_SRC" ]]; then
  echo "=== Fetching FFmpeg ${FFMPEG_VER} ==="
  curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz" \
    | tar -xJ -C "$WORK_DIR"
fi

# 3. Configure minimal decoder-only static FFmpeg
echo "=== Building minimal static FFmpeg ${FFMPEG_VER} into $PREFIX ==="
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

ASM_FLAG=""
if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
  echo "WARNING: nasm/yasm not found; disabling x86asm"
  ASM_FLAG="--disable-x86asm"
fi

cd "$FF_SRC"
make distclean >/dev/null 2>&1 || true

./configure \
  --prefix="$PREFIX" \
  --pkg-config-flags="--static" \
  --extra-cflags="-O2 -fPIC" \
  --enable-static \
  --disable-shared \
  --disable-programs \
  --disable-doc \
  --disable-debug \
  --disable-everything \
  --disable-avdevice \
  --disable-avformat \
  --disable-avfilter \
  --disable-swresample \
  --disable-postproc \
  --disable-network \
  --disable-autodetect \
  --enable-avcodec \
  --enable-avutil \
  --enable-swscale \
  --enable-zlib \
  --enable-vaapi \
  --enable-ffnvcodec \
  --enable-cuda \
  --enable-cuvid \
  --enable-nvdec \
  --enable-decoder=h264,hevc,av1 \
  --enable-parser=h264,hevc,av1 \
  --enable-hwaccel=h264_vaapi,hevc_vaapi,av1_vaapi,h264_nvdec,hevc_nvdec,av1_nvdec \
  $ASM_FLAG

make -j"$JOBS"
make install

echo "=== Built static FFmpeg libraries ==="
ls -lh "$PREFIX/lib/libavcodec.a" "$PREFIX/lib/libavutil.a" "$PREFIX/lib/libswscale.a"
