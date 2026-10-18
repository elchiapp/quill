import fs from 'node:fs/promises'
import path from 'node:path'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { filesBelow } from './macos-bundle.mjs'

const [resources, cache] = process.argv.slice(2)
if (![resources, cache].every(value => value && path.isAbsolute(value))) throw new Error('Usage: macos-notices RESOURCES_DIR LOCAL_LEGAL_CACHE')
const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const sha = bytes => createHash('sha256').update(bytes).digest('hex')
const escape = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;')
const licenseName = /(?:^|[._-])(?:licen[sc]e|copying|notice|copyright)(?:[._-]|$)/i
await fs.mkdir(resources, { recursive: true })
await fs.mkdir(cache, { recursive: true })
const sections = []
const components = []
const downloads = []
const declaredOnly = []

async function addFile(component, file, relative) {
  const bytes = await fs.readFile(file)
  const text = bytes.toString('utf8')
  if (text.includes('\0')) throw new Error(`Binary license file: ${file}`)
  sections.push({ component, file: relative, text })
  return { file: relative, sha256: sha(bytes) }
}

async function cached(url, name) {
  const file = path.join(cache, name)
  let bytes
  try { bytes = await fs.readFile(file) }
  catch (error) {
    if (error.code !== 'ENOENT') throw error
    console.log(`Fetching public license/source: ${name}`)
    const response = await fetch(url)
    if (!response.ok) throw new Error(`${response.status} fetching ${url}`)
    bytes = Buffer.from(await response.arrayBuffer())
    await fs.writeFile(file, bytes)
  }
  downloads.push({ name, url, bytes: bytes.length, sha256: sha(bytes) })
  return { file, bytes }
}

const upstream = path.join(project, 'Packaging/Licenses/Quill-MIT.txt')
components.push({ name: 'Quill upstream', version: 'aad60f98e680720dd24a30115580f226ae36c12c',
  source: 'https://github.com/humanitas-labs/quill', license: 'MIT',
  notices: [await addFile('Quill upstream', upstream, 'Quill-MIT.txt')] })

const swift = JSON.parse(await fs.readFile(path.join(project, 'Package.resolved'), 'utf8')).pins
const missing = []
for (const entry of swift) {
  const candidates = await fs.readdir(path.join(project, '.build/checkouts'), { withFileTypes: true })
  const directory = candidates.find(item => item.isDirectory() && item.name.toLowerCase() === entry.identity)
  if (!directory) throw new Error(`Missing Swift checkout ${entry.identity}`)
  const root = path.join(project, '.build/checkouts', directory.name)
  const notices = []
  for (const file of await filesBelow(root)) {
    const relative = path.relative(root, file)
    if (relative.split(path.sep).some(part => ['.git', '.build'].includes(part))) continue
    if (licenseName.test(path.basename(file))) notices.push(await addFile(entry.identity, file, relative))
  }
  if (!notices.length) missing.push(`swift:${entry.identity}`)
  components.push({ name: entry.identity, version: entry.state.version ?? entry.state.revision,
    source: entry.location, notices })
}

