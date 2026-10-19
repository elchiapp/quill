// Isolated, sequential lanes. No concurrent inference contaminates the comparison.
import { spawn } from 'node:child_process'
import fs from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const [root, runtime, psy, parakeet, coreml] = process.argv.slice(2)
if (![root, runtime, psy, parakeet, coreml].every(p => p && path.isAbsolute(p))) {
  throw new Error('Usage: run-speech-matrix ROOT RUNTIME PSY_GGUF PARAKEET_GGUF PARAKEET_COREML_GGUF')
}
const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const manifest = path.join(root, 'data/manifest.json')
await fs.mkdir(path.join(root, 'lanes'), { recursive: true })
const entries = []
// Metal first gives a useful baseline before the slower CPU stress lanes.
for (const acceleration of ['metal', 'cpu', 'coreml']) {
  for (const model of ['parakeet', 'transcribepsy']) {
    if (model === 'transcribepsy' && acceleration === 'coreml') continue
    for (const route of ['sdk', 'fabricDirect']) {
      const name = `${route}-${model}-${acceleration}`
      entries.push({ name, command: process.execPath, args: [path.join(project, 'scripts/benchmark-qvac.mjs'),
        '--runtime-root', runtime, '--work-dir', path.join(root, 'lanes', name), '--action', 'samples',
        '--samples-file', manifest, '--model-path', acceleration === 'coreml' ? coreml : model === 'parakeet' ? parakeet : psy,
        '--speech-route', route, '--speech-model', model, '--acceleration', acceleration,
        '--repeat', '3', '--long-repeat', '1', '--label', name] })
    }
  }
}
for (const compute of ['default', 'cpu', 'gpu']) {
  const name = `native-${compute}`
  entries.push({ name, command: 'swift', args: ['test', '-c', 'release', '--skip-build', '--filter', 'benchmarkNativeASRAccuracySamples'],
    env: { DROPSIFT_ASR_ACCURACY_MANIFEST: manifest, DROPSIFT_ASR_ACCURACY_OUTPUT: path.join(root, 'lanes', name, 'result.json'),
      DROPSIFT_BENCHMARK_REPEATS: '3', DROPSIFT_BENCHMARK_LONG_REPEATS: '1', DROPSIFT_NATIVE_COMPUTE: compute } })
}
let matrix = []
try { matrix = JSON.parse(await fs.readFile(path.join(root, 'matrix.json'), 'utf8')) } catch (error) {
  if (error.code !== 'ENOENT') throw error
}
for (const entry of entries) {
  if (matrix.some(row => row.lane === entry.name && row.exitCode === 0)) continue
  const output = path.join(root, 'lanes', entry.name)
  await fs.mkdir(output, { recursive: true })
  const startedAt = new Date().toISOString()
  console.log(`BEGIN ${entry.name} ${startedAt}`)
  const start = performance.now()
  const child = spawn(entry.command, entry.args, { cwd: project, env: { ...process.env, ...entry.env }, stdio: ['ignore', 'pipe', 'pipe'] })
  let count = 0
  child.stdout.on('data', bytes => {
    void fs.appendFile(path.join(output, 'stdout.log'), bytes).catch(error => console.error('Evidence write failed: '+error.message))
    count += bytes.toString().split('\n').filter(line => /run=/.test(line)).length
    if (count >= 40) { console.log(`${entry.name}: another ${count} measured samples`); count = 0 }
  })
  child.stderr.on('data', bytes => { void fs.appendFile(path.join(output, 'stderr.log'), bytes).catch(error => console.error('Evidence write failed: '+error.message)) })
  const timer = setTimeout(() => child.kill('SIGTERM'), 45 * 60_000)
  const exitCode = await new Promise(resolve => {
    child.once('error', error => { console.error(String(error)); resolve(-1) })
    child.once('exit', code => resolve(code))
  })
  clearTimeout(timer)
  matrix.push({ lane: entry.name, startedAt, finishedAt: new Date().toISOString(), wallSeconds: (performance.now() - start) / 1000, exitCode })
  await fs.writeFile(path.join(root, 'matrix.json'), JSON.stringify(matrix, null, 2))
  console.log(`END ${entry.name} exit=${exitCode}`)
  // A failing lane does not prevent independent routes from being tested.
}
console.log('MATRIX FINISHED. Review individual errors and coverage; exit zero alone is not a pass.')
