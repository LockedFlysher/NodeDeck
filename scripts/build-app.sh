#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="NodeDeck.app"
APP_PATH="$ROOT/dist/$APP_NAME"
UNIVERSAL="${UNIVERSAL:-0}"
INSTALL="${INSTALL:-0}"
HOST_APP="${HOST_APP:-$ROOT/.build/host/NodeDeckHost.app}"
HOST_BIN="${HOST_BIN:-$ROOT/.build/host/nodedeck-host}"

cd "$ROOT"
mkdir -p "$ROOT/.build" "$ROOT/dist"
touch "$ROOT/.build/.metadata_never_index" "$ROOT/dist/.metadata_never_index"

if [[ "$UNIVERSAL" == "1" ]]; then
    ARM_TRIPLE="arm64-apple-macosx14.0"
    INTEL_TRIPLE="x86_64-apple-macosx14.0"
    swift build -c "$CONFIG" --triple "$ARM_TRIPLE"
    ARM_BIN="$(swift build -c "$CONFIG" --triple "$ARM_TRIPLE" --show-bin-path)/NodeDeck"
    ARM_COPY="$ROOT/.build/NodeDeck-arm64"
    cp "$ARM_BIN" "$ARM_COPY"
    swift build -c "$CONFIG" --triple "$INTEL_TRIPLE"
    INTEL_BIN="$(swift build -c "$CONFIG" --triple "$INTEL_TRIPLE" --show-bin-path)/NodeDeck"
    ARM_BIN="$ARM_COPY"
else
    swift build -c "$CONFIG"
    ARM_BIN="$(swift build -c "$CONFIG" --show-bin-path)/NodeDeck"
    INTEL_BIN=""
fi

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

if [[ -n "$INTEL_BIN" ]]; then
    lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP_PATH/Contents/MacOS/NodeDeck"
else
    cp "$ARM_BIN" "$APP_PATH/Contents/MacOS/NodeDeck"
fi
cp "$ROOT/Support/Info.plist" "$APP_PATH/Contents/Info.plist"

ICON_WORK="$ROOT/.build/nodedeck-icon"
ICONSET="$ICON_WORK/AppIcon.iconset"
MASTER="$ICON_WORK/AppIcon-1024.png"
rm -rf "$ICON_WORK"
mkdir -p "$ICONSET"

swift "$ROOT/scripts/make-icon.swift" "$MASTER"

for size in 16 32 64 128 256 512 1024; do
    if [[ "$size" == "16" ]]; then
        name="icon_16x16.png"
    elif [[ "$size" == "32" ]]; then
        name="icon_16x16@2x.png"
        sips -z 32 32 "$MASTER" --out "$ICONSET/icon_32x32.png" >/dev/null
    elif [[ "$size" == "64" ]]; then
        name="icon_32x32@2x.png"
    elif [[ "$size" == "128" ]]; then
        name="icon_128x128.png"
    elif [[ "$size" == "256" ]]; then
        name="icon_128x128@2x.png"
        sips -z 256 256 "$MASTER" --out "$ICONSET/icon_256x256.png" >/dev/null
    elif [[ "$size" == "512" ]]; then
        name="icon_256x256@2x.png"
        sips -z 512 512 "$MASTER" --out "$ICONSET/icon_512x512.png" >/dev/null
    else
        name="icon_512x512@2x.png"
    fi
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$APP_PATH/Contents/Resources/AppIcon.icns"

# Embed source-built headless NodeDeckHost.app (zero-Qt Sunshine host) if present
if [[ -d "$HOST_APP" ]]; then
    mkdir -p "$APP_PATH/Contents/Helpers"
    rm -rf "$APP_PATH/Contents/Helpers/NodeDeckHost.app"
    ditto "$HOST_APP" "$APP_PATH/Contents/Helpers/NodeDeckHost.app"
elif [[ -x "$HOST_BIN" ]]; then
    mkdir -p "$APP_PATH/Contents/Helpers"
    cp "$HOST_BIN" "$APP_PATH/Contents/Helpers/nodedeck-host"
    chmod 0755 "$APP_PATH/Contents/Helpers/nodedeck-host"
    HOST_LIB_DIR="$(dirname "$HOST_BIN")/host-lib"
    if [[ -d "$HOST_LIB_DIR" ]] && [[ -n "$(ls -A "$HOST_LIB_DIR" 2>/dev/null)" ]]; then
        rm -rf "$APP_PATH/Contents/Helpers/host-lib"
        ditto "$HOST_LIB_DIR" "$APP_PATH/Contents/Helpers/host-lib"
    fi
fi

# Embed built-in EasyTier core binary if present
EASYTIER_BIN="${EASYTIER_BIN:-/usr/local/bin/easytier-core}"
if [[ -x "$EASYTIER_BIN" ]]; then
    mkdir -p "$APP_PATH/Contents/Helpers"
    cp "$EASYTIER_BIN" "$APP_PATH/Contents/Helpers/easytier-core"
    chmod 0755 "$APP_PATH/Contents/Helpers/easytier-core"
fi

codesign --force --deep --sign - "$APP_PATH"

ARTIFACT_DIR="$ROOT/artifacts"
if [[ "$UNIVERSAL" == "1" ]]; then
    ARTIFACT_PATH="$ARTIFACT_DIR/NodeDeck-macos-universal.zip"
else
    ARTIFACT_PATH="$ARTIFACT_DIR/NodeDeck-macos-arm64.zip"
fi
mkdir -p "$ARTIFACT_DIR"
rm -f "$ARTIFACT_PATH" "$ARTIFACT_DIR/NodeDeck-macos-universal.zip"
ditto -c -k --norsrc --keepParent "$APP_PATH" "$ARTIFACT_PATH"
(cd "$ARTIFACT_DIR" && shasum -a 256 *.zip *.deb 2>/dev/null > SHA256SUMS.txt || shasum -a 256 "$(basename "$ARTIFACT_PATH")" > SHA256SUMS.txt)

if [[ "$INSTALL" == "1" ]]; then
    LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREG" -u "$APP_PATH" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME"
    mv "$APP_PATH" "/Applications/$APP_NAME"
    "$LSREG" -f "/Applications/$APP_NAME" 2>/dev/null || true
    printf '/Applications/%s\n' "$APP_NAME"
else
    printf '%s\n' "$APP_PATH"
fi
