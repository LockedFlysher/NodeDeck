#!/usr/bin/env bash
# Compile headless zero-Qt nodedeck-host directly from third_party/sunshine source on Linux.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/sunshine"
BUILD_DIR="$ROOT/.build/sunshine-linux"
OUT_DIR="$ROOT/.build/host-linux"

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  echo "ERROR: third_party/sunshine submodule not initialized. Run: git submodule update --init --recursive" >&2
  exit 1
fi

CUDA_FLAG="OFF"
if command -v nvcc >/dev/null 2>&1; then
  CUDA_FLAG="ON"
fi

echo "=== Configuring headless zero-Qt Sunshine host from source (Linux, CUDA=$CUDA_FLAG) ==="
cmake -S "$SRC" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DSUNSHINE_ENABLE_TRAY=OFF \
  -DBUILD_DOCS=OFF \
  -DBUILD_TESTS=OFF \
  -DSUNSHINE_ENABLE_CUDA="$CUDA_FLAG" \
  -DCUDA_FAIL_ON_MISSING=OFF \
  -DNPM=/usr/bin/true \
  -DSUNSHINE_PUBLISHER_NAME="NodeDeck" \
  -DSUNSHINE_PUBLISHER_WEBSITE="https://github.com/LockedFlysher/NodeDeck" \
  -DSUNSHINE_PUBLISHER_ISSUE_URL="https://github.com/LockedFlysher/NodeDeck/issues"

echo "=== Building headless nodedeck-host target ==="
cmake --build "$BUILD_DIR" --target sunshine -j "$(nproc)"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/bin"
cp "$BUILD_DIR/sunshine" "$OUT_DIR/bin/nodedeck-host"
chmod 0755 "$OUT_DIR/bin/nodedeck-host"

echo "=== Built headless Linux nodedeck-host successfully ==="
ls -lh "$OUT_DIR/bin/nodedeck-host"
"$OUT_DIR/bin/nodedeck-host" --version || true
