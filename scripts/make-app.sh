#!/bin/sh
# Builds Hefty.app (universal, release) into ./build. With --install it puts the
# app in ~/Applications (replacing the pre-1.0 BigFileEditor.app) so it shows up
# in Launchpad, Spotlight and "Open With".
set -e
cd "$(dirname "$0")/.."
VERSION=1.0.0
# Build number = commit count, so every shipped build has a higher number.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
BUNDLE_ID=app.hefty.Hefty

swift build -c release --triple arm64-apple-macosx13.0
swift build -c release --triple x86_64-apple-macosx13.0
APP=build/Hefty.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/Hefty .build/x86_64-apple-macosx/release/Hefty \
  -output "$APP/Contents/MacOS/Hefty"
TMP=$(mktemp -d)
swift scripts/make-icon.swift iconset "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Hefty</string>
  <key>CFBundleDisplayName</key><string>Hefty</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Hefty</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Nok. MIT License.</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key><array>
    <dict>
      <key>CFBundleTypeName</key><string>Text and data files</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array>
        <string>public.text</string><string>public.data</string><string>public.content</string>
      </array>
    </dict>
  </array>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP $VERSION ($BUILD)"
if [ "$1" = "--install" ]; then
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  mkdir -p "$HOME/Applications"
  if [ -d "$HOME/Applications/BigFileEditor.app" ]; then
    $LSREGISTER -u "$HOME/Applications/BigFileEditor.app" || true
    mv "$HOME/Applications/BigFileEditor.app" "$HOME/.Trash/BigFileEditor-$(date +%s).app"
    echo "Moved old BigFileEditor.app to the Trash"
  fi
  rm -rf "$HOME/Applications/Hefty.app"
  cp -R "$APP" "$HOME/Applications/"
  $LSREGISTER -f "$HOME/Applications/Hefty.app" || true
  echo "Installed to ~/Applications/Hefty.app"
fi
