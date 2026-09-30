#!/usr/bin/env bash
#
# Builds Enhance.app. Pass --debug for a faster, unoptimised build,
# or --install to also copy the result into /Applications.
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --debug)   CONFIG="debug" ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="Enhance"
BUNDLE_ID="com.local.adobeenhancer"
OUT="build/${APP_NAME}.app"

echo "==> swift build -c ${CONFIG}"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/AdobeEnhancer"

echo "==> assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"
cp "$BINARY" "${OUT}/Contents/MacOS/${APP_NAME}"

cat > "${OUT}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>        <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key>           <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Audio or Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.audio</string>
        <string>public.movie</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature keeps the WebKit cookie store (and therefore the Adobe
# login) attached to a stable identity across rebuilds.
echo "==> codesign (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT" >/dev/null

if [ "$INSTALL" = "1" ]; then
  echo "==> installing to /Applications"
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$OUT" "/Applications/${APP_NAME}.app"
fi

echo "==> done: ${OUT}"
