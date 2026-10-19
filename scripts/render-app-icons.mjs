import fs from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'
import { createHash } from 'node:crypto'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const files = [
  'Packaging/DropsiftIcon.svg', 'Packaging/DropsiftIcon.png',
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
  console.log('Mac, iPhone and Watch icons match the SVG source.')
} else {
  const rendererRoot = process.argv[2]
  if (!rendererRoot || !path.isAbsolute(rendererRoot)) throw new Error('Pass an absolute local tool directory containing @resvg/resvg-js@2.6.2')
  const require = createRequire(path.join(rendererRoot, 'package.json'))
  const { Resvg } = require('@resvg/resvg-js')
  const version = require('@resvg/resvg-js/package.json').version
  if (version !== '2.6.2') throw new Error(`Expected renderer 2.6.2, found ${version}`)
  const svg = await fs.readFile(path.join(project, files[0]), 'utf8')
  const options = { fitTo: { mode: 'width', value: 1024 }, font: { loadSystemFonts: false } }
  await fs.writeFile(path.join(project, files[1]), new Resvg(svg, options).render().asPng())
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'dropsift-icon-export-'))
  try {
    const mobile = path.join(temporary, 'mobile.png')
    await fs.writeFile(mobile, new Resvg(svg, { ...options, background: '#111c1d' }).render().asPng())
    execFileSync('/usr/bin/xcrun', ['swift', '-module-cache-path', path.join(rendererRoot, 'swift-cache'),
      path.join(project, 'scripts/export-mobile-icon.swift'), mobile,
      path.join(project, files[2]), path.join(project, files[3])], { stdio: 'inherit' })
  } finally { await fs.rm(temporary, { recursive: true, force: true }) }
  await fs.writeFile(manifestPath, JSON.stringify({ renderer: '@resvg/resvg-js@2.6.2', sha256: await hashes() }, null, 2) + '\n')
  console.log('Exported all app icons from one vector source.')
}
