#!/bin/zsh
# Builds StrataWidget.app (real bundle: proper LaunchServices/defaults identity).
# Launch instances with distinct --instance ids so parallel widgets stay isolated:
#   open -n ./StrataWidget.app --args --instance=StrataWidget1 --server-url=<lan-address> --strata-port=8080 --control-port=8090
set -e
cd "$(dirname "$0")"
APP=StrataWidget.app
rm -rf "$APP"
rm -f StrataWidget # stale bare binary: launching it skips --instance and the bundle identity
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources/icon.iconset"
# Build the app icon from icon.png (1024x1024): sips generates every required
# iconset size, iconutil packs them into the .icns the bundle reads.
# $APP is swift-widget/StrataWidget.app, so ../icon.png is the source icon.
sips -s format png -z 16 16 "$APP/../icon.png" --out "$APP/Contents/Resources/icon.iconset/icon_16.png"
sips -s format png -z 32 32 "$APP/../icon.png" --out "$APP/Contents/Resources/icon.iconset/icon_16@2x.png"
sips -s format png -z 32 32 "$APP/../icon.png" --out "$APP/Contents/Resources/icon.iconset/icon_32.png"
sips -s format png -z 64 64 "$APP/../icon.png" --out "$APP/Contents/Resources/icon.iconset/icon_32@2x.png"
sips -s format png -z 128 128 "$APP/../icon.png" --out "$APP/Contents/Resources/icon.iconset/icon_128.png"
sips -s format png -z 256 256 "$APP/../icon.png" --out "$APP/Contents/Resources/icon.iconset/icon_128@2x.png"
sips -s format png -z 256 256 "$APP/../icon.png" --out "$APP/Contents/Resources/icon.iconset/icon_256.png"
sips -s format png -z 512 512 "$APP/../icon.png" --out "$APP/Contents/Resources/icon.iconset/icon_256@2x.png"
sips -s format png -z 512 512 "$APP/../icon.png" --out "$APP/Contents/Resources/icon.iconset/icon_512.png"
sips -s format png -z 1024 1024 "$APP/../icon.png" --out "$APP/Contents/Resources/icon.iconset/icon_512@2x.png"
iconutil -c icns "$APP/Contents/Resources/icon.iconset" -o "$APP/Contents/Resources/Icon.icns"
# Pin the deployment target: without -target, swiftc stamps minos with the build host's
# OS, so a CI artifact would demand the runner's macOS version while Info.plist still
# claims 15.0. arm64 matches the GitHub macOS runners and these machines.
swiftc -O -target arm64-apple-macos15.0 strata-app.swift components.swift payload.swift chat.swift -o "$APP/Contents/MacOS/StrataWidget"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>StrataWidget</string>
  <key>CFBundleIdentifier</key><string>com.strata.widget</string>
  <key>CFBundleName</key><string>StrataWidget</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>CFBundleIconFile</key><string>Icon</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>StrataWidget reads its metrics and model list from the Strata server on your local network.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP"
