#!/usr/bin/env bash
# Build & package the AI Chat macOS app using swiftc directly (SPM-free),
# compatible with old toolchains that predate @main / App / WindowGroup.
#
# Usage:
#   ./build.sh                     # build x86_64 (or arm64 on Apple Silicon)
#   ARCHS="x86_64" ./build.sh      # force architecture
set -euo pipefail

APP_NAME="AIChatApp"
BUNDLE_ID="com.aichat.app"
BUILD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$BUILD_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
SRC_DIR="$BUILD_ROOT/Sources"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Architectures to build. Override with: ARCHS="x86_64" ./build.sh
ARCHS="${ARCHS:-x86_64}"
MIN_MACOS="10.15"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}WARN:${NC} $1"; }

info "AI Chat — build & package script"
info "Target architectures: $ARCHS"
info "Cleaning previous build..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

info "Compiling Swift sources with swiftc..."
SWIFT_FILES=$(find "$SRC_DIR" -name '*.swift' | sort)

# Use the system toolchain (Swift 5.2 bundled with Command Line Tools).
# This is the same approach music_alarm uses — it compiles fine with the
# legacy "macosx10.15" triple and the system SDK.
SWIFTC="swiftc"
info "Using compiler: $SWIFTC"

compile_arch() {
  local arch="$1" target
  # Legacy triple compatible with the system SDK.
  for t in "$arch-apple-macosx${MIN_MACOS}" "$arch-apple-macosx10.14"; do
    if "$SWIFTC" -O -swift-version 5 \
        -target "$t" \
        -framework SwiftUI \
        -framework AppKit \
        -framework Combine \
        -o "$TMP_DIR/$APP_NAME-$arch" \
        $SWIFT_FILES 2>"$TMP_DIR/$arch.err"; then
      echo "   [$arch] compiled OK (target: $t)."
      return 0
    fi
  done
  echo "   [$arch] FAILED:" >&2
  sed 's/^/       /' "$TMP_DIR/$arch.err" >&2 || true
  return 1
}

THIN_BINARIES=()
for arch in $ARCHS; do
  if compile_arch "$arch"; then
    THIN_BINARIES+=("$TMP_DIR/$APP_NAME-$arch")
  else
    warn "Compilation failed for $arch; skipping this architecture."
  fi
done

if [ "${#THIN_BINARIES[@]}" -eq 0 ]; then
  echo "ERROR: no architecture compiled successfully." >&2
  exit 1
fi

if [ "${#THIN_BINARIES[@]}" -eq 1 ]; then
  warn "Only one architecture built (${THIN_BINARIES[0]##*-}); this is NOT a universal binary."
  cp "${THIN_BINARIES[0]}" "$MACOS_DIR/$APP_NAME"
else
  info "Merging universal binary with lipo..."
  lipo -create "${THIN_BINARIES[@]}" -output "$MACOS_DIR/$APP_NAME"
  lipo -info "$MACOS_DIR/$APP_NAME" || true
fi
echo "   Binary: $MACOS_DIR/$APP_NAME"

info "Copying Info.plist..."
cp "$BUILD_ROOT/Info.plist" "$CONTENTS/Info.plist"

info "Ad-hoc code signing..."
if codesign --force --deep --sign - "$APP_DIR" 2>/dev/null; then
  echo "   Signed OK."
else
  warn "codesign failed; app is still runnable locally."
fi

echo ""
echo -e "${GREEN}Build complete!${NC}"
echo "   App:     $APP_DIR"
echo "   Binary:  $MACOS_DIR/$APP_NAME"
echo ""
echo "   To launch:  open \"$APP_DIR\""