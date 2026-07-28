#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
DIST_DIR="$PROJECT_ROOT/dist"
APP_OUTPUT="$DIST_DIR/Quill.app"
DMG_PATH="$DIST_DIR/Quill.dmg"
BUILD_CONFIGURATION=${BUILD_CONFIGURATION:-release}
SIGN_IDENTITY=${SIGN_IDENTITY:--}

cd "$PROJECT_ROOT"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    swift build -c "$BUILD_CONFIGURATION"
fi

BIN_DIR=$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)
QUILL_BINARY="$BIN_DIR/quill"
if [[ ! -x "$QUILL_BINARY" ]]; then
    print -u2 "Missing built executable: $QUILL_BINARY"
    exit 1
fi

if [[ "$APP_OUTPUT" != "$PROJECT_ROOT/dist/Quill.app" ]]; then
    print -u2 "Refusing to replace an unexpected app path: $APP_OUTPUT"
    exit 1
fi

/bin/mkdir -p "$DIST_DIR"
/bin/rm -rf "$APP_OUTPUT" "$DMG_PATH"

PACKAGE_WORK=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/quill-package.XXXXXX")
APP_BUNDLE="$PACKAGE_WORK/Quill.app"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
/usr/bin/ditto "$QUILL_BINARY" "$APP_BUNDLE/Contents/MacOS/quill"
/bin/chmod 755 "$APP_BUNDLE/Contents/MacOS/quill"
/usr/bin/ditto "$PROJECT_ROOT/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

COMMIT_COUNT=$(/usr/bin/git rev-list --count HEAD 2>/dev/null || print 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $COMMIT_COUNT" "$APP_BUNDLE/Contents/Info.plist"

ICON_WORK=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/quill-icon.XXXXXX")
DMG_WORK=""
cleanup() {
    /bin/rm -rf "$ICON_WORK" "$PACKAGE_WORK"
    if [[ -n "$DMG_WORK" ]]; then
        /bin/rm -rf "$DMG_WORK"
    fi
}
trap cleanup EXIT

/usr/bin/qlmanage -t -s 1024 -o "$ICON_WORK" "$PROJECT_ROOT/Packaging/QuillIcon.svg" >/dev/null
ICON_SOURCE="$ICON_WORK/QuillIcon.svg.png"
if [[ ! -f "$ICON_SOURCE" ]]; then
    print -u2 "Quick Look did not render the app icon."
    exit 1
fi

ICONSET="$ICON_WORK/Quill.iconset"
/bin/mkdir -p "$ICONSET"
for SPEC in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    SIZE=${SPEC%% *}
    NAME=${SPEC#* }
    /usr/bin/sips -z "$SIZE" "$SIZE" "$ICON_SOURCE" --out "$ICONSET/$NAME" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/Quill.icns"

# Finder and Quick Look can attach metadata that codesign rejects as resource
# forks. Generated bundles do not need any extended attributes.
/usr/bin/xattr -cr "$APP_BUNDLE"
/usr/bin/codesign \
    --force \
    --timestamp=none \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

DMG_WORK=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/quill-dmg.XXXXXX")
/usr/bin/ditto "$APP_BUNDLE" "$DMG_WORK/Quill.app"
/bin/ln -s /Applications "$DMG_WORK/Applications"
/usr/bin/hdiutil create \
    -quiet \
    -volname "Quill" \
    -srcfolder "$DMG_WORK" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Keep a directly runnable copy beside the DMG. The project may itself live
# inside a File Provider folder, so export without inherited extended metadata.
/usr/bin/ditto --noextattr --noqtn "$APP_BUNDLE" "$APP_OUTPUT"
/usr/bin/xattr -cr "$APP_OUTPUT"

print "Created:"
print "  $APP_OUTPUT"
print "  $DMG_PATH"
