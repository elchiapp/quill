#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
DIST_DIR="$PROJECT_ROOT/dist"
APP_OUTPUT="$DIST_DIR/DropSift.app"
APP_ARCHIVE="$DIST_DIR/DropSift.app.zip"
DMG_PATH="$DIST_DIR/DropSift.dmg"
BUILD_CONFIGURATION=${BUILD_CONFIGURATION:-release}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
MLX_DERIVED_DATA="$PROJECT_ROOT/.build/mlx-xcode"
MLX_PROJECT="$PROJECT_ROOT/.build/checkouts/mlx-swift/xcode/MLX.xcodeproj"
MLX_METALLIB="$MLX_DERIVED_DATA/Build/Products/Release/Cmlx.framework/Versions/A/Resources/default.metallib"
MLX_BUILD_LOG="$DIST_DIR/mlx-metal-build.log"
VERSION_FILE="$PROJECT_ROOT/VERSION"
BUILD_NUMBER_FILE="$PROJECT_ROOT/BUILD_NUMBER"
QVAC_SOURCE="$PROJECT_ROOT/QVACBridge"

cd "$PROJECT_ROOT"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    swift build -c "$BUILD_CONFIGURATION"
fi

/bin/mkdir -p "$DIST_DIR"

if [[ "${SKIP_METAL_BUILD:-0}" != "1" ]]; then
    if [[ ! -d "$MLX_PROJECT" ]]; then
        print -u2 "Missing MLX checkout: $MLX_PROJECT"
        print -u2 "Run 'swift package resolve' first."
        exit 1
    fi
    if ! /usr/bin/xcodebuild build \
        -quiet \
        -project "$MLX_PROJECT" \
        -scheme Cmlx \
        -configuration Release \
        -destination "platform=macOS,arch=arm64" \
        -derivedDataPath "$MLX_DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        >"$MLX_BUILD_LOG" 2>&1
    then
        /usr/bin/tail -n 80 "$MLX_BUILD_LOG" >&2
        print -u2 "MLX Metal build failed. If Xcode reports a missing Metal Toolchain, run:"
        print -u2 "  xcodebuild -downloadComponent MetalToolchain"
        exit 1
    fi
fi

if [[ ! -f "$MLX_METALLIB" ]]; then
    print -u2 "Missing compiled MLX shader library: $MLX_METALLIB"
    exit 1
fi

BIN_DIR=$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)
DROPSIFT_BINARY="$BIN_DIR/dropsift"
if [[ ! -x "$DROPSIFT_BINARY" ]]; then
    print -u2 "Missing built executable: $DROPSIFT_BINARY"
    exit 1
fi

if [[ "$APP_OUTPUT" != "$PROJECT_ROOT/dist/DropSift.app" ]]; then
    print -u2 "Refusing to replace an unexpected app path: $APP_OUTPUT"
    exit 1
fi

/bin/rm -rf "$APP_OUTPUT" "$APP_ARCHIVE" "$DMG_PATH"

PACKAGE_WORK=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dropsift-package.XXXXXX")
APP_BUNDLE="$PACKAGE_WORK/DropSift.app"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
/usr/bin/ditto "$DROPSIFT_BINARY" "$APP_BUNDLE/Contents/MacOS/dropsift"
/usr/bin/ditto "$MLX_METALLIB" "$APP_BUNDLE/Contents/Resources/mlx.metallib"

# QVAC runs as a child Bare process managed by Dropsift. Bundle the bridge and
# only the Apple-silicon addon prebuilds; npm packages otherwise include native
# binaries for every desktop, mobile, and server platform.
QVAC_EXECUTABLE="$QVAC_SOURCE/node_modules/bare-runtime-darwin-arm64/bin/bare"
if [[ ! -f "$QVAC_SOURCE/bootstrap.cjs" \
    || ! -f "$QVAC_SOURCE/bridge.mjs" \
    || ! -f "$QVAC_SOURCE/package-lock.json" ]]; then
    print -u2 "Missing QVAC bridge sources in $QVAC_SOURCE"
    exit 1
fi
if [[ ! -x "$QVAC_EXECUTABLE" ]]; then
    /usr/bin/env npm ci --omit=dev --prefix "$QVAC_SOURCE"
    /bin/chmod 755 "$QVAC_EXECUTABLE"
