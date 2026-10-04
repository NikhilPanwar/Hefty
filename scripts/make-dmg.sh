#!/bin/sh
# Builds build/Hefty-<version>.dmg (drag-to-Applications window with branded
# background) and build/Hefty-<version>.zip.
# Not Developer ID signed/notarized: first launch needs right-click > Open.
set -e
cd "$(dirname "$0")/.."
scripts/make-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Hefty.app/Contents/Info.plist)
NAME="Hefty $VERSION"
DMG="build/Hefty-$VERSION.dmg"
WORK=$(mktemp -d)
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R build/Hefty.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift scripts/make-icon.swift dmg "$WORK/bg.png" "$WORK/bg@2x.png"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null

# Lay out the window in a writable image under a temporary, unique volume name
# (so an already-mounted copy of the DMG can't collide), then rename and compress.
FINAL_NAME="$NAME"
NAME="HeftyBuild$$"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk '/Apple_HFS/ {print $1}')
osascript <<APPLESCRIPT || echo "warning: Finder layout skipped (allow automation of Finder to get the styled window)"
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 560}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Hefty.app" of container window to {170, 230}
    set position of item "Applications" of container window to {490, 230}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
# Volume icon goes in after the Finder pass, which drops it.
cp build/Hefty.app/Contents/Resources/AppIcon.icns "/Volumes/$NAME/.VolumeIcon.icns"
SetFile -a C "/Volumes/$NAME" 2>/dev/null || true
diskutil rename "/Volumes/$NAME" "$FINAL_NAME" >/dev/null
sync
hdiutil detach "$DEV" -quiet || hdiutil detach "$DEV" -force -quiet
rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$WORK"
codesign --force --sign - "$DMG" >/dev/null 2>&1 || true
(cd build && rm -f "Hefty-$VERSION.zip" && ditto -c -k --keepParent Hefty.app "Hefty-$VERSION.zip")
ls -lh "$DMG" "build/Hefty-$VERSION.zip"
