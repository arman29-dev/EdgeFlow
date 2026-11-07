#!/bin/bash
# Builds EdgeFlow.app from the Swift package.
#   scripts/build_app.sh              build into ./build/
#   scripts/build_app.sh --install    also copy to ~/Applications
#   SIGN_IDENTITY="My Cert" scripts/build_app.sh     sign with a stable identity (recommended, see README)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="EdgeFlow"
BUNDLE_ID="local.EdgeFlow"
VERSION="1.0.0"
CONFIG="${CONFIG:-release}"
IDENTITY="${SIGN_IDENTITY:--}"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: 'swift' not found. Install Xcode or the Xcode Command Line Tools (xcode-select --install)." >&2
  exit 1
fi

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

OUT="build/$APP_NAME.app"
echo "==> Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$OUT/Contents/MacOS/$APP_NAME"

# App icon: build AppIcon.icns from assets/AppIcon.png with the tools that ship with macOS.
ICON_SRC="assets/AppIcon.png"
if [ -f "$ICON_SRC" ] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  echo "==> Building app icon"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
else
  echo "==> Skipping icon (assets/AppIcon.png, sips or iconutil not found)"
fi

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Trackpad Edge Gestures</string>
  <key>CFBundleDisplayName</key><string>Trackpad Edge Gestures</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$OUT"
if [ "$IDENTITY" = "-" ]; then
  echo "    (ad-hoc signature: macOS forgets Accessibility/Input Monitoring grants every rebuild."
  echo "     See README 'Stable signing' to avoid that.)"
fi

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  cp -R "$OUT" "$HOME/Applications/"
  touch "$HOME/Applications/$APP_NAME.app"      # nudges Finder/Spotlight to re-read the icon
  echo "==> Installed to ~/Applications/$APP_NAME.app"
  echo "    If the icon still looks blank, run:  killall Finder; killall Dock"
  echo "    Open it with:  open ~/Applications/$APP_NAME.app"
else
  echo "==> Done: $OUT"
  echo "    Run it with:   open $OUT"
  echo "    Or install:    scripts/build_app.sh --install"
fi
