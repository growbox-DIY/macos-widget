#!/bin/sh
# Builds build/GrowBox Widget.app (release, ad-hoc signed - runs locally,
# no Apple account, no expiry).
# ./build.sh install: also copies it to ~/Applications and (re)starts it -
# the copy there is the one that opens at login.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="build/GrowBox Widget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/GrowBoxWidget "$APP/Contents/MacOS/GrowBoxWidget"
mkdir -p "$APP/Contents/Resources"
cp Resources/Ionicons.ttf "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GrowBox Widget</string>
  <key>CFBundleIdentifier</key><string>pl.umatik.growbox-widget</string>
  <key>CFBundleExecutable</key><string>GrowBoxWidget</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- no Dock icon, no menu bar -->
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Reads temperature, humidity and fan state from the grow box ESP in your home network.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [ "$1" = "install" ]; then
  pkill -f "GrowBox Widget.app/Contents/MacOS/GrowBoxWidget" || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/GrowBox Widget.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/GrowBox Widget.app"
  echo "Installed to ~/Applications"
fi
