#!/usr/bin/env bash
# Build a Universal (arm64 + x86_64) macOS app bundle and package it as a .dmg.
#
#   ./scripts/build_dmg.sh                  # arm64 + x86_64 universal
#   ARCHS="arm64" ./scripts/build_dmg.sh    # Apple Silicon only (works on CLI
#                                           # toolchain without full Xcode)
#
# On GitHub Actions (macos-latest, full Xcode) this produces a true Universal
# binary. On a CLI-only Mac, cross-compiling to both arches needs Xcode, so the
# script falls back to whichever single arch can compile and warns.
set -euo pipefail

APP_NAME="AIChatApp"
BUILD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHS="${ARCHS:-arm64 x86_64}"
VERSION="${VERSION:-1.0.0}"

STAGE="$BUILD_ROOT/.stage/$APP_NAME.app"
DMG_PATH="$BUILD_ROOT/dist/$APP_NAME-$VERSION.dmg"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}WARN:${NC} $1"; }

info "Building macOS app: $APP_NAME"
info "Architectures: $ARCHS"
info "Version: $VERSION"

rm -rf "$BUILD_ROOT/.stage" "$DMG_PATH"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cd "$BUILD_ROOT"

# Build release binary(ies). On full Xcode this produces a universal binary
# directly; on some SwiftPM versions it produces per-arch binaries we merge
# with lipo below.
if ! swift build -c release --arch $ARCHS 2>"/tmp/aichat-build-err.log"; then
  warn "Multi-arch release build failed. Retrying per-arch and merging with lipo…"
  BUILD_ARMS=()
  FAILED=0
  for arch in $ARCHS; do
    if swift build -c release --arch "$arch" 2>>"/tmp/aichat-build-err.log"; then
      BUILD_ARMS+=("$arch")
    else
      warn "Failed to build arch: $arch"
      FAILED=1
    fi
  done
  if [ "$FAILED" -eq 1 ] && [ "${#BUILD_ARMS[@]}" -eq 0 ]; then
    echo "ERROR: no architecture compiled. See /tmp/aichat-build-err.log" >&2
    exit 1
  fi
fi

# Locate the built product binary (new SwiftPM puts it under
# .build/apple/Products/Release or per-arch .build/<triple>/release).
BIN="$(swift build -c release --show-bin-path 2>/dev/null)/$APP_NAME"
if [ ! -f "$BIN" ]; then
  BIN="$(find .build/apple/Products/Release -name "$APP_NAME" -type f 2>/dev/null | head -1)"
fi
if [ ! -f "$BIN" ]; then
  BIN="$(find .build -path "*release/$APP_NAME" -type f 2>/dev/null | head -1)"
fi
if [ ! -f "$BIN" ]; then
  # Per-arch products (no universal) → merge with lipo.
  MERGE=()
  for arch in $ARCHS; do
    F="$(find .build -path "*$arch*/release/$APP_NAME" -type f 2>/dev/null | head -1)"
    [ -n "$F" ] && MERGE+=("$F")
  done
  if [ "${#MERGE[@]}" -ge 2 ]; then
    lipo -create "${MERGE[@]}" -output "/tmp/$APP_NAME-universal"
    BIN="/tmp/$APP_NAME-universal"
  fi
fi

[ -f "$BIN" ] || { echo "ERROR: built binary not found" >&2; exit 1; }

file "$BIN" | head -1

# Assemble bundle.
cp "$BIN" "$STAGE/Contents/MacOS/$APP_NAME"
cp "$BUILD_ROOT/Info.plist" "$STAGE/Contents/Info.plist"

# Icon (generate if missing, then copy into Resources).
if [ ! -f "$BUILD_ROOT/Assets/AppIcon.icns" ]; then
  info "Generating app icon…"
  swiftc -O "$BUILD_ROOT/scripts/generate_icon.swift" -framework AppKit -o /tmp/genicon 2>/dev/null
  mkdir -p "$BUILD_ROOT/Assets/AppIcon.iconset"
  /tmp/genicon /tmp/icon-1024.png 2>/dev/null || true
  sips -z 512 512 /tmp/icon-1024.png --out "$BUILD_ROOT/Assets/AppIcon.iconset/icon_512x512@2x.png" >/dev/null 2>&1 || true
  iconutil -c icns "$BUILD_ROOT/Assets/AppIcon.iconset" -o "$BUILD_ROOT/Assets/AppIcon.icns" 2>/dev/null || true
fi
cp "$BUILD_ROOT/Assets/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns" 2>/dev/null || \
  warn "Icon not found; app will build without one"

# Ad-hoc sign so it launches locally on both architectures.
codesign --force --deep --sign - "$STAGE" 2>/dev/null || warn "codesign failed"

# Package into DMG.
mkdir -p "$BUILD_ROOT/dist"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$BUILD_ROOT/.stage" \
  -ov -format UDZO "$DMG_PATH"

info "DMG created: $DMG_PATH"
echo ""
echo "   App:  $STAGE"
echo "   DMG:  $DMG_PATH"
echo "   To run: open \"$STAGE\""