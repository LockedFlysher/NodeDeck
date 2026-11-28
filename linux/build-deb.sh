#!/usr/bin/env bash
# Build an All-in-One self-contained Debian/Ubuntu .deb package for NodeDeck Linux
# (Client + Built-in nodedeck-host + Built-in EasyTier Mesh).
#
# Cross-distro & zero-extra-deps portability design:
# - Statically links minimal FFmpeg 7.1.1 (H.264/HEVC/AV1 + VAAPI + CUDA/NVDEC via dlopen)
#   into nodedeck-stream -> ZERO libavcodecXX / libavutilXX / libswscaleXX SONAME lock-in.
# - Statically links SDL2 (with X11/Wayland/PulseAudio runtime dlopen) + libopus.a
#   into nodedeck-stream -> ZERO libsdl2-2.0-0 / libopus0 external dependency!
# - Bundles libminiupnpc, libopus, libnuma, libevdev, libva, libva-drm into private lib dirs
#   with absolute+relative RUNPATH (/opt/nodedeck[/host]/lib:$ORIGIN[/..]/lib) so binaries
#   resolve cleanly even under AT_SECURE=1 (cap_sys_admin+p).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-2.1.0}"
BUNDLE_HOST="${BUNDLE_HOST:-1}"
STATIC_FFMPEG="${STATIC_FFMPEG:-1}"
STATIC_SDL2="${STATIC_SDL2:-1}"
FFMPEG_PREFIX="${FFMPEG_PREFIX:-$ROOT/.build/ffmpeg-static}"
SDL2_PREFIX="${SDL2_PREFIX:-$ROOT/.build/sdl2-static}"
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
  "$STAGE/opt/nodedeck/lib" \
  "$STAGE/opt/nodedeck/easytier" \
  "$STAGE/usr/local/bin" \
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

if [[ "$STATIC_FFMPEG" == "1" ]]; then
  PREFIX="$FFMPEG_PREFIX" bash "$ROOT/linux/build-ffmpeg-static.sh"
  FFMPEG_CFLAGS="-I${FFMPEG_PREFIX}/include"
  FFMPEG_LIBS=(
    -Wl,--start-group
    "${FFMPEG_PREFIX}/lib/libavcodec.a"
    "${FFMPEG_PREFIX}/lib/libswscale.a"
    "${FFMPEG_PREFIX}/lib/libavutil.a"
    -Wl,--end-group
    -lva -lva-drm -ldrm -lz -ldl
  )
else
  FFMPEG_CFLAGS="$(pkg-config --cflags libavcodec libavutil libswscale)"
  read -r -a FFMPEG_LIBS <<< "$(pkg-config --libs libavcodec libavutil libswscale)"
fi

if [[ "$STATIC_SDL2" == "1" ]]; then
  PREFIX="$SDL2_PREFIX" bash "$ROOT/linux/build-sdl2-static.sh"
  SDL_CFLAGS="-I${SDL2_PREFIX}/include -I${SDL2_PREFIX}/include/SDL2 -D_REENTRANT"
  SDL_LIBS=("${SDL2_PREFIX}/lib/libSDL2.a" -ldl -lpthread -lm)
else
  SDL_CFLAGS="$(pkg-config --cflags sdl2)"
  read -r -a SDL_LIBS <<< "$(pkg-config --libs sdl2)"
fi

OPUS_STATIC_A="$(find /usr/lib /lib -name libopus.a 2>/dev/null | head -n 1 || true)"
if [[ -n "$OPUS_STATIC_A" && -f "$OPUS_STATIC_A" ]]; then
  OPUS_CFLAGS="$(pkg-config --cflags opus)"
  OPUS_LIBS=("$OPUS_STATIC_A")
else
  OPUS_CFLAGS="$(pkg-config --cflags opus)"
  read -r -a OPUS_LIBS <<< "$(pkg-config --libs opus)"
fi

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
  $FFMPEG_CFLAGS $SDL_CFLAGS $OPUS_CFLAGS $(pkg-config --cflags libcrypto) \
  "$ROOT/linux/nodedeck_stream.c" \
  "${COMMON_SRCS[@]}" \
  "$ROOT"/Sources/CMoonlightCommon/enet/{callbacks,compress,host,list,packet,peer,protocol,unix}.c \
  "$ROOT"/Sources/CMoonlightCommon/nanors/rs.c \
  "$ROOT"/Sources/CMoonlightCommon/nanors/deps/obl/{oblas_common,oblas_lite}.c \
  "${SDL_LIBS[@]}" \
  "${OPUS_LIBS[@]}" \
  $(pkg-config --libs libcrypto) \
  "${FFMPEG_LIBS[@]}" \
  -Wl,-rpath,'/opt/nodedeck/lib:$ORIGIN/lib' \
  -lpthread -lm -ldl \
  -o "$STAGE/opt/nodedeck/nodedeck-stream"
