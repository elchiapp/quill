import { spawn } from 'node:child_process'
import fs from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import os from 'node:os'

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const root = process.argv[2]
if (!root || !path.isAbsolute(root)) throw new Error('Pass an absolute isolated benchmark workspace')
const evidence = path.join(root, 'evidence')
const audio = path.join(root, 'audio')
const recording = process.argv[3] ?? process.env.DROPSIFT_BENCHMARK_RECORDING
if (!recording || !path.isAbsolute(recording)) throw new Error('Pass the recording directory as the second argument')
const modelCache = process.argv[4] ?? path.join(os.homedir(), 'Library/Caches/Dropsift/QVAC/Models')
const oldRuntime = '/Applications/DropSift.app/Contents/Resources/QVACRuntime'
const newRuntime = path.join(project, 'QVACBridge')
const model = path.join(modelCache, 'cefd830cf8c3dc92_parakeet-tdt-0.6b-v3.q8_0.gguf')
const coremlModel = JSON.parse(await fs.readFile(path.join(evidence, 'stage-coreml/result.json'))).speechModelPath
const nativeLLM = path.join(evidence, 'native-llm')
const baseEnv = { ...process.env, DROPSIFT_BENCHMARK_REPEATS: '3',
  DROPSIFT_BENCHMARK_AUDIO: audio,
  DROPSIFT_BENCHMARK_RECORDING: recording }

function qvac(name, runtime, action, modelPath) {
  const args = [path.join(project, 'scripts/benchmark-qvac.mjs'), '--runtime-root', runtime,
    '--work-dir', path.join(evidence, name), '--action', action,
    '--model-cache', modelCache, '--audio-root', audio, '--repeat', '3', '--label', name]
  if (modelPath) args.push('--model-path', modelPath)
  if (action === 'llm') args.push('--prompts-file', path.join(nativeLLM, 'workloads.json'))
  return { name, command: process.execPath, args }
}
const native = lane => ({ name: `native-${lane}`, command: 'swift',
  args: ['test', '-c', 'release', '--skip-build', '--filter', 'measureNativeBackendPerformance'],
  env: { ...baseEnv, DROPSIFT_NATIVE_BENCHMARK: lane,
    DROPSIFT_BENCHMARK_OUTPUT: path.join(evidence, `native-${lane}`, 'result.json') } })
const psy = (name, backend, modelFile) => ({ name, command: path.join(root, 'transcribepsy-benchmark'),
  args: [modelFile, audio, path.join(evidence, name), backend, '3'] })
const cases = [
  qvac('legacy-qvac-asr', oldRuntime, 'asr'),
  native('asr'),
  qvac('qvac-metal-asr', newRuntime, 'asr', model),
  qvac('qvac-coreml-asr', newRuntime, 'asr', coremlModel),
  psy('transcribepsy-metal', 'metal', path.join(root, 'models/gguf/transcribepsy-250m-eu-sub.gguf')),
  psy('transcribepsy-coreml', 'coreml', path.join(root, 'models/coreml/transcribepsy-250m-eu-sub-coreml.gguf')),
  native('llm'),
  qvac('qvac-llm', newRuntime, 'llm'),
  qvac('legacy-qvac-llm', oldRuntime, 'llm')
]
const summary = []
for (const entry of cases) {
  const caseDir = path.join(evidence, entry.name)
  await fs.mkdir(caseDir, { recursive: true })
  const startedAt = new Date().toISOString()
  console.log(`BEGIN ${entry.name} ${startedAt}`)
  const started = performance.now()
  const child = spawn(entry.command, entry.args, { cwd: project, env: entry.env ?? baseEnv,
    stdio: ['ignore', 'pipe', 'pipe'] })
  child.stdout.on('data', data => {
    void fs.appendFile(path.join(caseDir, 'stdout.log'), data)
    for (const line of data.toString().split('\n')) {
      if (/completed in|NATIVE_(ASR|MLX)|TRANSCRIBEPSY|BENCHMARK_ERROR/.test(line)) console.log(line)
    }
  })
  child.stderr.on('data', data => { void fs.appendFile(path.join(caseDir, 'stderr.log'), data) })
  const timer = setTimeout(() => { console.log(`TIMEOUT ${entry.name}`); child.kill('SIGTERM') }, 20 * 60 * 1000)
  const exitCode = await new Promise(resolve => {
    child.on('error', error => { console.log(`${entry.name}: ${error.message}`); resolve(-1) })
    child.on('exit', code => resolve(code))
  })
  clearTimeout(timer)
  const seconds = (performance.now() - started) / 1000
  summary.push({ name: entry.name, startedAt, finishedAt: new Date().toISOString(), seconds, exitCode })
  await fs.writeFile(path.join(evidence, 'matrix.json'), JSON.stringify(summary, null, 2))
  console.log(`END ${entry.name} exit=${exitCode} total=${seconds.toFixed(2)}s`)
}
