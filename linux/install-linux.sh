#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="/opt/nodedeck"
CC="${CC:-gcc}"

echo "=== Installing Linux build dependencies ==="
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  gcc pkg-config libssl-dev libopus-dev libsdl2-dev \
  libavcodec-dev libavutil-dev libswscale-dev \
  python3-gi gir1.2-gtk-3.0

echo "=== Compiling native nodedeck-stream (moonlight-common-c + FFmpeg + Opus + SDL2) ==="
mkdir -p "$INSTALL_DIR"

COMMON_SRCS=()
for f in "$ROOT"/Sources/CMoonlightCommon/src/*.c; do
  base="$(basename "$f")"
  [[ "$base" == "SunshineCryptoBridge.c" ]] && continue
  COMMON_SRCS+=("$f")
done

ENET_SRCS=(
  "$ROOT/Sources/CMoonlightCommon/enet/callbacks.c"
  "$ROOT/Sources/CMoonlightCommon/enet/compress.c"
  "$ROOT/Sources/CMoonlightCommon/enet/host.c"
  "$ROOT/Sources/CMoonlightCommon/enet/list.c"
  "$ROOT/Sources/CMoonlightCommon/enet/packet.c"
  "$ROOT/Sources/CMoonlightCommon/enet/peer.c"
  "$ROOT/Sources/CMoonlightCommon/enet/protocol.c"
  "$ROOT/Sources/CMoonlightCommon/enet/unix.c"
)

NANORS_SRCS=(
  "$ROOT/Sources/CMoonlightCommon/nanors/rs.c"
  "$ROOT/Sources/CMoonlightCommon/nanors/deps/obl/oblas_common.c"
  "$ROOT/Sources/CMoonlightCommon/nanors/deps/obl/oblas_lite.c"
)

"$CC" -O2 -std=gnu11 \
  -DHAS_FCNTL=1 -DHAS_IOCTL=1 -DHAS_POLL=1 \
  -DHAS_GETNAMEINFO=1 -DHAS_GETADDRINFO=1 -DHAS_GETHOSTBYNAME_R=1 -DHAS_GETHOSTBYADDR_R=1 \
  -DHAS_INET_PTON=1 -DHAS_INET_NTOP=1 -DHAS_MSGHDR_FLAGS=1 -DHAS_SOCKLEN_T=1 -DNDEBUG=1 \
  -I"$ROOT/Sources/CMoonlightCommon/include" \
  -I"$ROOT/Sources/CMoonlightCommon/src" \
  -I"$ROOT/Sources/CMoonlightCommon/enet/include" \
  -I"$ROOT/Sources/CMoonlightCommon/nanors" \
  -I"$ROOT/Sources/CMoonlightCommon/nanors/deps" \
  -I"$ROOT/Sources/CMoonlightCommon/nanors/deps/obl" \
  "$ROOT/linux/nodedeck_stream.c" \
  "${COMMON_SRCS[@]}" \
  "${ENET_SRCS[@]}" \
  "${NANORS_SRCS[@]}" \
  $(pkg-config --cflags --libs sdl2 libavcodec libavutil libswscale opus libcrypto) \
  -lpthread -lm \
  -o "$INSTALL_DIR/nodedeck-stream"

cp "$ROOT/linux/nodedeck_linux.py" "$INSTALL_DIR/nodedeck_linux.py"
chmod +x "$INSTALL_DIR/nodedeck-stream" "$INSTALL_DIR/nodedeck_linux.py"

if [[ -f "$ROOT/linux/nodedeck.png" ]]; then
  cp "$ROOT/linux/nodedeck.png" "$INSTALL_DIR/nodedeck.png"
  mkdir -p /usr/share/icons/hicolor/256x256/apps /usr/share/pixmaps
  cp "$ROOT/linux/nodedeck.png" /usr/share/icons/hicolor/256x256/apps/nodedeck.png
  cp "$ROOT/linux/nodedeck.png" /usr/share/pixmaps/nodedeck.png
  gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
fi

cat > /usr/local/bin/nodedeck <<'EOF'
#!/usr/bin/env bash
exec python3 /opt/nodedeck/nodedeck_linux.py "$@"
EOF
chmod +x /usr/local/bin/nodedeck

cat > /usr/share/applications/nodedeck.desktop <<'EOF'
[Desktop Entry]
Name=NodeDeck
Comment=SSH Device Manager, Port Forwarding & Native Moonlight Client
Exec=/usr/local/bin/nodedeck
Icon=nodedeck
Terminal=false
Type=Application
Categories=Network;System;Utility;
StartupWMClass=nodedeck_linux.py
EOF
update-desktop-database /usr/share/applications 2>/dev/null || true

echo "=== Installed NodeDeck for Linux successfully ==="
ls -lh "$INSTALL_DIR/nodedeck-stream" "$INSTALL_DIR/nodedeck_linux.py" "$INSTALL_DIR/nodedeck.png" /usr/local/bin/nodedeck /usr/share/applications/nodedeck.desktop /usr/share/icons/hicolor/256x256/apps/nodedeck.png
