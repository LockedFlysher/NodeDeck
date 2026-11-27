#!/usr/bin/env bash
# Build an All-in-One Debian/Ubuntu .deb package for NodeDeck Linux (Client + Built-in nodedeck-host).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-2.1.0}"
BUNDLE_HOST="${BUNDLE_HOST:-1}"
if [[ -z "${HOST_SRC_DIR:-}" ]]; then
  if [[ -x "$ROOT/.build/host-linux/bin/nodedeck-host" ]]; then
    HOST_SRC_DIR="$ROOT/.build/host-linux"
  else
    HOST_SRC_DIR="/opt/nodedeck/host"
  fi
fi
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
STAGE="$ROOT/.build/deb-stage"
OUT_DIR="$ROOT/artifacts"
DEB_PATH="$OUT_DIR/nodedeck_${VERSION}_${ARCH}.deb"

rm -rf "$STAGE"
mkdir -p \
  "$STAGE/DEBIAN" \
  "$STAGE/opt/nodedeck" \
  "$STAGE/opt/nodedeck/easytier" \
  "$STAGE/usr/local/bin" \
  "$STAGE/usr/lib/systemd/system" \
  "$STAGE/usr/lib/systemd/user" \
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
install -m 0755 "$ROOT/linux/nodedeck_mesh_agent.py" "$STAGE/opt/nodedeck/nodedeck_mesh_agent.py"
install -m 0644 "$ROOT/linux/nodedeck-mesh.service" "$STAGE/usr/lib/systemd/system/nodedeck-mesh.service"
if [[ -x "/usr/local/bin/easytier-core" ]]; then
  install -m 0755 "/usr/local/bin/easytier-core" "$STAGE/opt/nodedeck/easytier/easytier-core"
fi
cat > "$STAGE/usr/local/bin/nodedeck-mesh" <<'EOF'
#!/usr/bin/env bash
exec python3 /opt/nodedeck/nodedeck_mesh_agent.py "$@"
EOF
chmod 0755 "$STAGE/usr/local/bin/nodedeck-mesh"
if [[ -f "$ROOT/linux/nodedeck.png" ]]; then
  install -m 0644 "$ROOT/linux/nodedeck.png" "$STAGE/opt/nodedeck/nodedeck.png"
  install -m 0644 "$ROOT/linux/nodedeck.png" "$STAGE/usr/share/icons/hicolor/256x256/apps/nodedeck.png"
  install -m 0644 "$ROOT/linux/nodedeck.png" "$STAGE/usr/share/pixmaps/nodedeck.png"
fi

HOST_DEPENDS=""
if [[ "$BUNDLE_HOST" == "1" ]]; then
  if [[ -x "$HOST_SRC_DIR/bin/nodedeck-host" ]]; then
    echo "=== Bundling built-in nodedeck-host from $HOST_SRC_DIR ==="
    mkdir -p "$STAGE/opt/nodedeck/host"
    cp -a "$HOST_SRC_DIR/." "$STAGE/opt/nodedeck/host/"
    chmod 0755 "$STAGE/opt/nodedeck/host/bin/nodedeck-host"
    HOST_DEPENDS=", libminiupnpc17 | libminiupnpc18, libnuma1, libva2, libva-drm2, libdrm2, libevdev2, libpulse0, libcurl4t64 | libcurl4, libcap2, libwayland-client0"

    cat > "$STAGE/usr/lib/systemd/user/nodedeck-host.service" <<'EOF'
[Unit]
Description=NodeDeck Built-in Remote Desktop Host (Sunshine)
After=graphical-session.target pipewire-pulse.service

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'mkdir -p "$HOME/.config/nodedeck"; if [ ! -f "$HOME/.config/nodedeck/apps.json" ]; then printf "{\n  \"env\": {},\n  \"apps\": [{ \"name\": \"Desktop\", \"image-path\": \"desktop.png\" }]\n}\n" > "$HOME/.config/nodedeck/apps.json"; fi; if [ ! -f "$HOME/.config/nodedeck/host.conf" ]; then printf "port = 47989\nfile_apps = %s/.config/nodedeck/apps.json\nfile_state = %s/.config/nodedeck/host_state.json\ncredentials_file = %s/.config/nodedeck/credentials.json\npkey = %s/.config/nodedeck/host.key\ncert = %s/.config/nodedeck/host.cert\n" "$HOME" "$HOME" "$HOME" "$HOME" "$HOME" > "$HOME/.config/nodedeck/host.conf"; fi'
ExecStart=/opt/nodedeck/host/bin/nodedeck-host %h/.config/nodedeck/host.conf
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
  else
    echo "WARNING: BUNDLE_HOST=1 set, but $HOST_SRC_DIR/bin/nodedeck-host not found; building client-only .deb."
  fi
fi

cat > "$STAGE/usr/local/bin/nodedeck" <<'EOF'
#!/usr/bin/env bash
exec python3 /opt/nodedeck/nodedeck_linux.py "$@"
EOF
chmod 0755 "$STAGE/usr/local/bin/nodedeck"

cat > "$STAGE/usr/share/applications/nodedeck.desktop" <<'EOF'
[Desktop Entry]
Name=NodeDeck
Comment=All-in-One SSH Workstation Manager, Built-in Remote Desktop Client & Host
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
Depends: python3, python3-gi, gir1.2-gtk-3.0, libsdl2-2.0-0, libopus0, libssl3t64 | libssl3, libavcodec60 | libavcodec-extra60 | libavcodec59, libavutil58 | libavutil57, libswscale7 | libswscale6, openssh-client, openssl${HOST_DEPENDS}
Description: NodeDeck All-in-One SSH Manager, Remote Desktop Client & Built-in Host
 Zero-cloud SSH workstation manager with live CPU/GPU telemetry, port forwarding,
 hardware-accelerated Moonlight streaming client, and built-in Sunshine host (nodedeck-host).
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -e
if [ -x /opt/nodedeck/host/bin/nodedeck-host ] && command -v setcap >/dev/null 2>&1; then
  setcap cap_sys_admin+p /opt/nodedeck/host/bin/nodedeck-host 2>/dev/null || true
fi
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
update-desktop-database /usr/share/applications 2>/dev/null || true
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

dpkg-deb -Zxz --build "$STAGE" "$DEB_PATH"
echo "Built All-in-One package: $DEB_PATH"
ls -lh "$DEB_PATH"
