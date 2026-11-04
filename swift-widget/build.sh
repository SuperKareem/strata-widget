#!/bin/zsh
# Builds StrataWidget.app (real bundle: proper LaunchServices/defaults identity).
# Launch instances with distinct --instance ids so parallel widgets stay isolated:
#   open -n ./StrataWidget.app --args --instance=deskstrata --server-url=192.168.1.13 --strata-port=8080 --control-port=8090
set -e
cd "$(dirname "$0")"
APP=StrataWidget.app
rm -rf "$APP"
rm -f StrataWidget # stale bare binary: launching it skips --instance and the bundle identity
mkdir -p "$APP/Contents/MacOS"
# Pin the deployment target: without -target, swiftc stamps minos with the build host's
# OS, so a CI artifact would demand the runner's macOS version while Info.plist still
# claims 15.0. arm64 matches the GitHub macOS runners and these machines.
swiftc -O -target arm64-apple-macos15.0 strata-app.swift components.swift payload.swift -o "$APP/Contents/MacOS/StrataWidget"
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
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>StrataWidget reads its metrics and model list from the Strata server on your local network.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP"
