#!/bin/bash
# Assembles an Intel (x86_64) build of Picnido.app from the SwiftPM build product.
#
# Derived from build_app.sh — keep the two in step. Only these things differ:
#   1. `swift build --arch x86_64`, so the product lands under an extra triple directory
#   2. BIN points into `.build/x86_64-apple-macosx/…`
#   3. the bundle is staged in `dist-x86/`, so an Intel build never overwrites the arm one
#   4. `lipo -archs` is asserted, because a mistyped --arch silently rebuilds for the host
#   5. no `lsregister`: registering a second copy of the same bundle id is how this machine
#      ended up with three live instances once already
set -euo pipefail

# The tree this script lives in, found rather than written down.
#
# This used to be the literal absolute path of the working copy, which made it work perfectly
# here and nowhere else: the source tarball is one of the three things shipped per release, and
# unpacking it somewhere else and running this script built **the original working copy** instead
# of the unpacked tree — silently, because the path existed. That is exactly how a source package
# passes a "does it still build?" check while being unbuildable on any other machine. Found while
# packaging 1.3.1 by comparing `pwd` inside the unpacked tree with where the output landed.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Picnido"
BUILD_CONFIG="${1:-release}"
APP="$ROOT/dist-x86/$APP_NAME.app"

echo "==> building ($BUILD_CONFIG)"
cd "$ROOT"
# `--disable-sandbox` + the two path overrides are required here: SwiftPM tries to
# nest its own sandbox-exec while compiling the manifest and to touch ~/.swiftpm/security,
# neither of which is permitted inside the agent sandbox.
mkdir -p "$ROOT/.swiftpm-local/security" "$ROOT/.swiftpm-local/cache"
# The build log is kept and the error lines are echoed on failure. Piping straight into `tail`
# hid a compile error for a whole round of testing: the exit status was still correct, but the
# only output left in the terminal was a pair of diagnostic-group links, and the freshly "built"
# bundle turned out to be the previous binary copied over itself.
BUILD_LOG="$ROOT/.swiftpm-local/build.log"
if ! swift build -c "$BUILD_CONFIG" --arch x86_64 --disable-sandbox \
       --cache-path "$ROOT/.swiftpm-local/cache" \
       --security-path "$ROOT/.swiftpm-local/security" > "$BUILD_LOG" 2>&1; then
  echo "==> build FAILED (full log: $BUILD_LOG)"
  grep -E "error:" "$BUILD_LOG" | head -20
  exit 1
fi
tail -3 "$BUILD_LOG"

BIN="$ROOT/.build/x86_64-apple-macosx/$BUILD_CONFIG/Picnido"
if [ ! -x "$BIN" ]; then echo "missing binary $BIN"; exit 1; fi

# `--arch` is easy to get wrong in a way nothing else notices: drop it and SwiftPM happily
# produces an arm64 binary in the host's build directory, which still runs on this machine.
ARCHS="$(/usr/bin/lipo -archs "$BIN")"
if [ "$ARCHS" != "x86_64" ]; then echo "expected a thin x86_64 binary, got: $ARCHS"; exit 1; fi
echo "==> binary: thin $ARCHS"

echo "==> assembling $APP"
# NOTE: assemble in place. A blanket `rm -rf "$APP"` trips the sandbox's bulk-delete
# guard, and an app bundle never needs to be wiped to be rebuilt.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp -f "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# gallery templates: none bundled — `GalleryWriter` writes a self-contained HTML album
# from code, so there is no template folder to copy.
#
# ⚠️ This script assembles in place, so a bundle staged by 1.3.3 or older still carries
# `Resources/templates/` (108 files) and `Resources/SHORTCUTS.xml`. Those cannot be wiped
# from here — a bulk delete of that size is refused by the sandbox — so remove `dist/`
# once by hand after upgrading, then rebuild.
for stale in "$APP/Contents/Resources/templates" "$APP/Contents/Resources/SHORTCUTS.xml"; do
    if [ -e "$stale" ]; then
        echo "⚠️  stale asset from an older build: $stale (remove dist/ and rebuild)"
    fi
done