strip --strip-unneeded "$STAGE/opt/nodedeck/nodedeck-stream" 2>/dev/null || true

bundle_so() {
  local soname="$1"
  local dest_dir="$2"
  if [[ -f "$dest_dir/$soname" ]]; then
    return 0
  fi
  local found
  found="$(ldconfig -p 2>/dev/null | awk -v lib="$soname" '$1 == lib {print $NF; exit}' || true)"
  if [[ -n "$found" && -f "$found" ]]; then
    cp -L "$found" "$dest_dir/$soname"
    chmod 0644 "$dest_dir/$soname"
  fi
}

# Bundle tiny VAAPI glue libs for nodedeck-stream so libva2/libva-drm2 aren't required externally
bundle_so "libva.so.2" "$STAGE/opt/nodedeck/lib"
bundle_so "libva-drm.so.2" "$STAGE/opt/nodedeck/lib"

install -m 0755 "$ROOT/linux/nodedeck_linux.py" "$STAGE/opt/nodedeck/nodedeck_linux.py"
install -m 0755 "$ROOT/linux/nodedeck_mesh_agent.py" "$STAGE/opt/nodedeck/nodedeck_mesh_agent.py"
cat > "$STAGE/usr/lib/systemd/user/nodedeck-mesh.service" <<'EOF'
[Unit]
Description=NodeDeck User-Space Built-in EasyTier Mesh Agent (Zero-Sudo)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/nodedeck/nodedeck_mesh_agent.py --state-dir %h/.config/nodedeck daemon
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
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

ensure_patchelf() {
  if command -v patchelf >/dev/null 2>&1; then
    command -v patchelf
    return 0
  fi
  local tools_dir="$ROOT/.build/host-tools"
  mkdir -p "$tools_dir"
  if [[ -x "$tools_dir/root/usr/bin/patchelf" ]]; then
    echo "$tools_dir/root/usr/bin/patchelf"
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1 && command -v dpkg-deb >/dev/null 2>&1; then
    (cd "$tools_dir" && apt-get download patchelf >/dev/null 2>&1 && dpkg-deb -x patchelf_*.deb "$tools_dir/root") || true
    if [[ -x "$tools_dir/root/usr/bin/patchelf" ]]; then
      echo "$tools_dir/root/usr/bin/patchelf"
      return 0
    fi
  fi
  return 1
}

HOST_DEPENDS=""
if [[ "$BUNDLE_HOST" == "1" ]]; then
  if [[ -x "$HOST_SRC_DIR/bin/nodedeck-host" ]]; then
    echo "=== Bundling built-in nodedeck-host from $HOST_SRC_DIR ==="
    mkdir -p "$STAGE/opt/nodedeck/host/lib"
    cp -a "$HOST_SRC_DIR/." "$STAGE/opt/nodedeck/host/"
    chmod 0755 "$STAGE/opt/nodedeck/host/bin/nodedeck-host"

    # Bundle all non-default tiny runtime libs alongside nodedeck-host (~700 KB total)
    MINI_SONAME="$(readelf -d "$STAGE/opt/nodedeck/host/bin/nodedeck-host" 2>/dev/null \
      | grep -oE 'libminiupnpc\.so\.[0-9.]+' | head -n 1 || true)"
    [[ -n "$MINI_SONAME" ]] && bundle_so "$MINI_SONAME" "$STAGE/opt/nodedeck/host/lib"
    for extra_so in libopus.so.0 libnuma.so.1 libevdev.so.2 libva.so.2 libva-drm.so.2; do
      bundle_so "$extra_so" "$STAGE/opt/nodedeck/host/lib"
    done

    # Stamp absolute + relative RUNPATH so /opt/nodedeck/host/lib resolves even with cap_sys_admin+p (AT_SECURE=1)
    PATCHELF_BIN="$(ensure_patchelf || true)"
    if [[ -n "$PATCHELF_BIN" ]]; then
      "$PATCHELF_BIN" --set-rpath '/opt/nodedeck/host/lib:$ORIGIN/../lib' "$STAGE/opt/nodedeck/host/bin/nodedeck-host"
    else
      echo "ERROR: patchelf not found; cannot stamp RPATH on nodedeck-host" >&2
      exit 1
    fi

    # Only base libraries preinstalled on standard Ubuntu/Debian desktops
    HOST_DEPENDS=", libpulse0, libcurl4t64 | libcurl4, libcap2, libwayland-client0"

    cat > "$STAGE/usr/lib/systemd/user/nodedeck-host.service" <<'EOF'
