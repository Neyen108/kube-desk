#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache"
BIN_DIR="$(swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache" --show-bin-path)"
APP="dist/KubeDesk.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/KubeDesk" "$APP/Contents/MacOS/KubeDesk"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>KubeDesk</string>
<key>CFBundleDisplayName</key><string>KubeDesk</string>
<key>CFBundleIdentifier</key><string>local.kubedesk.app</string>
<key>CFBundleExecutable</key><string>KubeDesk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"
