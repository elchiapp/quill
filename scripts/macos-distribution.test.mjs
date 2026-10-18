import test from 'node:test'
import assert from 'node:assert/strict'
import { minimumMacOS, versionExceeds, forbiddenPayload, signingArguments } from './macos-bundle.mjs'

test('parses deployment targets, not dylib current versions', () => {
  assert.equal(minimumMacOS('cmd LC_BUILD_VERSION\n platform 1\n minos 13.0\n sdk 26.5\nLoad command 4\n current version 1700.0.0'), '13.0')
  assert.equal(minimumMacOS('cmd LC_VERSION_MIN_MACOSX\n version 15.0\n sdk 26.5'), '15.0')
  assert.equal(minimumMacOS('cmd LC_ID_DYLIB\n current version 2026.0'), null)
})
test('compares deployment versions numerically', () => {
  assert.equal(versionExceeds('15.1', '15.0'), true)
  assert.equal(versionExceeds('13.0', '15.0'), false)
  assert.equal(versionExceeds('15.0.0', '15.0'), false)
})
test('rejects credentials, model weights, recordings and private checkout data', () => {
  for (const file of ['AuthKey.p8', 'cert.p12', '.env', '.dropsift-private/secret', '.git/config', 'model.gguf', 'mic.caf', 'test.wav']) assert.equal(forbiddenPayload(file), true, file)
  for (const file of ['bridge.mjs', 'LICENSE', 'qvac.bare', 'logo.png', 'PrivateKeySchema.js']) assert.equal(forbiddenPayload(file), false, file)
})
test('release mode never falls back to ad-hoc signing', () => {
  assert.throws(() => signingArguments({ identity: '-', release: true }))
  assert.throws(() => signingArguments({ release: true }))
  assert.throws(() => signingArguments({ identity: 'Apple Development: Test', release: true }))
  const args = signingArguments({ identity: 'Developer ID Application: Explicit Approved Identity', release: true, entitlements: '/test/strict.plist' })
  assert.ok(args.includes('--timestamp'))
  assert.ok(args.includes('runtime'))
  assert.equal(args.includes('--deep'), false)
})
