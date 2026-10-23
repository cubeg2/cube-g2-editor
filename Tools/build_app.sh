#!/bin/bash
# build_app.sh — buduje „Cube G2 Editor.app” i DMG dla testerów (plan bety C.1).
#
#   Tools/build_app.sh            → dist/Cube G2 Editor.app + dist/Cube-G2-Editor-<wersja>-beta.dmg
#   Tools/build_app.sh --no-dmg   → sama aplikacja
#
# Wersja: plik VERSION (np. 0.1.0). Numer kompilacji: liczba commitów.
# Bez konta Apple: podpis ad-hoc. Tester otwiera aplikację przez System Settings ▸
# Privacy & Security ▸ Open Anyway — instrukcja jest na tle okna DMG.
# Tylko Maki z procesorem M i macOS 15+ (libusb z Homebrew jest arm64 i wymaga 15.0).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NAME="Cube G2 Editor"
BUNDLE_ID="io.github.cubeg2.editor"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD)"
SHORT_VERSION="${VERSION%.0}"                # 0.1.0 → 0.1 (nazwa DMG)
DIST="$ROOT/dist"
APP="$DIST/$NAME.app"
DMG="$DIST/Cube-G2-Editor-$SHORT_VERSION-beta.dmg"
SCRATCH="$ROOT/.build/public"                # osobny katalog: bez prywatnych flag
LIBUSB="$(brew --prefix libusb)/lib/libusb-1.0.0.dylib"
MAKE_DMG=1
[[ "${1:-}" == "--no-dmg" ]] && MAKE_DMG=0

echo "▸ Kompilacja $VERSION ($BUILD_NUMBER), wersja publiczna"
G2_PUBLIC_BUILD=1 swift build -c release --scratch-path "$SCRATCH" --product G2EditorApp
BIN="$SCRATCH/release"

echo "▸ Składanie $NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" "$APP/Contents/Frameworks"
cp "$BIN/G2EditorApp" "$APP/Contents/MacOS/$NAME"
# Paczki zasobów SwiftPM w Resources — w korzeniu .app psułyby podpis
# (szuka ich tam `Bundle.appResourceBundle`).
cp -R "$BIN/G2Editor_G2Core.bundle" "$BIN/G2Editor_G2EditorApp.bundle" "$APP/Contents/Resources/"

# libusb (LGPL-2.1) w środku aplikacji, żeby tester nie potrzebował Homebrew.
cp "$LIBUSB" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
chmod u+w "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
OLD_LIBUSB="$(otool -L "$APP/Contents/MacOS/$NAME" | awk '/libusb/ {print $1}')"
install_name_tool -change "$OLD_LIBUSB" "@executable_path/../Frameworks/libusb-1.0.0.dylib" "$APP/Contents/MacOS/$NAME"

cp LICENSE "$APP/Contents/Resources/Licenses/LICENSE.txt"
cp NOTICE.md "$APP/Contents/Resources/Licenses/NOTICE.md"
cp "$(brew --prefix libusb)/COPYING" "$APP/Contents/Resources/Licenses/libusb-COPYING.txt"

ART="$(mktemp -d)"
trap 'rm -rf "$ART"' EXIT
swift Tools/packaging_art.swift icon Sources/G2EditorApp/Resources/AppIcon.svg "$ART/AppIcon.iconset"
iconutil -c icns "$ART/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Spectrum and X-Y Plot can show the sound coming into your audio interface, for example from a Nord G2.</string>
    <!-- .pch2 i .prf2 otwierają się z Findera (podwójny klik, Open With, ikona w Docku). -->
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.clavia.nordmodular.g2.patch</string>
            <key>UTTypeDescription</key><string>Nord Modular G2 Patch</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>pch2</string></array></dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>com.clavia.nordmodular.g2.performance</string>
            <key>UTTypeDescription</key><string>Nord Modular G2 Performance</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>prf2</string></array></dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Nord Modular G2 Patch</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>com.clavia.nordmodular.g2.patch</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Nord Modular G2 Performance</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>com.clavia.nordmodular.g2.performance</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "▸ Podpis ad-hoc"
codesign --force --sign - "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

[[ $MAKE_DMG == 1 ]] || { echo "✅ $APP"; exit 0; }

echo "▸ DMG"
VOLUME="/Volumes/$NAME"
if [[ -d "$VOLUME" ]]; then
    echo "❌ $VOLUME jest już podłączony — odłącz go (wysuń w Finderze) i uruchom ponownie."
    exit 1
fi
STAGE="$ART/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift Tools/packaging_art.swift background "$ART"
tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null

RW="$ART/rw.dmg"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$NAME" -fs HFS+ -format UDRW -size 200m "$RW"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW"

# Wygląd okna ustawia Finder (te same liczby co w packaging_art.swift: okno 640×460,
# ikony na wysokości 130 pt). Pierwszy raz macOS może zapytać o zgodę na sterowanie Finderem.
# Rozmiar okna Finder zapisuje do .DS_Store dopiero po zamknięciu i ponownym otwarciu —
# za pierwszym razem DMG otwierał się w domyślnej szerokości 920 pt (2026-10-16).
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "$NAME.app" of container window to {170, 130}
        set position of item "Applications" of container window to {470, 130}
        set the bounds of container window to {200, 120, 840, 580}
        close
        delay 1
        open
        set the bounds of container window to {200, 120, 840, 580}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sleep 2
sync
hdiutil detach -quiet "$VOLUME"
rm -f "$DMG"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
echo "✅ $DMG ($(du -h "$DMG" | cut -f1))"
