import fs from 'node:fs/promises'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

const magic = new Set(['cffaedfe', 'cefaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca'])

export async function filesBelow(root) {
  const files = []
  for (const item of await fs.readdir(root, { withFileTypes: true })) {
    const file = path.join(root, item.name)
    if (item.isDirectory()) files.push(...await filesBelow(file))
    else if (item.isFile()) files.push(file)
  }
  return files
}

export async function nativeFiles(root) {
  const result = []
  for (const file of await filesBelow(root)) {
    const handle = await fs.open(file, 'r')
    const bytes = Buffer.alloc(4)
    try { await handle.read(bytes, 0, 4, 0) } finally { await handle.close() }
    if (magic.has(bytes.toString('hex'))) result.push(file)
  }
  return result.sort((a, b) => b.split(path.sep).length - a.split(path.sep).length || a.localeCompare(b))
}

export function minimumMacOS(loadCommands) {
  const build = loadCommands.match(/cmd LC_BUILD_VERSION\b(?:(?!Load command)[\s\S])*?\bminos\s+([\d.]+)/)
  if (build) return build[1]
  return loadCommands.match(/cmd LC_VERSION_MIN_MACOSX\b(?:(?!Load command)[\s\S])*?\bversion\s+([\d.]+)/)?.[1] ?? null
}

export function versionExceeds(actual, supported) {
  const a = actual.split('.').map(Number), b = supported.split('.').map(Number)
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0)
  }
  return false
}

export function forbiddenPayload(relative) {
  const name = path.basename(relative)
  return /\.(?:p8|p12|pfx|mobileprovision|pem|key|gguf|safetensors|caf|m4a|wav)$/i.test(name)
    || name.startsWith('.env') || ['.DS_Store', '.npmrc', '.netrc'].includes(name)
    || /(?:^|\/)\.(?:git|dropsift-private)(?:\/|$)/.test(relative)
}

export function signingArguments({ identity, release, entitlements }) {
  if (release && (!identity || identity === '-')) throw new Error('A friends release requires an explicit Developer ID Application identity')
  if (release && !/^Developer ID Application: .+/.test(identity) && !/^[a-f0-9]{40}$/i.test(identity)) {
    throw new Error('Release signing requires a Developer ID Application name or its exact SHA-1 identity fingerprint')
  }
  const args = ['--force', '--sign', identity || '-']
  if (release) {
    args.push('--timestamp', '--options', 'runtime')
    if (entitlements) args.push('--entitlements', entitlements)
  } else args.push('--timestamp=none')
  return args
}

export function command(file, args) {
  return execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
}
