import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { command, nativeFiles, signingArguments } from './macos-bundle.mjs'

const app = process.argv[2]
if (!app || !path.isAbsolute(app) || !app.endsWith('/DropSift.app')) throw new Error('Pass the staged DropSift.app absolute path')
const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const identity = process.env.SIGN_IDENTITY || '-'
const release = process.env.DROPSIFT_RELEASE === '1'
// No identity discovery, key import, ACL changes, keychain search-list changes,
// or credential storage. The operator supplies one approved identity explicitly.
signingArguments({ identity, release })
const main = path.join(app, 'Contents/MacOS/dropsift')
const helper = path.join(app, 'Contents/Resources/QVACRuntime/node_modules/bare-runtime-darwin-arm64/bin/bare')
for (const file of await nativeFiles(app)) {
  if (file === main) continue // The enclosing bundle signs its main executable last.
  const entitlements = file === helper ? path.join(project, 'Packaging/QVACRuntime.entitlements') : undefined
  command('/usr/bin/codesign', [...signingArguments({ identity, release, entitlements }), file])
}
command('/usr/bin/codesign', [...signingArguments({ identity, release,
  entitlements: path.join(project, 'Packaging/DropSift.entitlements') }), app])
command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app])
console.log(release ? 'Signing completed; certificate verification and notarization are still required.' : 'Development signing completed. This is NOT a share-ready build.')
