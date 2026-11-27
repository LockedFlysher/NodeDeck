#!/usr/bin/env bash
# Build self-contained static SDL2 (libSDL2.a) with runtime dlopen for X11, Wayland & PulseAudio.
# Eliminates the external libsdl2-2.0-0 runtime package dependency (and Ubuntu's libdecor/libXss/libsamplerate chain).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDL_VER="${SDL_VER:-2.30.11}"
WORK_DIR="${WORK_DIR:-$ROOT/.build/sdl2-work}"
PREFIX="${PREFIX:-$ROOT/.build/sdl2-static}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

if [[ -f "$PREFIX/lib/libSDL2.a" && -f "$PREFIX/include/SDL2/SDL.h" && "${FORCE_REBUILD:-0}" != "1" ]]; then
  echo "Static SDL2 already built at $PREFIX (set FORCE_REBUILD=1 to rebuild)."
  exit 0
fi

mkdir -p "$WORK_DIR" "$PREFIX"

SRC_DIR="$WORK_DIR/SDL2-${SDL_VER}"
if [[ ! -d "$SRC_DIR" ]]; then
  echo "=== Fetching SDL2 ${SDL_VER} ==="
  curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL_VER}/SDL2-${SDL_VER}.tar.gz" \
    | tar -xz -C "$WORK_DIR"
fi

BUILD_DIR="$WORK_DIR/build"
rm -rf "$BUILD_DIR"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DSDL_SHARED=OFF \
  -DSDL_STATIC=ON \
  -DSDL_TEST=OFF \
  -DSDL_X11=ON \
  -DSDL_X11_SHARED=ON \
  -DSDL_WAYLAND=ON \
  -DSDL_WAYLAND_SHARED=ON \
  -DSDL_WAYLAND_LIBDECOR=OFF \
  -DSDL_PULSEAUDIO=ON \
  -DSDL_PULSEAUDIO_SHARED=ON \
  -DSDL_PIPEWIRE=OFF \
  -DSDL_ALSA=OFF \
  -DSDL_JACK=OFF \
  -DSDL_SNDIO=OFF \
  -DSDL_KMSDRM=OFF \
  -DSDL_VULKAN=OFF \
  -DSDL_HIDAPI=OFF \
  -DSDL_DBUS=OFF \
  -DSDL_IBUS=OFF \
  -DSDL_FCITX=OFF \
  -DSDL_LIBSAMPLERATE=OFF

cmake --build "$BUILD_DIR" -j"$JOBS"
cmake --install "$BUILD_DIR"

echo "=== Built static SDL2 ==="
ls -lh "$PREFIX/lib/libSDL2.a"