const modules = path.join(resources, 'QVACRuntime/node_modules')
for (const file of await filesBelow(modules)) {
  if (path.basename(file) !== 'package.json') continue
  const relativeParts = path.relative(modules, file).split(path.sep)
  const packageParts = relativeParts.slice(relativeParts.lastIndexOf('node_modules') + 1)
  if (packageParts.length !== (packageParts[0].startsWith('@') ? 3 : 2)) continue
  const entry = JSON.parse(await fs.readFile(file, 'utf8'))
  if (!entry.name || !entry.version) continue
  const root = path.dirname(file)
  const notices = []
  for (const candidate of await fs.readdir(root, { withFileTypes: true })) {
    if (candidate.isFile() && licenseName.test(candidate.name)) notices.push(await addFile(entry.name, path.join(root, candidate.name), candidate.name))
  }
  // Some published tarballs declare a standard SPDX license but omit the
  // standalone text. Preserve that declaration and README verbatim, disclose
  // the missing original text, and include a clearly labeled SPDX template.
  if (!notices.length && ['Apache-2.0', 'MIT', 'ISC'].includes(entry.license)) {
    const id = `${entry.name}@${entry.version}`
    const standard = await cached(`https://raw.githubusercontent.com/spdx/license-list-data/v3.27.0/text/${entry.license}.txt`, `SPDX-${entry.license}.txt`)
    const readmeName = (await fs.readdir(root)).find(name => /^readme/i.test(name))
    const readme = readmeName ? await fs.readFile(path.join(root, readmeName), 'utf8') : ''
    const text = `Published package declaration (not a new license grant):\n${JSON.stringify({name:entry.name,version:entry.version,license:entry.license,author:entry.author,repository:entry.repository},null,2)}\n\nThis tarball supplies no standalone license text. The original README follows. The SPDX standard text is reproduced after it as a template, not as an assertion that its example/placeholder copyright holders own this component. Review source-specific attribution before a public release.\n\n${readme}\n\nSPDX standard template:\n${standard.bytes.toString('utf8')}`
    sections.push({component:id,file:'published-license-declaration + SPDX standard template',text})
    notices.push({file:'published-license-declaration + SPDX standard template',sha256:sha(Buffer.from(text))})
    declaredOnly.push(id)
  }
  if (!notices.length) missing.push(`npm:${entry.name}@${entry.version}`)
  components.push({ name: entry.name, version: entry.version, license: entry.license,
    source: typeof entry.repository === 'string' ? entry.repository : entry.repository?.url,
    notices })
}

const extra = [
  ['NeMo text processing / Apache-2.0', 'nemo-NOTICE.txt', 'https://raw.githubusercontent.com/FluidInference/text-processing-rs/v0.3.1/NOTICE'],
  ['NeMo text processing / transitive static libraries', 'nemo-third-party.txt', 'https://raw.githubusercontent.com/FluidInference/text-processing-rs/v0.3.1/THIRD-PARTY-LICENSES.md'],
  ['FFmpeg / LGPL-2.1-or-later', 'ffmpeg-LGPL-2.1.txt', 'https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.1.1/COPYING.LGPLv2.1'],
  ['bare-ffmpeg / Apache-2.0', 'bare-ffmpeg-NOTICE.txt', 'https://raw.githubusercontent.com/holepunchto/bare-ffmpeg/v1.5.0/NOTICE'],
  ['libvpx', 'libvpx-LICENSE.txt', 'https://raw.githubusercontent.com/webmproject/libvpx/v1.15.0/LICENSE'],
  ['libvpx patent grant', 'libvpx-PATENTS.txt', 'https://raw.githubusercontent.com/webmproject/libvpx/v1.15.0/PATENTS'],
  ['Opus', 'opus-COPYING.txt', 'https://raw.githubusercontent.com/xiph/opus/v1.5.2/COPYING'],
  ['SVT-AV1', 'svt-av1-LICENSE.txt', 'https://gitlab.com/AOMediaCodec/SVT-AV1/-/raw/v2.3.0/LICENSE.md'],
  ['dav1d', 'dav1d-COPYING.txt', 'https://raw.githubusercontent.com/videolan/dav1d/1.5.1/COPYING'],
  ['V8 embedded in Bare', 'v8-LICENSE.txt', 'https://raw.githubusercontent.com/v8/v8/14.8.178.31/LICENSE'],
  ['libuv embedded in Bare', 'libuv-LICENSE.txt', 'https://raw.githubusercontent.com/libuv/libuv/v1.52.1/LICENSE'],
]
for (const [component, name, url] of extra) {
  const { file } = await cached(url, name)
  await addFile(component, file, name)
}
// Source and relinking material travels inside the app, so forwarding just the
// app or its ZIP does not drop the FFmpeg source bundle from the distribution.
const sourceDir = path.join(resources, 'ThirdPartySources')
await fs.mkdir(sourceDir, { recursive: true })
await fs.copyFile(path.join(project, 'scripts/prepare-package-resources.mjs'), path.join(sourceDir, 'DropSift-resource-compatibility.mjs'))
sections.push({component:'DropSift resource compatibility modifications',file:'DropSift-resource-compatibility.mjs',text:
  'DropSift modifies Swift Transformers Hub.swift and FluidAudio LuxTtsG2p.swift to resolve resource bundles from Contents/Resources in a signed macOS app. Original licenses are retained. The exact idempotent source-edit script is included in ThirdPartySources. No model weights or inference algorithms are changed.'})
