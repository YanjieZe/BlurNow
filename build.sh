#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=BlurNow.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp AppIcon.icns $APP/Contents/Resources/
# universal binary: Apple Silicon + Intel
swiftc -O -target arm64-apple-macos13 main.swift -o /tmp/BlurNow-arm64
swiftc -O -target x86_64-apple-macos13 main.swift -o /tmp/BlurNow-x86_64
lipo -create /tmp/BlurNow-arm64 /tmp/BlurNow-x86_64 -output $APP/Contents/MacOS/BlurNow
rm -f /tmp/BlurNow-arm64 /tmp/BlurNow-x86_64
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>BlurNow</string>
  <key>CFBundleIdentifier</key><string>local.blurnow</string>
  <key>CFBundleExecutable</key><string>BlurNow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - $APP
echo "Built $(pwd)/$APP"
