#!/usr/bin/env bash
# Build a self-contained Debian/Ubuntu .deb package for NodeDeck Linux.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-2.0.0}"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
STAGE="$ROOT/.build/deb-stage"
OUT_DIR="$ROOT/artifacts"
DEB_PATH="$OUT_DIR/nodedeck_${VERSION}_${ARCH}.deb"

rm -rf "$STAGE"
mkdir -p \
  "$STAGE/DEBIAN" \
  "$STAGE/opt/nodedeck" \
  "$STAGE/usr/local/bin" \
  "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/icons/hicolor/256x256/apps" \
  "$STAGE/usr/share/pixmaps" \
  "$OUT_DIR"

COMMON_SRCS=()
for f in "$ROOT"/Sources/CMoonlightCommon/src/*.c; do
  base="$(basename "$f")"
  [[ "$base" == "SunshineCryptoBridge.c" ]] && continue
  COMMON_SRCS+=("$f")
done

"${CC:-gcc}" -O2 -std=gnu11 \
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
  "$ROOT"/Sources/CMoonlightCommon/enet/{callbacks,compress,host,list,packet,peer,protocol,unix}.c \
  "$ROOT/Sources/CMoonlightCommon/nanors/rs.c" \
  "$ROOT"/Sources/CMoonlightCommon/nanors/deps/obl/{oblas_common,oblas_lite}.c \
  $(pkg-config --cflags --libs sdl2 libavcodec libavutil libswscale opus libcrypto) \
  -lpthread -lm \
  -o "$STAGE/opt/nodedeck/nodedeck-stream"

install -m 0755 "$ROOT/linux/nodedeck_linux.py" "$STAGE/opt/nodedeck/nodedeck_linux.py"
if [[ -f "$ROOT/linux/nodedeck.png" ]]; then
  install -m 0644 "$ROOT/linux/nodedeck.png" "$STAGE/opt/nodedeck/nodedeck.png"
  install -m 0644 "$ROOT/linux/nodedeck.png" "$STAGE/usr/share/icons/hicolor/256x256/apps/nodedeck.png"
  install -m 0644 "$ROOT/linux/nodedeck.png" "$STAGE/usr/share/pixmaps/nodedeck.png"
fi

cat > "$STAGE/usr/local/bin/nodedeck" <<'EOF'
#!/usr/bin/env bash
exec python3 /opt/nodedeck/nodedeck_linux.py "$@"
EOF
chmod 0755 "$STAGE/usr/local/bin/nodedeck"

cat > "$STAGE/usr/share/applications/nodedeck.desktop" <<'EOF'
[Desktop Entry]
Name=NodeDeck
Comment=SSH Device Manager, Live GPU Metrics, Port Forwarding & Hardware Moonlight Client
Exec=/usr/local/bin/nodedeck
Icon=nodedeck
Terminal=false
Type=Application
Categories=Network;System;Utility;
StartupWMClass=nodedeck_linux.py
EOF

cat > "$STAGE/DEBIAN/control" <<EOF
Package: nodedeck
Version: ${VERSION}
Section: net
Priority: optional
Architecture: ${ARCH}
Maintainer: NodeDeck Contributors
Depends: python3, python3-gi, gir1.2-gtk-3.0, libsdl2-2.0-0, libopus0, libssl3t64 | libssl3, libavcodec60 | libavcodec-extra60 | libavcodec59, libavutil58 | libavutil57, libswscale7 | libswscale6, openssh-client, openssl
Description: NodeDeck SSH Workstation Manager & Native Moonlight Client
 Manage SSH devices, live CPU/GPU metrics, port forwarding, multi-user
 Linux Sunshine host isolation profiles, and hardware-accelerated desktop streaming.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -e
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
update-desktop-database /usr/share/applications 2>/dev/null || true
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

dpkg-deb --build "$STAGE" "$DEB_PATH"
echo "Built package: $DEB_PATH"
ls -lh "$DEB_PATH"
