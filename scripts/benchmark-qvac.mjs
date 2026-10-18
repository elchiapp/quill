import { execFile, spawn } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import fs from 'node:fs/promises'
import path from 'node:path'
import { parseArgs } from 'node:util'
import { performance } from 'node:perf_hooks'

const { values } = parseArgs({ options: {
  'runtime-root': { type: 'string' },
  'work-dir': { type: 'string' },
  'model-cache': { type: 'string' },
  'model-path': { type: 'string' },
  'audio-root': { type: 'string' },
  'prompts-file': { type: 'string' },
  action: { type: 'string', default: 'smoke' },
  repeat: { type: 'string', default: '3' },
  label: { type: 'string', default: 'QVAC' }
} })
const runtimeRoot = path.resolve(values['runtime-root'])
const workDir = path.resolve(values['work-dir'])
await fs.mkdir(workDir, { recursive: true })
const cacheDir = path.join(workDir, 'model-cache')
await fs.mkdir(cacheDir, { recursive: true })
if (values['model-cache']) {
  for (const entry of await fs.readdir(values['model-cache'], { withFileTypes: true })) {
    if (!entry.isFile() || entry.name.endsWith('.json')) continue
    try { await fs.symlink(path.join(values['model-cache'], entry.name), path.join(cacheDir, entry.name)) }
    catch (error) { if (error.code !== 'EEXIST') throw error }
  }
}
const configPath = path.join(workDir, 'qvac.config.json')
await fs.writeFile(configPath, JSON.stringify({
  cacheDirectory: cacheDir, loggerConsoleOutput: false
}))
const binary = path.join(runtimeRoot, 'node_modules/bare-runtime-darwin-arm64/bin/bare')
const prefix = '__DROPSIFT_QVAC__'
const executableHash = createHash('sha256').update(await fs.readFile(binary)).digest('hex')
const child = spawn(binary, [path.join(runtimeRoot, 'bootstrap.cjs')], {
  cwd: runtimeRoot,
  env: { ...process.env, QVAC_CONFIG_PATH: configPath, SNAP_USER_COMMON: path.join(workDir, 'runtime-home') },
  stdio: ['pipe', 'pipe', 'pipe']
})
const pending = new Map()
let peakRSSBytes = 0
let sampling = false
const resourceTimer = setInterval(() => {
  if (sampling || child.exitCode !== null || !child.pid) return
  sampling = true
  execFile('/bin/ps', ['-p', String(child.pid), '-o', 'rss='], (error, stdout) => {
    sampling = false
    if (!error) peakRSSBytes = Math.max(peakRSSBytes, Number(stdout.trim()) * 1024 || 0)
  })
}, 500)
resourceTimer.unref()
let output = ''
let readyResolve
let readyReject
const ready = new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject })
child.on('error', error => { readyReject(error) })
child.stderr.on('data', data => { void fs.appendFile(path.join(workDir, 'engine.log'), data) })
child.stdout.on('data', data => {
  output += data.toString()
  while (output.includes('\n')) {
    const newline = output.indexOf('\n')
    const line = output.slice(0, newline)
    output = output.slice(newline + 1)
    const marker = line.indexOf(prefix)
    if (marker < 0) continue
    let event
    try { event = JSON.parse(line.slice(marker + prefix.length)) } catch { continue }
    if (event.type === 'ready') { readyResolve(); continue }
    const entry = pending.get(event.id)
    if (!entry) continue
    if (event.type === 'token') {
      if (entry.firstTokenMs === null) entry.firstTokenMs = performance.now() - entry.started
      entry.tokenEvents++
    }
    if (event.type === 'result' || event.type === 'error') {
      clearTimeout(entry.timeout)
      pending.delete(event.id)
      const seconds = (performance.now() - entry.started) / 1000
      const trace = { method: entry.method, seconds, type: event.type, error: event.error,
        firstTokenMs: entry.firstTokenMs, tokenEvents: entry.tokenEvents }
      void fs.appendFile(path.join(workDir, 'requests.jsonl'), JSON.stringify(trace) + '\n')
      if (event.type === 'error') entry.reject(new Error(event.error))
      else entry.resolve({ event, seconds, ...trace })
    }
  }
})
child.on('exit', (code, signal) => {
  for (const entry of pending.values()) {
    clearTimeout(entry.timeout)
    entry.reject(new Error(`Engine exited: code=${code}, signal=${signal}`))
  }
  pending.clear()
})
function request(method, params = {}, timeoutSeconds = 300) {
  const id = randomUUID()
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pending.delete(id)
      reject(new Error(`${method} timed out after ${timeoutSeconds}s`))
      child.kill('SIGTERM')
    }, timeoutSeconds * 1000)
    pending.set(id, { method, started: performance.now(), resolve, reject, timeout,
      firstTokenMs: null, tokenEvents: 0 })
    child.stdin.write(JSON.stringify({ id, method, params }) + '\n')
  })
}
const report = { label: values.label, startedAt: new Date().toISOString(),
  runtimeRoot, executableHash, action: values.action, runs: [] }
