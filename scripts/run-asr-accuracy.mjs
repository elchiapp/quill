import { spawn } from 'node:child_process'
import fs from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const [root, psyModel, parakeetModel, runtime = '/Applications/DropSift.app/Contents/Resources/QVACRuntime'] = process.argv.slice(2)
if (![root, psyModel, parakeetModel, runtime].every(value => value && path.isAbsolute(value))) {
  throw new Error('Usage: run-asr-accuracy WORKSPACE TRANSCRIBEPSY_GGUF PARAKEET_GGUF [RUNTIME_ROOT]')
}
const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const manifest = path.join(root, 'manifest.json')
const env = { ...process.env, DROPSIFT_BENCHMARK_REPEATS: '3' }
const entries = [
  { name: 'native', command: 'swift', args: ['test', '-c', 'release', '--skip-build', '--filter', 'benchmarkNativeASRAccuracySamples'],
    env: { ...env, DROPSIFT_ASR_ACCURACY_MANIFEST: manifest,
      DROPSIFT_ASR_ACCURACY_OUTPUT: path.join(root, 'native/result.json') } },
  ...[['qvac-transcribepsy', psyModel], ['qvac-parakeet', parakeetModel]].map(([name, model]) => ({
    name, command: process.execPath, env, args: [path.join(project, 'scripts/benchmark-qvac.mjs'),
      '--runtime-root', runtime, '--work-dir', path.join(root, name), '--action', 'samples',
      '--samples-file', manifest, '--model-path', model, '--repeat', '3', '--label', name,
      '--chunk-seconds', process.env.DROPSIFT_ASR_CHUNK_SECONDS ?? '60']
  }))
]
const from = process.env.DROPSIFT_ASR_ACCURACY_FROM
const index = from ? entries.findIndex(entry => entry.name === from) : 0
if (index < 0) throw new Error('Unknown resume lane')
let matrix = []
if (from) {
  try { matrix = JSON.parse(await fs.readFile(path.join(root, 'matrix.json'), 'utf8')) }
  catch (error) { if (error.code !== 'ENOENT') throw error }
}
for (const entry of entries.slice(index)) {
  const output = path.join(root, entry.name)
  await fs.mkdir(output, { recursive: true })
  const startedAt = new Date().toISOString()
  console.log(`BEGIN ${entry.name} ${startedAt}`)
  const started = performance.now()
  const child = spawn(entry.command, entry.args, { cwd: project, env: entry.env, stdio: ['ignore', 'pipe', 'pipe'] })
  let count = 0
  child.stdout.on('data', bytes => {
    void fs.appendFile(path.join(output, 'stdout.log'), bytes)
    count += bytes.toString().split('\n').filter(line => /run=/.test(line)).length
    if (count >= 25) { console.log(`${entry.name}: progressing through samples`); count = 0 }
  })
  child.stderr.on('data', bytes => { void fs.appendFile(path.join(output, 'stderr.log'), bytes) })
  const timer = setTimeout(() => child.kill('SIGTERM'), 15 * 60_000)
  const exitCode = await new Promise(resolve => {
    child.on('error', error => { console.log(String(error)); resolve(-1) })
    child.on('exit', code => resolve(code))
  })
  clearTimeout(timer)
  matrix.push({ lane: entry.name, startedAt, finishedAt: new Date().toISOString(),
    wallSeconds: (performance.now() - started) / 1000, exitCode })
  await fs.writeFile(path.join(root, 'matrix.json'), JSON.stringify(matrix, null, 2))
  console.log(`END ${entry.name} exit=${exitCode}`)
  if (exitCode !== 0) { process.exitCode = 1; break }
}
