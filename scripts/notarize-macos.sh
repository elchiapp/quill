#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
DIST_DIR=${1:-}
NOTARY_PROFILE=${2:-}
SIGN_IDENTITY=${SIGN_IDENTITY:-}
if [[ "$DIST_DIR" != /* || -z "$NOTARY_PROFILE" || -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
    print -u2 "Usage: SIGN_IDENTITY='exact approved Developer ID identity' scripts/notarize-macos.sh /absolute/artifacts exact-approved-notary-profile"
    print -u2 "This uses existing credentials only. It never creates a keychain profile or imports a key."
    exit 1
fi
ARCHIVE="$DIST_DIR/DropSift.app.zip"
DMG="$DIST_DIR/DropSift.dmg"
[[ -f "$ARCHIVE" ]] || { print -u2 "Missing signed app archive: $ARCHIVE"; exit 1; }
NOTARY_WORK=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dropsift-notary.XXXXXX")
cleanup() { /bin/rm -rf "$NOTARY_WORK"; }
trap cleanup EXIT
/usr/bin/ditto -x -k "$ARCHIVE" "$NOTARY_WORK"
APP="$NOTARY_WORK/DropSift.app"
# Validate certificate type, timestamps, hardened runtime and every nested
# signature before requesting access to the explicitly supplied notary profile.
/usr/bin/env node "$SCRIPT_DIR/verify-macos-package.mjs" "$APP" --release \
    > "$DIST_DIR/prenotarization-verification.json"
"$APP/Contents/MacOS/dropsift" doctor --package-resources \
    > "$DIST_DIR/package-resource-check.json"

submit() {
    local payload=$1
    local result=$2
    /usr/bin/xcrun notarytool submit "$payload" \
        --keychain-profile "$NOTARY_PROFILE" --output-format json --wait > "$result"
    /usr/bin/env node - "$result" <<'NODE'
const fs = require('node:fs')
const result = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
if (result.status !== 'Accepted') {
  console.error('Notarization was not accepted. Submission:', result.id, 'Status:', result.status)
  process.exit(1)
}
console.log('Apple accepted submission', result.id)
NODE
}

submit "$ARCHIVE" "$DIST_DIR/notarization-app.json"
/usr/bin/xcrun stapler staple "$APP"
/usr/bin/env node "$SCRIPT_DIR/verify-macos-package.mjs" "$APP" --release --notarized \
    > "$DIST_DIR/app-release-verification.json"
/usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"

IMAGE_ROOT="$NOTARY_WORK/image"
/bin/mkdir -p "$IMAGE_ROOT"
/usr/bin/ditto "$APP" "$IMAGE_ROOT/DropSift.app"
/usr/bin/ditto "$APP/Contents/Resources/BetaGuide.html" "$IMAGE_ROOT/READ ME FIRST.html"
/bin/ln -s /Applications "$IMAGE_ROOT/Applications"
/usr/bin/hdiutil create -quiet -volname "DropSift" -srcfolder "$IMAGE_ROOT" -ov -format UDZO "$DMG"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
/usr/bin/codesign --verify --strict "$DMG"
submit "$DMG" "$DIST_DIR/notarization-dmg.json"
/usr/bin/xcrun stapler staple "$DMG"
/usr/bin/xcrun stapler validate "$DMG"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

/usr/bin/env node - "$DIST_DIR" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')
const { createHash } = require('node:crypto')
const root = process.argv[2]
const verification = JSON.parse(fs.readFileSync(path.join(root, 'app-release-verification.json'), 'utf8'))
if (!verification.shareReady) throw new Error('App release verification did not pass')
const hashes = ['DropSift.app.zip', 'DropSift.dmg'].map(name => ({name,
  sha256:createHash('sha256').update(fs.readFileSync(path.join(root,name))).digest('hex')}))
fs.writeFileSync(path.join(root, 'SHA256SUMS.txt'), hashes.map(x=>x.sha256+'  '+x.name).join('\n')+'\n')
fs.writeFileSync(path.join(root, 'release-status.json'), JSON.stringify({
  version:verification.version, build:verification.build, signing:'developer-id',
  notarized:true, gatekeeper:'accepted', shareReady:true, artifacts:hashes
}, null, 2))
NODE
print "Share-ready app and disk image verified: $DIST_DIR"