try {
  await Promise.race([ready, new Promise((_, reject) => {
    setTimeout(() => reject(new Error('No ready message')), 15000).unref()
  })])
  report.ping = (await request('ping')).event.text
  console.log(`${values.label}: ${report.ping}`)
  if (values.action === 'stage-coreml') {
    report.speechModelPath = (await request('prepareSpeechAssets', {
      speechModelPath: values['model-path']
    }, 900)).event.model
    console.log(`Core ML assets ready: ${report.speechModelPath}`)
  }
  if (values.action === 'diarize') {
    report.prepareSeconds = (await request('prepareDiarization', {}, 300)).seconds
    const result = await request('diarize', {
      audioPath: path.join(values['audio-root'], 'system-000.pcm'), audioDurationMs: 11157
    }, 120)
    report.diarization = result.event
    console.log(`Diarization: ${result.event.turns?.length ?? 0} turns`)
    await request('unloadDiarization')
  }
  if (values.action === 'asr') {
    const params = values['model-path'] ? { speechModelPath: path.resolve(values['model-path']) } : {}
    report.prepareSeconds = (await request('prepareTranscription', params, 600)).seconds
    const names = (await fs.readdir(values['audio-root'])).filter(name => /^(system|mic)-\d+\.pcm$/.test(name)).sort()
    if (!names.length) throw new Error('No normalized speech chunks')
    for (let run = 0; run < Number(values.repeat); run++) {
      let seconds = 0
      let segments = []
      const engineStats = []
      for (const [index, name] of names.entries()) {
        const file = path.join(values['audio-root'], name)
        const durationMs = Math.round((await fs.stat(file)).size / 32)
        const response = await request('transcribe', { audioPath: file, audioDurationMs: durationMs }, 180)
        seconds += response.seconds
        segments.push(...(response.event.segments ?? []))
        engineStats.push({ file: name, stats: response.event.stats, diagnostics: response.event.diagnostics })
        console.log(`${values.label}: run ${run + 1}, chunk ${index + 1}/${names.length}, ${response.seconds.toFixed(3)}s`)
      }
      const text = segments.map(segment => segment.text).join(' ')
      const metric = { run: run + 1, seconds, segmentCount: segments.length,
        characterCount: text.length, wordCount: text.trim().split(/\s+/).length, engineStats }
      if (!text.trim()) throw new Error('Empty transcription')
      report.runs.push(metric)
      await fs.writeFile(path.join(workDir, `private-transcript-${run + 1}.txt`), text, { mode: 0o600 })
      console.log(`${values.label}: run ${run + 1} completed in ${seconds.toFixed(3)}s, ${metric.wordCount} words`)
      await fs.writeFile(path.join(workDir, 'result.json'), JSON.stringify(report, null, 2))
    }
    report.unloadSeconds = (await request('unloadTranscription')).seconds
  }
  if (values.action === 'llm') {
    report.prepareSeconds = (await request('prepareLLM', {
      modelID: 'mlx-community/Qwen3.5-4B-4bit', modelSize: '4B', contextTokens: 32768
    }, 600)).seconds
    const prompts = values['prompts-file'] ? JSON.parse(await fs.readFile(values['prompts-file'], 'utf8')) : [
      { name: 'answer', systemPrompt: 'Use only this source and cite [1]: Alice will send the budget on Friday. Marco will run the offline test on Monday.', question: 'Who will send the budget and when?', maxTokens: 256 },
      { name: 'title', systemPrompt: 'Return only JSON with title and description string fields. Give a specific title and a one sentence description based on the supplied meeting.', question: 'Alice and Marco agreed to ship the offline knowledge application after checking audio capture, transcription accuracy, and iCloud synchronization on Friday.', maxTokens: 384 },
      { name: 'summary', systemPrompt: 'Return only JSON with summary, participants, topics, decisions, and actionItems fields. Use arrays for all fields except summary. Do not invent facts.', question: 'Alice and Marco reviewed the offline knowledge application. They decided to delay release until Friday. Alice will verify recording and transcription. Marco will test iCloud synchronization. Both agreed to collect feedback from three friends.', maxTokens: 768 }
    ]
    for (let run = 0; run < Number(values.repeat); run++) {
      for (const prompt of prompts) {
        const result = await request('complete', { systemPrompt: prompt.systemPrompt,
          messages: [{ role: 'user', content: prompt.question }], maxTokens: prompt.maxTokens,
          responseFormat: prompt.name === 'title' ? 'presentation' : prompt.name === 'summary' ? 'summary' : undefined }, 180)
        const text = result.event.text ?? ''
        if (!text.trim()) throw new Error('Empty language-model response')
        let valid = text.toLowerCase().includes('friday')
        if (prompt.name !== 'answer') {
          try { JSON.parse(text.replace(/^```(?:json)?\s*|\s*```$/g, '')); valid = true } catch { valid = false }
        }
        const metric = { run: run + 1, task: prompt.name, seconds: result.seconds,
          firstTokenMs: result.firstTokenMs, tokenEvents: result.tokenEvents,
          characters: text.length, valid }
        report.runs.push(metric)
        await fs.writeFile(path.join(workDir, `${prompt.name}-${run + 1}.txt`), text, { mode: 0o600 })
        console.log(`${values.label}: ${prompt.name} ${run + 1}, ${result.seconds.toFixed(3)}s, valid=${valid}`)
        await fs.writeFile(path.join(workDir, 'result.json'), JSON.stringify(report, null, 2))
      }
    }
    report.unloadSeconds = (await request('unloadLLM')).seconds
  }
  report.shutdownSeconds = (await request('shutdown', {}, 10)).seconds
  report.peakEngineRSSBytes = peakRSSBytes
  report.finishedAt = new Date().toISOString()
  await fs.writeFile(path.join(workDir, 'result.json'), JSON.stringify(report, null, 2))
} catch (error) {
  report.error = String(error)
  await fs.writeFile(path.join(workDir, 'result.json'), JSON.stringify(report, null, 2))
  console.error(error.message)
  process.exitCode = 1
} finally {
  clearInterval(resourceTimer)
  child.stdin.end()
  if (child.exitCode === null) child.kill('SIGTERM')
}