[Unit]
Description=NodeDeck Built-in Remote Desktop Host (Sunshine)
After=graphical-session.target pipewire-pulse.service

[Service]
Type=simple
PassEnvironment=DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR PULSE_SERVER
Environment=DISPLAY=:0
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

# Self-containment audit
echo "=== Auditing dynamic library dependencies ==="
if [[ "$STATIC_FFMPEG" == "1" ]]; then
  if readelf -d "$STAGE/opt/nodedeck/nodedeck-stream" | grep -qE 'libavcodec\.so|libavutil\.so|libswscale\.so'; then
    echo "ERROR: nodedeck-stream still dynamically links system FFmpeg!" >&2
    readelf -d "$STAGE/opt/nodedeck/nodedeck-stream" | grep NEEDED >&2
    exit 1
  fi
fi
if [[ "$STATIC_SDL2" == "1" ]]; then
  if readelf -d "$STAGE/opt/nodedeck/nodedeck-stream" | grep -qE 'libSDL2'; then
    echo "ERROR: nodedeck-stream still dynamically links libSDL2!" >&2
    readelf -d "$STAGE/opt/nodedeck/nodedeck-stream" | grep NEEDED >&2
    exit 1
  fi
fi
if [[ -x "$STAGE/opt/nodedeck/host/bin/nodedeck-host" ]]; then
  if ! readelf -d "$STAGE/opt/nodedeck/host/bin/nodedeck-host" | grep -q '/opt/nodedeck/host/lib'; then
    echo "ERROR: nodedeck-host is missing /opt/nodedeck/host/lib RPATH/RUNPATH!" >&2
    exit 1
  fi
  if ! ls "$STAGE/opt/nodedeck/host/lib/"libminiupnpc.so.* >/dev/null 2>&1; then
    echo "ERROR: bundled libminiupnpc.so.* missing from /opt/nodedeck/host/lib!" >&2
    exit 1
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

EXTRA_CLIENT_DEPENDS=""
if [[ "$STATIC_SDL2" != "1" ]]; then
  EXTRA_CLIENT_DEPENDS="${EXTRA_CLIENT_DEPENDS}, libsdl2-2.0-0"
fi
if [[ "$STATIC_FFMPEG" != "1" ]]; then
  EXTRA_CLIENT_DEPENDS="${EXTRA_CLIENT_DEPENDS}, libavcodec61 | libavcodec60 | libavcodec-extra60 | libavcodec59, libavutil59 | libavutil58 | libavutil57, libswscale8 | libswscale7 | libswscale6"
fi

cat > "$STAGE/DEBIAN/control" <<EOF
Package: nodedeck
Version: ${VERSION}
Section: net
Priority: optional
Architecture: ${ARCH}
Maintainer: NodeDeck Contributors
Depends: python3, python3-gi, gir1.2-gtk-3.0, libssl3t64 | libssl3, libdrm2, openssh-client, openssl${EXTRA_CLIENT_DEPENDS}${HOST_DEPENDS}
Description: NodeDeck All-in-One SSH Manager, Remote Desktop Client & Built-in Host
 Zero-cloud SSH workstation manager with live CPU/GPU telemetry, port forwarding,
 self-contained hardware-accelerated Moonlight streaming client (static FFmpeg + SDL2 + Opus),
 and built-in Sunshine host (nodedeck-host) with bundled runtime dependencies.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -e
if command -v setcap >/dev/null 2>&1; then
  if [ -x /opt/nodedeck/host/bin/nodedeck-host ]; then
    setcap cap_sys_admin+p /opt/nodedeck/host/bin/nodedeck-host 2>/dev/null || true
  fi
  if [ -x /opt/nodedeck/easytier/easytier-core ]; then
    setcap cap_net_admin,cap_net_raw+ep /opt/nodedeck/easytier/easytier-core 2>/dev/null || true
  fi
fi
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
update-desktop-database /usr/share/applications 2>/dev/null || true
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

dpkg-deb -Zxz --build "$STAGE" "$DEB_PATH"
echo "Built self-contained All-in-One package: $DEB_PATH"
ls -lh "$DEB_PATH"
dpkg-deb -I "$DEB_PATH" | grep -E 'Package:|Version:|Architecture:|Depends:'
