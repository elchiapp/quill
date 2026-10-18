import fs from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const patches = [
  { file: 'swift-transformers/Sources/Hub/Hub.swift',
    before: '        guard let url = Bundle.module.url(forResource: fallbackTokenizerConfigBaseName, withExtension: "json") else {',
    after: `        // DropSift distribution compatibility: SwiftPM's CLI accessor looks in
        // the .app root, but signed macOS apps keep resources under Contents.
        let distributionBundle = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("swift-transformers_Hub.bundle"))
        }
        let resourceBundle = distributionBundle ?? Bundle.module
        guard let url = resourceBundle.url(forResource: fallbackTokenizerConfigBaseName, withExtension: "json") else {` },
  { file: 'FluidAudio/Sources/FluidAudio/TTS/LuxTts/G2p/LuxTtsG2p.swift',
    before: `    public init() throws {
        guard
            let lexiconURL = Bundle.module.url(
                forResource: "luxtts_en_us_lexicon.tsv", withExtension: "zz"),
            let auxURL = Bundle.module.url(`,
    after: `    public init() throws {
        // DropSift distribution compatibility: prefer the signed app's resource
        // directory over SwiftPM's generated CLI/build-directory fallback.
        let distributionBundle = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("FluidAudio_FluidAudio.bundle"))
        }
        let resourceBundle = distributionBundle ?? Bundle.module
        guard
            let lexiconURL = resourceBundle.url(
                forResource: "luxtts_en_us_lexicon.tsv", withExtension: "zz"),
            let auxURL = resourceBundle.url(` }
]
for (const patch of patches) {
  const file = path.join(project, '.build/checkouts', patch.file)
  const source = await fs.readFile(file, 'utf8')
  if (source.includes(patch.after)) continue
  if (source.split(patch.before).length !== 2) throw new Error(`Dependency changed; review the resource patch before building: ${patch.file}`)
  const mode = (await fs.stat(file)).mode & 0o777
  // Write in place to preserve existing File Provider exclusion attributes
  // and flags. Never reset a checkout or touch unrelated dependency changes.
  await fs.chmod(file, mode | 0o200)
  try { await fs.writeFile(file, source.replace(patch.before, patch.after)) }
  finally { await fs.chmod(file, mode) }
}
