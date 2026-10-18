import fs from 'node:fs/promises'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { command, filesBelow, nativeFiles, minimumMacOS, versionExceeds, forbiddenPayload } from './macos-bundle.mjs'

const app = process.argv[2]
const release = process.argv.includes('--release')
const notarized = process.argv.includes('--notarized')
if (!app || !path.isAbsolute(app) || !app.endsWith('.app')) throw new Error('Pass an absolute app bundle path')
const plist = path.join(app, 'Contents/Info.plist')
const property = name => command('/usr/libexec/PlistBuddy', ['-c', `Print :${name}`, plist]).trim()
const minimum = property('LSMinimumSystemVersion')
const errors = []
const warnings = []
const allFiles = await filesBelow(app)
for (const file of allFiles) {
  if (forbiddenPayload(path.relative(app, file))) errors.push(`Unexpected private/model/test payload: ${path.relative(app, file)}`)
}
for (const name of ['BetaGuide.html', 'Privacy.html', 'ThirdPartyNotices.html', 'ThirdPartyManifest.json', 'mlx.metallib', 'swift-transformers_Hub.bundle', 'FluidAudio_FluidAudio.bundle']) {
  try { await fs.access(path.join(app, 'Contents/Resources', name)) }
  catch { errors.push(`Missing required resource: ${name}`) }
}
for (const name of ['NSMicrophoneUsageDescription', 'NSAudioCaptureUsageDescription']) {
  if (!property(name).trim()) errors.push(`Missing privacy purpose string: ${name}`)
}
const files = await nativeFiles(app)
const code = []
let team
for (const file of files) {
  const relative = path.relative(app, file)
  const arch = command('/usr/bin/lipo', ['-archs', file]).trim()
  if (!arch.split(/\s+/).includes('arm64')) errors.push(`Missing arm64: ${relative}`)
  const min = minimumMacOS(command('/usr/bin/otool', ['-l', file]))
  if (!min || versionExceeds(min, minimum)) errors.push(`Minimum macOS ${min ?? 'unknown'} exceeds ${minimum}: ${relative}`)
  const libraries = command('/usr/bin/otool', ['-L', file])
  if (/\n\s*\/(?:Users|opt|private|Volumes)\//.test(libraries)) errors.push(`Non-system absolute library dependency: ${relative}`)
  const verify = spawnSync('/usr/bin/codesign', ['--verify', '--strict', file], { encoding: 'utf8' })
  if (verify.status !== 0) errors.push(`Invalid code signature: ${relative}`)
  const description = spawnSync('/usr/bin/codesign', ['-d', '--verbose=4', file], { encoding: 'utf8' }).stderr
  const fileTeam = description.match(/^TeamIdentifier=(.+)$/m)?.[1]
  if (release) {
    if (!description.includes('Authority=Developer ID Application:')) errors.push(`Not signed with Developer ID Application: ${relative}`)
    if (!description.includes('Timestamp=')) errors.push(`Missing secure timestamp: ${relative}`)
    if (!fileTeam || fileTeam === 'not set') errors.push(`Missing signing team: ${relative}`)
    if (team && fileTeam !== team) errors.push(`Mixed signing teams: ${relative}`)
    team ??= fileTeam
    const isExecutable = relative === 'Contents/MacOS/dropsift' || relative.endsWith('/bin/bare')
    if (isExecutable && !/flags=.*runtime/.test(description)) errors.push(`Missing hardened runtime: ${relative}`)
    const entitlementDump = spawnSync('/usr/bin/codesign', ['-d', '--entitlements', ':-', file], { encoding: 'utf8' })
    const entitlements = entitlementDump.stdout + entitlementDump.stderr
    if (/com\.apple\.security\.(?:get-task-allow|cs\.disable-library-validation|cs\.allow-unsigned-executable-memory)/.test(entitlements)) errors.push(`Unexpected debug or broad runtime entitlement: ${relative}`)
  }
  code.push({ file: relative, architectures: arch, minimumMacOS: min, team: fileTeam })
}
command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app])
if (notarized) {
  for (const [file, args] of [
    ['/usr/bin/xcrun', ['stapler', 'validate', app]],
    ['/usr/sbin/spctl', ['--assess', '--type', 'execute', '--verbose=2', app]],
  ]) {
    const result = spawnSync(file, args, { encoding: 'utf8' })
    if (result.status !== 0) errors.push(`Notarization/Gatekeeper check failed: ${result.stderr || result.stdout}`)
  }
}
if (!release || !notarized) warnings.push('NOT SHARE READY: Developer ID signing, notarization and Gatekeeper acceptance are required.')
const report = { version: property('CFBundleShortVersionString'), build: property('CFBundleVersion'),
  bundleID: property('CFBundleIdentifier'), minimumMacOS: minimum, fileCount: allFiles.length,
  nativeFiles: code, errors, warnings, shareReady: release && notarized && errors.length === 0 }
console.log(JSON.stringify(report, null, 2))
if (errors.length) process.exitCode = 1
