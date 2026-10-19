import fs from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const files = [
  'Packaging/DropsiftIconMaster.png', 'Packaging/DropsiftIcon.png',
  'Mobile/Assets/MobileAssets.xcassets/AppIcon.appiconset/AppIcon-1024.png',
  'Mobile/Assets/WatchAssets.xcassets/AppIcon.appiconset/WatchIcon-1024.png'
]
const manifestPath = path.join(project, 'Packaging/DropsiftIcon.render.json')
const hashes = async () => Object.fromEntries(await Promise.all(files.map(async file =>
  [file, createHash('sha256').update(await fs.readFile(path.join(project, file))).digest('hex')]
)))
if (process.argv[2] === '--check') {
  const manifest = JSON.parse(await fs.readFile(manifestPath, 'utf8'))
  const current = await hashes()
  for (const file of files) if (manifest.sha256[file] !== current[file]) throw new Error(`Stale icon export: ${file}`)
  console.log('Mac, iPhone and Watch icons match the master artwork.')
} else {
  const cacheRoot = process.argv[2] ?? path.join(os.tmpdir(), 'dropsift-icon-compiler-cache')
  if (!path.isAbsolute(cacheRoot)) throw new Error('Pass an absolute local compiler cache directory')
  await fs.mkdir(cacheRoot, { recursive: true })
  execFileSync('/usr/bin/xcrun', ['swift', '-module-cache-path', cacheRoot,
    path.join(project, 'scripts/export-mobile-icon.swift'), ...files.map(file => path.join(project, file))], { stdio: 'inherit' })
  await fs.writeFile(manifestPath, JSON.stringify({ renderer: 'Apple Core Graphics; built-in imagegen master', sha256: await hashes() }, null, 2) + '\n')
  console.log('Exported all app icons from the 3D master artwork.')
}