fi
QVAC_RUNTIME="$APP_BUNDLE/Contents/Resources/QVACRuntime"
if [[ "$QVAC_RUNTIME" != "$APP_BUNDLE/Contents/Resources/QVACRuntime" ]]; then
    print -u2 "Refusing to assemble QVAC at an unexpected path: $QVAC_RUNTIME"
    exit 1
fi
/bin/mkdir -p "$QVAC_RUNTIME"
/usr/bin/ditto "$QVAC_SOURCE/bootstrap.cjs" "$QVAC_RUNTIME/bootstrap.cjs"
/usr/bin/ditto "$QVAC_SOURCE/bridge.mjs" "$QVAC_RUNTIME/bridge.mjs"
/usr/bin/ditto "$QVAC_SOURCE/package.json" "$QVAC_RUNTIME/package.json"
/usr/bin/ditto "$QVAC_SOURCE/package-lock.json" "$QVAC_RUNTIME/package-lock.json"
/usr/bin/rsync -a --exclude='prebuilds/*' \
    "$QVAC_SOURCE/node_modules/" "$QVAC_RUNTIME/node_modules/"
while IFS= read -r PREBUILD
do
    RELATIVE_PREBUILD=${PREBUILD#"$QVAC_SOURCE/"}
    /bin/mkdir -p "${QVAC_RUNTIME}/${RELATIVE_PREBUILD:h}"
    /usr/bin/ditto "$PREBUILD" "$QVAC_RUNTIME/$RELATIVE_PREBUILD"
done < <(/usr/bin/find "$QVAC_SOURCE/node_modules" \
    -type d -path '*/prebuilds/darwin-arm64')
/bin/chmod 755 \
    "$QVAC_RUNTIME/node_modules/bare-runtime-darwin-arm64/bin/bare"

/bin/ln -s ../Resources "$APP_BUNDLE/Contents/MacOS/Resources"
/bin/chmod 755 "$APP_BUNDLE/Contents/MacOS/dropsift"
/usr/bin/ditto "$PROJECT_ROOT/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

if [[ ! -s "$VERSION_FILE" || ! -s "$BUILD_NUMBER_FILE" ]]; then
    print -u2 "Missing VERSION or BUILD_NUMBER release metadata."
    exit 1
fi
RELEASE_VERSION=$(</dev/null /usr/bin/tr -d '[:space:]' < "$VERSION_FILE")
RELEASE_BUILD=$(</dev/null /usr/bin/tr -d '[:space:]' < "$BUILD_NUMBER_FILE")
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $RELEASE_VERSION" \
    "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleVersion $RELEASE_BUILD" \
    "$APP_BUNDLE/Contents/Info.plist"

ICON_WORK=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dropsift-icon.XXXXXX")
DMG_WORK=""
cleanup() {
    /bin/rm -rf "$ICON_WORK" "$PACKAGE_WORK"
    if [[ -n "$DMG_WORK" ]]; then
        /bin/rm -rf "$DMG_WORK"
    fi
}
trap cleanup EXIT

/usr/bin/qlmanage -t -s 1024 -o "$ICON_WORK" "$PROJECT_ROOT/Packaging/DropsiftIcon.svg" >/dev/null
ICON_SOURCE="$ICON_WORK/DropsiftIcon.svg.png"
if [[ ! -f "$ICON_SOURCE" ]]; then
    print -u2 "Quick Look did not render the app icon."
    exit 1
fi

ICONSET="$ICON_WORK/Dropsift.iconset"
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
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/Dropsift.icns"

# Finder and Quick Look can attach metadata that codesign rejects as resource
# forks. Generated bundles do not need any extended attributes.
/bin/chmod -R u+w "$APP_BUNDLE"
/usr/bin/xattr -cr "$APP_BUNDLE"
/usr/bin/codesign \
    --force \
    --deep \
    --timestamp=none \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

DMG_WORK=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dropsift-dmg.XXXXXX")
/usr/bin/ditto "$APP_BUNDLE" "$DMG_WORK/DropSift.app"
/bin/ln -s /Applications "$DMG_WORK/Applications"
/usr/bin/hdiutil create \
    -quiet \
    -volname "DropSift" \
    -srcfolder "$DMG_WORK" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Archive directly from the clean temporary bundle. A bare app written into a
# File Provider folder can acquire Finder xattrs after signing; the archive
# and DMG remain byte-stable and preserve the valid signature.
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ARCHIVE"

print "Created:"
print "  $APP_ARCHIVE"
print "  $DMG_PATH"