const archive = await cached('https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n8.1.1', 'FFmpeg-n8.1.1.tar.gz')
await fs.copyFile(archive.file, path.join(sourceDir, 'FFmpeg-n8.1.1.tar.gz'))
const wrapperArchive = path.join(sourceDir, 'bare-ffmpeg-1.5.0-source.tar.gz')
execFileSync('/usr/bin/tar', ['-czf', wrapperArchive, '--exclude=./prebuilds',
  '-C', path.join(project, 'QVACBridge/node_modules/bare-ffmpeg'), '.'])
await fs.writeFile(path.join(sourceDir, 'REBUILD.txt'), `FFmpeg source and relinking information

DropSift includes FFmpeg through the separately loadable bare-ffmpeg 1.5.0
native module. The wrapper source, its CMake port recipe, and the complete
FFmpeg n8.1.1 source are included beside this file. No modifications to these
upstream sources were made for this package.

The vendor's default BARE_FFMPEG_ENABLE_GPL option is OFF. Its port builds
FFmpeg with --disable-autodetect, --disable-doc, --disable-programs,
--disable-network, --enable-pic, and --enable-cross-compile. The CMake port
files give the full platform configuration and dependency revisions.

Rebuild the wrapper using the official instructions in its README and
https://github.com/holepunchto/bare-make : install the declared build tools,
run bare-make generate with BARE_FFMPEG_ENABLE_GPL=OFF, then bare-make build
and bare-make install. Use the matching macOS arm64 target and Bare ABI.
The separately loadable result replaces node_modules/bare-ffmpeg/prebuilds/
darwin-arm64/bare-ffmpeg.bare inside the app's QVACRuntime directory.

An altered application needs to be signed again by its builder. Use your own
approved identity and the supplied signing script. Do not disable Gatekeeper
or system security settings. DropSift imposes no additional prohibition on
modifying or reverse engineering LGPL components for debugging modifications.
Their original licenses govern those components.

Native prebuilds came from the pinned public npm packages. The release
manifest records their hashes. A source inventory is not a legal clearance
opinion or a substitute for reviewing vendor build provenance.
`)

const css = 'body{font:14px/1.5 Arial,Helvetica,sans-serif;max-width:950px;margin:30px auto;padding:0 18px;color:#182332}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:12px}details{border-top:1px solid #ddd;padding:12px 0}summary{cursor:pointer;font-weight:bold}a{color:#1260b4}'
const heading = `<h1>DropSift — Open-source notices</h1><p>DropSift incorporates software under the licenses reproduced below. These notices do not assign a single new license to all DropSift-specific work. Model weights download separately and retain their own terms.</p><p>This software uses libraries from the FFmpeg project under the LGPLv2.1 or later. <a href="ThirdPartySources/REBUILD.txt">Source and rebuild information</a> and the full source archives are included inside this app. The wrapper is separately loadable.</p><p>${components.length} package/component records. ${missing.length} missing license declarations require review. ${declaredOnly.length} published packages declare a standard license without a standalone text; their metadata, README and a labeled SPDX template are retained. Vendor NOTICE files can name optional or build-only components that are not present in this binary. This is an engineering inventory, not legal advice or a public-release legal clearance.</p>`
await fs.writeFile(path.join(resources, 'ThirdPartyNotices.html'), `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>DropSift — Open-source notices</title><style>${css}</style>${heading}${sections.map(item => `<details><summary>${escape(item.component)} — ${escape(item.file)}</summary><pre>${escape(item.text)}</pre></details>`).join('')}</html>`)
await fs.writeFile(path.join(resources, 'ThirdPartyNotices.txt'), sections.map(item => `${item.component} — ${item.file}\n${'='.repeat(72)}\n${item.text}\n`).join('\n'))
const manifest = { components, externalSources: downloads, missingLicenseTexts: missing, declaredLicenseOnly: declaredOnly,
  sourceArchives: [archive.file, wrapperArchive].map(file => path.basename(file)),
  scope: 'Bundled software and known static/native dependencies; model weights are not included.' }
await fs.writeFile(path.join(resources, 'ThirdPartyManifest.json'), JSON.stringify(manifest, null, 2))
console.log(JSON.stringify({ components: components.length, noticeFiles: sections.length, missing, declaredOnly }))
if (missing.length) process.exitCode = 1
