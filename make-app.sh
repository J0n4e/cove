#!/bin/bash
# Builds a release Cove.app (with icon) in ./dist
set -euo pipefail
cd "$(dirname "$0")"
APP=dist/Cove.app
# Version shown in the app: $VERSION if given (e.g. "v0.5Beta"), else the latest git tag plus commits since.
VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null || echo dev)}"
# It goes into Info.plist unescaped, so allow only plain version characters.
[[ "$VERSION" =~ ^[0-9A-Za-z._+-]{1,64}$ ]] || { echo "error: VERSION '$VERSION' may only contain letters, digits and . _ + -" >&2; exit 1; }
SHORT=$(echo "$VERSION" | sed -E 's/^v//; s/^([0-9]+(\.[0-9]+)*).*/\1/'); [[ "$SHORT" =~ ^[0-9] ]] || SHORT=0.0
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
echo "Version: $VERSION ($SHORT, build $BUILD)"
swift build -c release --arch arm64   # Apple Silicon only (Intel Macs are not supported)
BIN=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Cove" "$APP/Contents/MacOS/Cove"
cp -R "$BIN/Cove_Cove.bundle" "$APP/Contents/Resources/"

# Icon: build .icns from Sources/Resources/AppIcon.png
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Sources/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Sources/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Cove</string>
  <key>CFBundleDisplayName</key><string>Cove</string>
  <key>CFBundleIdentifier</key><string>eu.jonae.cove</string>
  <key>CFBundleExecutable</key><string>Cove</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CoveVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Many home Emby servers use plain http (e.g. http://host:8096); allow it. -->
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST

# Signature: CI passes the release certificate's SHA-1 as CODESIGN_IDENTITY (see scripts/ci-import-cert.sh), so every
# release is recognized as the same app; local builds stay ad-hoc ("-"). Hardened runtime in both cases.
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with ${IDENTITY/#-/ad-hoc signature})"
