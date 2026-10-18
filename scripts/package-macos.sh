#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
DIST_DIR=${DROPSIFT_DIST_DIR:-"$PROJECT_ROOT/dist"}
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
RELEASE_MODE=${DROPSIFT_RELEASE:-0}

if [[ "$DIST_DIR" != /* || "$DIST_DIR" == "/" || "$DIST_DIR" == "/Applications" ]]; then
    print -u2 "DROPSIFT_DIST_DIR must be an explicit artifact directory."
    exit 1
fi
if [[ "$RELEASE_MODE" == "1" && "$SIGN_IDENTITY" == "-" ]]; then
    print -u2 "Release mode requires one explicit, approved Developer ID Application identity."
    exit 1
fi

cd "$PROJECT_ROOT"

/usr/bin/env node "$SCRIPT_DIR/prepare-package-resources.mjs"

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

PACKAGE_WORK=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dropsift-package.XXXXXX")
ICON_WORK=""
DMG_WORK=""
cleanup() {
    /bin/rm -rf "$PACKAGE_WORK"
    if [[ -n "$ICON_WORK" ]]; then /bin/rm -rf "$ICON_WORK"; fi
    if [[ -n "$DMG_WORK" ]]; then /bin/rm -rf "$DMG_WORK"; fi
}
trap cleanup EXIT
APP_BUNDLE="$PACKAGE_WORK/DropSift.app"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
/usr/bin/ditto "$DROPSIFT_BINARY" "$APP_BUNDLE/Contents/MacOS/dropsift"
/usr/bin/ditto "$MLX_METALLIB" "$APP_BUNDLE/Contents/Resources/mlx.metallib"
for RESOURCE_BUNDLE in "$BIN_DIR"/*.bundle(N)
do
    /usr/bin/ditto "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/${RESOURCE_BUNDLE:t}"
done

# QVAC runs as a child Bare process managed by Dropsift. Bundle the bridge and
# only the Apple-silicon addon prebuilds; npm packages otherwise include native
# binaries for every desktop, mobile, and server platform.
QVAC_EXECUTABLE="$QVAC_SOURCE/node_modules/bare-runtime-darwin-arm64/bin/bare"
for BRIDGE_FILE in bootstrap.cjs bridge.mjs speech-models.mjs structured-output.mjs diarization.mjs package-lock.json
do
    if [[ ! -f "$QVAC_SOURCE/$BRIDGE_FILE" ]]; then
        print -u2 "Missing QVAC bridge source: $QVAC_SOURCE/$BRIDGE_FILE"
        exit 1
    fi
done
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
/usr/bin/ditto "$QVAC_SOURCE/speech-models.mjs" "$QVAC_RUNTIME/speech-models.mjs"
/usr/bin/ditto "$QVAC_SOURCE/structured-output.mjs" "$QVAC_RUNTIME/structured-output.mjs"
/usr/bin/ditto "$QVAC_SOURCE/diarization.mjs" "$QVAC_RUNTIME/diarization.mjs"
/usr/bin/ditto "$QVAC_SOURCE/package.json" "$QVAC_RUNTIME/package.json"
/usr/bin/ditto "$QVAC_SOURCE/package-lock.json" "$QVAC_RUNTIME/package-lock.json"
/usr/bin/rsync -a --exclude='prebuilds/*' \
    --exclude='test/' --exclude='tests/' --exclude='__tests__/' \
    --exclude='examples/' --exclude='.github/' --exclude='.git/' \
    --exclude='.DS_Store' --exclude='*.log' \
    "$QVAC_SOURCE/node_modules/" "$QVAC_RUNTIME/node_modules/"
while IFS= read -r PREBUILD
do
    RELATIVE_PREBUILD=${PREBUILD#"$QVAC_SOURCE/"}
    /bin/mkdir -p "${QVAC_RUNTIME}/${RELATIVE_PREBUILD:h}"
    /bin/mkdir -p "$QVAC_RUNTIME/$RELATIVE_PREBUILD"
    /usr/bin/rsync -a --exclude='*.node' "$PREBUILD/" "$QVAC_RUNTIME/$RELATIVE_PREBUILD/"
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

/usr/bin/env node - "$PROJECT_ROOT" "$APP_BUNDLE/Contents/Resources" "$RELEASE_VERSION" "$RELEASE_BUILD" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')
const [project, resources, version, build] = process.argv.slice(2)
for (const name of ['BetaGuide', 'Privacy']) {
  const source = fs.readFileSync(path.join(project, 'Packaging', name + '.html'), 'utf8')
  fs.writeFileSync(path.join(resources, name + '.html'), source.replaceAll('@VERSION@', version).replaceAll('@BUILD@', build))
}
NODE
/usr/bin/env node "$SCRIPT_DIR/macos-notices.mjs" \
    "$APP_BUNDLE/Contents/Resources" \
    "${DROPSIFT_LEGAL_CACHE:-$PACKAGE_WORK/legal-cache}"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleVersion $RELEASE_BUILD" \
    "$APP_BUNDLE/Contents/Info.plist"

ICON_WORK=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dropsift-icon.XXXXXX")

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
SIGN_IDENTITY="$SIGN_IDENTITY" DROPSIFT_RELEASE="$RELEASE_MODE" \
    /usr/bin/env node "$SCRIPT_DIR/sign-macos.mjs" "$APP_BUNDLE"
VERIFY_OPTIONS=()
if [[ "$RELEASE_MODE" == "1" ]]; then VERIFY_OPTIONS+=(--release); fi
/usr/bin/env node "$SCRIPT_DIR/verify-macos-package.mjs" \
    "$APP_BUNDLE" "${VERIFY_OPTIONS[@]}" > "$DIST_DIR/package-verification.json"
"$APP_BUNDLE/Contents/MacOS/dropsift" doctor --package-resources \
    > "$DIST_DIR/package-resource-check.json"

DMG_WORK=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dropsift-dmg.XXXXXX")
/usr/bin/ditto "$APP_BUNDLE" "$DMG_WORK/DropSift.app"
/usr/bin/ditto "$APP_BUNDLE/Contents/Resources/BetaGuide.html" "$DMG_WORK/READ ME FIRST.html"
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

/usr/bin/env node - "$DIST_DIR" "$RELEASE_VERSION" "$RELEASE_BUILD" "$RELEASE_MODE" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')
const [directory, version, build, mode] = process.argv.slice(2)
fs.writeFileSync(path.join(directory, 'release-status.json'), JSON.stringify({
  version, build, signing: mode === '1' ? 'developer-id' : 'development-ad-hoc',
  notarized: false, shareReady: false,
  nextStep: 'Notarize, staple and pass Gatekeeper verification before sharing.'
}, null, 2))
NODE

print "Created (NOT SHARE READY until notarized):"
print "  $APP_ARCHIVE"
print "  $DMG_PATH"
