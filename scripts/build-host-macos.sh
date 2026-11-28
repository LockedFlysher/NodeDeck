#!/usr/bin/env zsh
# Compile headless zero-Qt nodedeck-host directly from third_party/sunshine source on macOS.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/sunshine"
BUILD_DIR="$ROOT/.build/sunshine-macos"
OUT_DIR="$ROOT/.build/host"

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  echo "ERROR: third_party/sunshine submodule not initialized. Run: git submodule update --init --recursive" >&2
  exit 1
fi

BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
OPENSSL_ROOT="$BREW_PREFIX/opt/openssl@3"
OPUS_ROOT="$BREW_PREFIX/opt/opus"
ICU_ROOT="$(brew --prefix icu4c 2>/dev/null || ls -d "$BREW_PREFIX"/opt/icu4c* 2>/dev/null | head -n 1 || true)"
export PKG_CONFIG_PATH="$OPENSSL_ROOT/lib/pkgconfig:$OPUS_ROOT/lib/pkgconfig:$BREW_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

OPENSSL_SHIM="$BUILD_DIR/openssl3-shim"
mkdir -p "$OPENSSL_SHIM"
ln -sfn "$OPENSSL_ROOT/include/openssl" "$OPENSSL_SHIM/openssl"

EXTRA_CMAKE_ARGS=(
  "-DCMAKE_CXX_FLAGS=-I$OPENSSL_SHIM"
  "-DCMAKE_C_FLAGS=-I$OPENSSL_SHIM"
  "-DOPENSSL_USE_STATIC_LIBS=TRUE"
)
if [[ -f "$OPENSSL_ROOT/lib/libssl.a" && -f "$OPENSSL_ROOT/lib/libcrypto.a" ]]; then
  EXTRA_CMAKE_ARGS+=(
    "-DOPENSSL_SSL_LIBRARY=$OPENSSL_ROOT/lib/libssl.a"
    "-DOPENSSL_CRYPTO_LIBRARY=$OPENSSL_ROOT/lib/libcrypto.a"
  )
fi
if [[ -n "$ICU_ROOT" && -d "$ICU_ROOT/lib" ]]; then
  EXTRA_CMAKE_ARGS+=("-DCMAKE_EXE_LINKER_FLAGS=-L$ICU_ROOT/lib")
fi

echo "=== Configuring headless zero-Qt Sunshine host from source (macOS) ==="
cmake -S "$SRC" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT" \
  -DSUNSHINE_ENABLE_TRAY=OFF \
  -DBUILD_DOCS=OFF \
  -DBUILD_TESTS=OFF \
  -DBOOST_USE_STATIC=ON \
  -DOPUS_USE_STATIC=ON \
  -DNPM=/usr/bin/true \
  -DSUNSHINE_PUBLISHER_NAME="NodeDeck" \
  -DSUNSHINE_PUBLISHER_WEBSITE="https://github.com/LockedFlysher/NodeDeck" \
  -DSUNSHINE_PUBLISHER_ISSUE_URL="https://github.com/LockedFlysher/NodeDeck/issues" \
  "${EXTRA_CMAKE_ARGS[@]}"

echo "=== Building headless nodedeck-host target ==="
cmake --build "$BUILD_DIR" --target sunshine -j "$(sysctl -n hw.ncpu)"

rm -rf "$OUT_DIR"
HOST_APP="$OUT_DIR/NodeDeckHost.app"
OUT_BIN="$HOST_APP/Contents/MacOS/nodedeck-host"
OUT_LIB="$HOST_APP/Contents/MacOS/host-lib"
OUT_ASSETS="$HOST_APP/Contents/Resources/assets"
mkdir -p "$(dirname "$OUT_BIN")" "$OUT_LIB" "$OUT_ASSETS"

BUILT_BIN="$BUILD_DIR/Sunshine.app/Contents/MacOS/Sunshine"
[[ -x "$BUILT_BIN" ]] || BUILT_BIN="$BUILD_DIR/sunshine"
cp "$BUILT_BIN" "$OUT_BIN"
chmod 0755 "$OUT_BIN"
strip -x "$OUT_BIN" 2>/dev/null || true

# Copy minimal runtime assets (no web UI, no Qt)
if [[ -d "$BUILD_DIR/Sunshine.app/Contents/Resources/assets" ]]; then
  cp -R "$BUILD_DIR/Sunshine.app/Contents/Resources/assets/"* "$OUT_ASSETS/" 2>/dev/null || true
fi
if [[ -f "$SRC/src_assets/macos/assets/apps.json" ]]; then
  cp "$SRC/src_assets/macos/assets/apps.json" "$OUT_ASSETS/apps.json"
fi

# Minimal background-agent Info.plist so macOS UserNotifications & TCC Screen Recording have a valid bundle identity (LSUIElement=true => no Dock icon)
cat > "$HOST_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>nodedeck-host</string>
    <key>CFBundleIdentifier</key>
    <string>com.nodedeck.host</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>NodeDeck Host</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>2.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>NodeDeck Host captures the local display to stream it to authorized NodeDeck clients.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>NodeDeck Host captures system audio for low-latency desktop streaming.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>NodeDeck Host listens for encrypted remote desktop connections on the local or overlay network.</string>
</dict>
</plist>
EOF

# Relocate any non-system dylibs (e.g. miniupnpc/icu) into host-lib so the binary is 100% portable
relocate_deps() {
  local target="$1"
  local dep
  for dep in $(otool -L "$target" | awk 'NR>1 {print $1}'); do
    case "$dep" in
      /System/*|/usr/lib/*|@executable_path/*|@loader_path/*|@rpath/*)
        continue
        ;;
      *)
        if [[ -f "$dep" ]]; then
          local base="$(basename "$dep")"
          if [[ ! -f "$OUT_LIB/$base" ]]; then
            cp -L "$dep" "$OUT_LIB/$base"
            chmod 0644 "$OUT_LIB/$base"
            install_name_tool -id "@loader_path/$base" "$OUT_LIB/$base" 2>/dev/null || true
            relocate_deps "$OUT_LIB/$base"
          fi
          if [[ "$target" == "$OUT_BIN" ]]; then
            install_name_tool -change "$dep" "@executable_path/host-lib/$base" "$target"
          else
            install_name_tool -change "$dep" "@loader_path/$base" "$target"
          fi
        fi
        ;;
    esac
  done
}

relocate_deps "$OUT_BIN"
codesign --force --sign - "$OUT_LIB"/*.dylib 2>/dev/null || true
codesign --force --deep --sign - "$HOST_APP"

echo "=== Built headless macOS nodedeck-host successfully ==="
ls -lh "$OUT_BIN"
du -sh "$HOST_APP"
otool -L "$OUT_BIN"
"$OUT_BIN" --version || true