# Interface translations. `Text("…")` looks its string up in the bundle the app is *running from*,
# so a language table that stays in the source tree translates nothing. One directory per
# language, and a language with no directory is not an error: a missing key falls back to the
# literal in the code, which is English, so a partial translation is a working translation.
for lproj in "$ROOT"/Resources/*.lproj; do
  [ -d "$lproj" ] || continue
  lang="$(basename "$lproj")"
  /usr/bin/rsync -a --delete "$lproj/" "$APP/Contents/Resources/$lang/"
  echo "==> translations: $lang"
done

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Quoted delimiter, deliberately. With an unquoted `<<PLIST` the shell expands the body before
# plutil ever sees it, and that silently ate an XML comment: the backticks around Alternate ran as
# a command substitution ("line 42: Alternate: command not found"), the comment collapsed to an
# empty string, and the plist stayed *valid* — so the build reported success and nothing was
# noticed. Nothing in this body needs expanding (APP_NAME is the constant "Picnido"), so quoting
# the delimiter switches the whole hazard off instead of asking every future edit to remember it.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Picnido</string>
    <key>CFBundleDisplayName</key><string>Picnido for Mac</string>
    <key>CFBundleExecutable</key><string>Picnido</string>
    <key>CFBundleIdentifier</key><string>app.picnido.mac</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.3.3</string>
    <key>CFBundleVersion</key><string>13</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- The development region is `en`, and deliberately there is no `en.lproj`. Every string in
         the code is written in English, so the literal *is* the English table — which is also
         what makes a missing translation fall back to something readable instead of to a key.
         `CFBundleLocalizations` is what tells the system (and a translator) which languages are
         actually on offer; without it the list is inferred from the .lproj directories that
         happen to be present, and that inference is what makes a half-copied bundle look like it
         supports a language it has no strings for. -->
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
      <string>en</string>
      <string>zh-Hans</string>
      <string>ja</string>
      <string>ko</string>
    </array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><true/>
    <!-- Declared, not just set at runtime, and that distinction is load-bearing.
         The app calls `setActivationPolicy(.regular)` when it has a library window and
         `.accessory` when it does not — but LaunchServices applies the *bundle's* policy every
         time it is asked to open this app, and with no declaration here that policy is "regular".
         Measured: with the app sitting happily in accessory mode, `open <another picture>.jpg`
         flipped it to regular and it stayed there — the Dock icon came back on exactly the path
         the design exists to keep it off. Declaring the app an agent makes accessory the
         system's own answer for this bundle, and the runtime promotion still produces a Dock
         icon when the library opens.
         NOTE: `LSUIElement`, not `LSBackgroundOnly` — the latter forbids windows entirely. -->
    <key>LSUIElement</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
      <dict>
        <key>CFBundleTypeName</key><string>Image</string>
        <key>CFBundleTypeRole</key><string>Viewer</string>
        <!-- Default, not Alternate. `Alternate` reads like the polite choice — show up in
             "Open With" without competing for the double-click — but LaunchServices refuses to
             make an Alternate-rank application the default, and reports success while refusing:
             both write APIs return noErr and the database keeps its old value. Measured, not
             guessed (work/probe/setdefault.swift): flipping an unrelated Default-rank app takes
             one call, and the same call on this app did nothing until this line changed.
             Claiming a format is still explicit — it happens in Settings, per format. Preview
             keeps the types it owns because it outranks this app on its own formats, not
             because this app hides. -->
        <key>LSHandlerRank</key><string>Default</string>
        <!-- Concrete, non-dynamic identifiers only, and only ones verified present on this
             machine by work/probe/utis.swift. LaunchServices drops an identifier it does not
             know, silently — no log, no warning — so this list is checked at runtime against
             FileTypeCatalog.uniqueUTIIdentifiers() by PICNIDO_FILETYPES_CHECK=1. Editing this
             by hand? Run that first, or add the format in FileTypeCatalog.swift instead.
             NOTE: the delimiter is quoted, so a backtick or a dollar sign in this body is inert
             and this comment may contain them freely. Keep the delimiter quoted. -->
        <key>LSItemContentTypes</key>
        <array>
          <!-- Common (15 extensions → 13 identifiers; jpg/jpeg and tif/tiff share one) -->
          <string>public.jpeg</string>
          <string>public.png</string>
          <string>com.compuserve.gif</string>
          <string>com.microsoft.bmp</string>
          <string>public.tiff</string>
          <string>public.heic</string>
          <string>public.heif</string>
          <string>org.webmproject.webp</string>
          <string>com.adobe.photoshop-image</string>
          <string>com.truevision.tga-image</string>
          <string>public.jpeg-2000</string>
          <string>public.avif</string>
          <string>public.jpeg-xl</string>
          <!-- RAW (26 extensions → 26 identifiers) -->
          <string>com.adobe.raw-image</string>
          <string>com.panasonic.raw-image</string>
          <string>com.hasselblad.3fr-raw-image</string>
          <string>com.hasselblad.fff-raw-image</string>
          <string>com.phaseone.raw-image</string>
          <string>com.leafamerica.raw-image</string>
          <string>com.konicaminolta.raw-image</string>
          <string>com.kodak.raw-image</string>
          <string>com.epson.raw-image</string>
          <string>com.dxo.raw-image</string>
          <string>com.canon.cr2-raw-image</string>
          <string>com.canon.cr3-raw-image</string>
          <string>com.canon.crw-raw-image</string>
          <string>com.nikon.raw-image</string>
          <string>com.nikon.nrw-raw-image</string>
          <string>com.nikon.nefx-raw-image</string>
          <string>com.sony.arw-raw-image</string>
          <string>com.sony.sr2-raw-image</string>
          <string>com.sony.raw-image</string>
          <string>com.sony.axr-raw-image</string>
          <string>com.olympus.raw-image</string>
          <string>com.panasonic.rw2-raw-image</string>
          <string>com.fuji.raw-image</string>
          <string>com.samsung.raw-image</string>
          <string>com.pentax.raw-image</string>
          <string>com.leica.rwl-raw-image</string>
        </array>
      </dict>
    </array>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

# Guard rail for the class of mistake above: a damaged plist makes the app fail to launch in ways
# that look like a code bug. Catch it at build time instead of at double-click time.
plutil -lint "$APP/Contents/Info.plist" >/dev/null || { echo "Info.plist is malformed"; exit 1; }

echo "==> signing (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>&1 | tail -2
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

echo "==> done: $APP"
du -sh "$APP"
