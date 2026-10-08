#!/bin/sh
# Build Ritrovo.app (universal arm64 + x86_64) and a DMG.
# The bundled PhotoRec engine comes from darwin/build-macos.sh.
# Requirements: Xcode command line tools, autoconf, automake, libtool,
# pkg-config, cmake, python3.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APPDIR="$ROOT/macos/Ritrovo"
OUT=${OUT:-$ROOT/build-macos/app}
VERSION=${VERSION:-0.1.0}
MACOS_MIN=13.0

"$ROOT/darwin/build-macos.sh"
# Engine for the app: hidden session file, no DFXML report (report.xml)
ENGINE="$ROOT/build-macos/engine"
BUILD="$ENGINE" EXTRA_CONFIGURE="--disable-dfxml" \
  EXTRA_CPPFLAGS='-DSESSION_FILENAME=\".ritrovo.ses\" -DSESSION_FILENAME_OLD=\".ritrovo.se2\"' \
  "$ROOT/darwin/build-macos.sh"

mkdir -p "$OUT"
python3 "$ROOT/macos/tools/gen_formats.py" "$ROOT/src" "$OUT/formats.json"

for arch in arm64 x86_64; do
  (cd "$APPDIR" && swift build -c release --product Ritrovo \
    --triple "$arch-apple-macosx$MACOS_MIN" --scratch-path "$OUT/swift-$arch")
done

APP="$OUT/Ritrovo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$OUT/swift-arm64/release/Ritrovo" "$OUT/swift-x86_64/release/Ritrovo" \
  -output "$APP/Contents/MacOS/Ritrovo"
cp "$ENGINE/dist/photorec" "$APP/Contents/MacOS/ritrovo-engine"
cp "$OUT/formats.json" "$APP/Contents/Resources/"
cp "$APPDIR/Resources/ritrovo-run.sh" "$APP/Contents/Resources/"
cp -R "$APPDIR/Resources/it.lproj" "$APP/Contents/Resources/"
cp "$ROOT/COPYING" "$APP/Contents/Resources/COPYING"
if [ -f "$APPDIR/Resources/AppIcon.icns" ]; then
  cp "$APPDIR/Resources/AppIcon.icns" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ritrovo</string>
  <key>CFBundleDevelopmentRegion</key><string>it</string>
  <key>CFBundleLocalizations</key><array><string>it</string></array>
  <key>CFBundleDisplayName</key><string>Ritrovo</string>
  <key>CFBundleIdentifier</key><string>it.fabiodalez.ritrovo</string>
  <key>CFBundleExecutable</key><string>Ritrovo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MACOS_MIN</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>GPL v2+. Recovery engine: PhotoRec by Christophe Grenier, CGSecurity.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Disk image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.disk-image</string><string>public.data</string></array>
    </dict>
  </array>
  <key>NSAppleEventsUsageDescription</key><string>Ritrovo asks for the administrator password to read disks.</string>
</dict>
</plist>
EOF

# Ad-hoc signature: enough to run locally, Gatekeeper still warns on
# other Macs until the app is signed with a Developer ID and notarized.
codesign --force -s - "$APP/Contents/MacOS/ritrovo-engine"
codesign --force -s - "$APP"
codesign --verify --deep --strict "$APP"

DMG="$OUT/Ritrovo-$VERSION.dmg"
rm -f "$DMG"
STAGE="$OUT/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Ritrovo $VERSION" -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"
lipo -info "$APP/Contents/MacOS/Ritrovo"
echo "App: $APP"
echo "DMG: $DMG"
