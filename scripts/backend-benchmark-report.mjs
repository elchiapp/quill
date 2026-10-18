import fs from 'node:fs/promises'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'

const root = process.argv[2]
if (!root || !path.isAbsolute(root)) throw new Error('Pass the isolated benchmark workspace')
const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const output = path.join(root, 'report')
const artifacts = path.join(output, 'artifacts')
await fs.mkdir(artifacts, { recursive: true })
await fs.mkdir(path.join(output, 'issues'), { recursive: true })
const readJSON = async file => { try { return JSON.parse(await fs.readFile(file, 'utf8')) } catch { return null } }
const escape = value => String(value ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;')
const median = values => { const sorted = [...values].sort((a, b) => a - b); return sorted[Math.floor(sorted.length / 2)] }
const seconds = value => Number.isFinite(value) ? `${value.toFixed(2)} s` : '—'
const mib = value => Number.isFinite(value) ? `${(value / 1048576).toFixed(0)} MiB` : '—'
const asrCases = [
  ['native-asr', 'Native FluidAudio 0.17.7 / Core ML', 'Parakeet'],
  ['legacy-qvac-asr', 'Previous QVAC 0.18.2 / ASR 0.1.0', 'Parakeet'],
  ['qvac-metal-asr', 'QVAC 0.21.1 / Speech 0.10.0 / Metal (controlled prior GGUF)', 'Parakeet'],
  ['qvac-current-asr', 'QVAC Metal / current registry GGUF', 'Parakeet'],
  ['qvac-current-auto-coreml-asr', 'QVAC current registry / automatic Core ML + Metal', 'Parakeet'],
  ['qvac-coreml-asr', 'QVAC hybrid Core ML + Metal', 'Parakeet'],
  ['transcribepsy-coreml', 'TranscribePsy 254M / Core ML / ANE', 'TranscribePsy']
]
const llmCases = [
  ['native-llm', 'Native MLX 0.32.3 / LM 3.32.3'],
  ['legacy-qvac-llm', 'Previous QVAC / unbounded JSON'],
  ['qvac-llm-fixed', 'Updated QVAC / before structured-output fix'],
  ['qvac-llm-final', 'Updated QVAC / validated JSON schema']
]
const all = new Map()
for (const [name] of [...asrCases, ...llmCases]) {
  const value = await readJSON(path.join(root, 'evidence', name, 'result.json'))
  if (value) {
    all.set(name, value)
    await fs.writeFile(path.join(artifacts, `${name}.json`), JSON.stringify(value, null, 2))
  }
}
const pipeline = await readJSON(path.join(root, 'evidence/pipeline-smoke/result.json'))
const packagedPipeline = await readJSON(path.join(root, 'evidence/packaged-pipeline/result.json'))
const e2e = await readJSON(path.join(root, 'evidence/e2e-metal/result.json'))
  ?? await readJSON(path.join(root, 'evidence/e2e/result.json'))
const matrix = await readJSON(path.join(root, 'evidence/matrix.json'))
const verification = await readJSON(path.join(root, 'evidence/verification.json'))
const capture = await readJSON(path.join(root, 'evidence/provenance.json'))
for (const [name, value] of Object.entries({ pipeline, packagedPipeline, e2e, matrix, verification, capture })) {
  if (value) await fs.writeFile(path.join(artifacts, `${name}.json`), JSON.stringify(value, null, 2))
}
try { await fs.copyFile(path.join(root, 'evidence/pipeline-smoke/ocr-fixture.png'), path.join(artifacts, 'ocr-fixture.png')) } catch {}
const baseSHA = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: project, encoding: 'utf8' }).trim()
const dirty = execFileSync('git', ['status', '--porcelain'], { cwd: project, encoding: 'utf8' }).trim() !== ''
const pins = JSON.parse(await fs.readFile(path.join(project, 'Package.resolved'), 'utf8')).pins
const npm = JSON.parse(await fs.readFile(path.join(project, 'QVACBridge/package-lock.json'), 'utf8'))
const versions = Object.fromEntries(['@qvac/inference', '@qvac/asr-ggml', '@qvac/fabric', '@qvac/llm-llamacpp', '@qvac/ocr-ggml', 'bare'].map(
  name => [name, npm.packages[`node_modules/${name}`]?.version]
))
for (const identity of ['fluidaudio', 'mlx-swift', 'mlx-swift-lm']) versions[identity] = pins.find(pin => pin.identity === identity)?.state.version
const sourceFiles = ['Package.swift', 'Package.resolved', 'QVACBridge/package-lock.json', 'QVACBridge/bridge.mjs',
  'QVACBridge/structured-output.mjs', 'QVACBridge/diarization.mjs', 'Sources/dropsift/Services/QVACRuntime.swift']
const sourceManifest = []
for (const file of sourceFiles) sourceManifest.push({ file,
  sha256: createHash('sha256').update(await fs.readFile(path.join(project, file))).digest('hex') })
await fs.writeFile(path.join(artifacts, 'source-manifest.json'), JSON.stringify({ baseSHA, dirty, versions, sourceManifest }, null, 2))

const issues = [
  { id: 'QVAC-0001', title: 'Queued inference could block cancellation and shutdown', severity: 'Critical', owner: 'app', state: 'fixed', area: 'lifecycle',
    detail: 'The previous continuation gate could not cancel a queued operation. The app was observed hanging during quit. Cancellable gate waiters, bounded shutdown, nonblocking pipe writes and generation-scoped exit handling now have focused regressions.', evidence: 'verification.json', validity: 'valid' },
  { id: 'QVAC-0002', title: 'Obsolete generation parameter rejected by the new SDK', severity: 'Critical', owner: 'app', state: 'fixed', area: 'LLM',
    detail: 'The first upgraded LLM run failed deterministically on remove_thinking_from_context. The bridge now uses the current public request vocabulary. The failed attempt is retained; the final 4B answer/title/summary matrix passed all nine cases.', evidence: 'qvac-llm-final.json', validity: 'valid' },
  { id: 'QVAC-0003', title: 'Unconstrained summary output could be incomplete', severity: 'Medium', owner: 'model-behavior', state: 'mitigated', area: 'LLM',
    detail: 'The prior and initial updated runs produced incomplete JSON. Prompting alone did not guarantee the application contract. Titles and summaries now request explicit JSON schemas with bounded fields. Final tested outputs were valid; factual accuracy was not human-scored.', evidence: 'qvac-llm-final.json', validity: 'valid' },
  { id: 'QVAC-0004', title: 'UTF-8 pipe boundaries could discard multilingual responses', severity: 'Critical', owner: 'app', state: 'fixed', area: 'transport',
    detail: 'Decoding each arbitrary pipe read as a whole UTF-8 string could discard both halves of an accented character and leave a request unanswered. The bridge now buffers bytes until a complete line. A subprocess regression deliberately splits Caffè across pipe writes.', evidence: 'verification.json', validity: 'valid' },
  { id: 'QVAC-0005', title: 'TranscribePsy Metal exploration is outside the documented release path', severity: 'Unclassified', owner: 'test-infrastructure', state: 'invalid-setup', area: 'speech',
    detail: 'The exploratory Metal lane failed with tdt_greedy_decode rc=6. The released on-device GGUF is documented for CPU; Core ML is the documented Apple accelerated build. CPU compatibility and three Core ML runs passed. Metal is not offered as a supported TranscribePsy option.', evidence: 'matrix.json', validity: 'invalid', reason: 'Unsupported experimental lane; not a demonstrated DropSift defect.' },
  { id: 'QVAC-0006', title: 'New speaker clock format was silently discarded', severity: 'Medium', owner: 'app', state: 'fixed', area: 'diarization',
    detail: 'Speech Fabric emitted Speaker 0: 00:00:00.000 - 00:00:11.200. The old seconds-only parser returned no turns. The parser now accepts clock and legacy second formats, checks ordering, and clamps padding to the input duration. The same app-bridge test now returns a valid speaker turn.', evidence: 'pipeline.json', validity: 'valid' },
  { id: 'QVAC-0007', title: 'Automatic encoder sidecars overrode the faster Metal path', severity: 'Low', owner: 'app', state: 'fixed', area: 'speech',
    detail: 'The current SDK automatically stages Core ML companions. On this M4 Max, the same current model took about 6.16 seconds with the hybrid encoder versus 3.66 seconds with Metal. The app now explicitly disables the sidecar for its default speech path. Per-run encoderUsedCoreml and selectedBackend confirm the actual placement. This is hardware-specific, not a claim that Metal wins on every Apple device.', evidence: 'qvac-current-asr.json', validity: 'valid' },
  { id: 'QVAC-0008', title: 'Coalesced creation flags could refresh the library during audio appends', severity: 'Low', owner: 'app', state: 'fixed', area: 'lifecycle',
    detail: 'The release regression failed after appending to an existing audio file. FSEvents can retain ItemCreated in a later change. The monitor now snapshots asset identities once and ignores creation flags for the same existing file. Newly arrived or replaced assets still refresh. The nine-second idle and audio-append regression also checks that new audio is detected. Initial failed suite logs remain in the private evidence workspace.', evidence: 'verification.json', validity: 'valid' }
]
const severityOrder = ['Critical', 'Medium', 'Low', 'Unclassified']
issues.sort((a, b) => severityOrder.indexOf(a.severity) - severityOrder.indexOf(b.severity)
  || (a.owner === 'app' ? 0 : 1) - (b.owner === 'app' ? 0 : 1))
const css = `:root{font:15px/1.5 Arial,Helvetica,sans-serif;color:#18212b;background:#f5f7f9}*{box-sizing:border-box}body{margin:0}main{max-width:1180px;margin:auto;padding:28px}h1{font-size:30px;margin:0 0 8px}h2{font-size:20px;margin:26px 0 12px}p{margin:8px 0 14px}.sub,.muted{color:#586574}.card,section{background:white;border:1px solid #dce2e8;border-radius:12px;padding:18px;margin:16px 0}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}.cards .card{margin:0}.value{font-size:28px;font-weight:bold}.badge{display:inline-block;border-radius:20px;padding:3px 10px;font-size:12px;background:#e9eef5}.good{background:#dcf3e6}.warn{background:#fff0cc}a{color:#175eb4}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:10px 8px;border-bottom:1px solid #e4e9ee;vertical-align:top}th{font-size:12px;color:#586574}td{overflow-wrap:anywhere}.table-wrap{overflow:auto}select,button,input,textarea{font:inherit;max-width:100%;padding:9px;border:1px solid #bdc9d5;border-radius:7px;background:white}button{cursor:pointer}button.primary{background:#165eb4;color:white;border-color:#165eb4}.filters{display:flex;flex-wrap:wrap;gap:8px;margin:12px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:12px}.review{display:flex;flex-wrap:wrap;gap:8px}.review textarea{flex:1;min-width:180px}.review-message{color:#ad3100}.hidden{display:none}code{font-size:12px}.tag{font-size:12px;color:#586574}img{max-width:100%;height:auto}footer{font-size:13px;color:#586574;margin:24px 0}@media(max-width:640px){main{padding:14px}h1{font-size:25px}section{padding:12px}td,th{padding:8px 5px;font-size:12px}.review>*{width:100%}.value{font-size:24px}}@media print{.filters,.review,button{display:none}body{background:white}main{max-width:none;padding:0}section,.card{break-inside:avoid}a{color:inherit}}`
const reviewScript = `const issues=ISSUES;const key=id=>'dropsift-qvac-qa-20261018:'+id;function current(i){try{return JSON.parse(localStorage.getItem(key(i.id)))||{validity:i.validity,reason:i.reason||''}}catch{return{validity:i.validity,reason:i.reason||''}}}function apply(){for(const row of document.querySelectorAll('[data-issue]')){const i=issues.find(x=>x.id===row.dataset.issue);const v=current(i);row.dataset.validity=v.validity;const tag=row.querySelector('.validity');if(tag)tag.textContent=v.validity+(v.reason?' · '+v.reason:'');}filter()}function filter(){const val=id=>document.getElementById(id)?.value||'all';let visible=0;for(const row of document.querySelectorAll('tr[data-area]')){const ok=['area','owner','state','severity','model'].every(k=>val(k)==='all'||row.dataset[k]===val(k));const valid=row.dataset.validity!=='invalid'||document.getElementById('show-invalid')?.checked;row.hidden=!(ok&&valid);if(!row.hidden)visible++}const count=document.getElementById('visible-count');if(count)count.textContent=visible+' visible rows';}for(const control of document.querySelectorAll('.filters select,.filters input'))control.addEventListener('change',filter);document.getElementById('double-check')?.addEventListener('click',()=>{document.getElementById('state').value='needs-double-check';filter()});for(const form of document.querySelectorAll('form[data-review]')){const i=issues.find(x=>x.id===form.dataset.review);const v=current(i);form.elements.validity.value=v.validity;form.elements.reason.value=v.reason;form.addEventListener('submit',e=>{e.preventDefault();const validity=form.elements.validity.value;const reason=form.elements.reason.value.trim();const msg=form.querySelector('.review-message');if(validity==='invalid'&&!reason){msg.textContent='Enter a reason before marking this invalid.';return}localStorage.setItem(key(i.id),JSON.stringify({validity,reason,updatedAt:new Date().toISOString()}));msg.textContent='Saved in this browser.';apply()})}apply();`
const review = issue => `<form class="review" data-review="${issue.id}"><select name="validity" aria-label="Review validity"><option value="valid">Valid</option><option value="invalid">Invalid</option></select><textarea name="reason" rows="2" aria-label="Review reason" placeholder="Reason required for Invalid"></textarea><button>Save review</button><span class="review-message" role="status"></span></form>`
const page = (title, body, prefix = '') => `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escape(title)}</title><style>${css}</style></head><body><main>${body}<footer>Local automated backend study. No credentials or private transcripts are included in this report. No GUI video was captured; packaged UI, clean-machine behavior and physical-device quality remain separate validation work.</footer></main><script>${reviewScript.replace('ISSUES', JSON.stringify(issues).replaceAll('<', '\\u003c'))}</script></body></html>`
const asrRows = asrCases.filter(([name]) => all.has(name)).map(([name, label, model], index) => {
  const result = all.get(name)
  const times = result.runs.map(row => row.seconds)
  return `<tr data-area="speech" data-owner="app" data-state="passed-automated" data-model="${model}"><td>QVAC-01${String(index + 1).padStart(2, '0')}<br>${escape(label)}</td><td>${seconds(median(times))}</td><td>${times.map(seconds).join(' / ')}</td><td>${seconds(result.prepareSeconds)}</td><td>${mib(result.peakEngineRSSBytes ?? result.peakProcessRSSBytes)}</td><td><a href="artifacts/${name}.json">Metrics</a></td></tr>`
}).join('')
const llmRows = llmCases.filter(([name]) => all.has(name)).flatMap(([name, label]) => {
  const result = all.get(name)
  return ['answer', 'title', 'summary'].map(task => {
    const rows = result.runs.filter(row => row.task === task)
    if (!rows.length) return ''
    return `<tr data-area="LLM" data-owner="app" data-state="passed-automated" data-model="Qwen 4B"><td>${escape(label)}</td><td>${task}</td><td>${seconds(median(rows.map(row => row.seconds)))}</td><td>${seconds(median(rows.map(row => row.firstTokenMs / 1000)))}</td><td>${rows.filter(row => row.valid).length}/${rows.length} valid JSON/answer</td><td><a href="artifacts/${name}.json">Metrics</a></td></tr>`
  })
}).join('')
const issueRows = issues.map(issue => `<tr data-issue="${issue.id}" data-area="${issue.area}" data-owner="${issue.owner}" data-state="${issue.state}" data-severity="${issue.severity}" data-model="all"><td><a href="issues/${issue.id}.html">${issue.id}</a><br>${escape(issue.title)}<br><span class="validity tag"></span></td><td>${issue.severity}</td><td>${issue.owner}</td><td>${issue.state}</td></tr>`).join('')
for (const issue of issues) {
  const body = `<p><a href="../index.html">← Benchmark dashboard</a></p><h1>${issue.id}</h1><h2>${escape(issue.title)}</h2><p>${escape(issue.detail)}</p><p><span class="badge">${issue.severity}</span> <span class="badge">${issue.owner}</span> <span class="badge">${issue.state}</span> <span class="badge">platform:macos · topology:desktop-1</span></p><section><h2>Evidence and acceptance</h2><p>Hardware: Apple M4 Max, 128 GB unified memory, macOS 26.5.2. Candidate DropSift 1.0.58 (2026101802). Local SDK engine; no cloud inference or peer delegation.</p><p><a href="../artifacts/${issue.evidence}">Reviewable automated evidence</a> · <a href="../artifacts/source-manifest.json">Source/dependency provenance</a></p><p>Acceptance: preserve user data, return the documented result, complete or fail within the configured deadline, and allow a subsequent request. Test scope is the backend boundary. GUI footage was not captured; this is not a full packaged-UI certification.</p></section><section data-issue="${issue.id}"><h2>Reviewer decision</h2><p class="validity"></p>${review(issue)}</section>`
  await fs.writeFile(path.join(output, 'issues', `${issue.id}.html`), page(issue.id, body, '../'))
}
const qvac = all.get('qvac-current-asr') ?? all.get('qvac-metal-asr')
const nativeASR = all.get('native-asr')
const speedup = qvac && nativeASR ? median(nativeASR.runs.map(row => row.seconds)) / median(qvac.runs.map(row => row.seconds)) : null
const body = `<h1>DropSift backend benchmark</h1><p class="sub">18 October 2026 · Apple M4 Max · 128 GB · macOS 26.5.2 · one Mac, sequential local engines</p><p>Candidate <strong>1.0.58 (2026101802)</strong>. Same 12-minute, 6-second call; both tracks total about 24 minutes of audio. Three runs per principal lane. Preparation is separate from timed transcription. LLM: Qwen3.5 4B, 4-bit, 32K context, matched app prompts and token caps.</p>
<div class="cards"><div class="card"><div class="value">${speedup ? speedup.toFixed(2) + '×' : 'Pending'}</div>QVAC Metal speedup over native ASR</div><div class="card"><div class="value">9/9</div>Final QVAC answer/title/summary checks</div><div class="card"><div class="value">${packagedPipeline?.appLLMStructuredOutput ? 'Packaged pass' : pipeline?.appLLMStructuredOutput ? 'Bridge pass' : 'Pending'}</div>Speech · diarization · OCR · recovery · LLM</div></div>
<section><h2>Scope and limits</h2><p>All model inference was local. The original recording was read, not rewritten. Prepared WAV/PCM comparisons exclude shared conversion; the separate CAF test below includes the app conversion path. Diarization checks prove valid speaker turns on a known speech fixture, not multi-speaker accuracy. ASR on the real call has no human reference and is not a word-error-rate benchmark.</p><p>TranscribePsy's released on-device model covers eight languages; standard Parakeet covers 25. Its Core ML path passed three runs. Its experimental Metal trial is not a supported app option. CPU compatibility passed, but its run overlapped compilation and is excluded from speed ranking.</p><p>Process RSS is not whole-system memory: Core ML can use shared services outside the measured host process. Do not infer total memory superiority from the RSS column.</p></section>
<div class="filters"><select id="area" aria-label="Area"><option value="all">All areas</option>${['speech','LLM','lifecycle','transport','diarization'].map(value => `<option>${value}</option>`).join('')}</select><select id="model" aria-label="Model"><option value="all">All models</option><option>Parakeet</option><option>TranscribePsy</option><option>Qwen 4B</option></select><select id="state" aria-label="State"><option value="all">All states</option>${['passed-automated','fixed','mitigated','needs-double-check','invalid-setup'].map(value => `<option>${value}</option>`).join('')}</select><select id="owner" aria-label="Owner"><option value="all">All owners</option><option>app</option><option>model-behavior</option><option>test-infrastructure</option></select><select id="severity" aria-label="Severity"><option value="all">All severities</option><option>Critical</option><option>Medium</option><option>Unclassified</option></select><label><input id="show-invalid" type="checkbox"> Show invalid attempts</label><button id="double-check">Needs double-check</button><span id="visible-count"></span></div>
<section><h2>Speech engine timing</h2><div class="table-wrap"><table><thead><tr><th>Lane</th><th>Median</th><th>All runs</th><th>Observed load</th><th>Peak process RSS</th><th>Evidence</th></tr></thead><tbody>${asrRows}</tbody></table></div><p class="muted">Latest Metal and hybrid Core ML lanes include per-run backend diagnostics. Legacy SDK requested GPU but did not expose the same per-run placement counters. Model quantization/container and preprocessing differ between native and QVAC; the comparison measures the available app backends.</p></section>
<section><h2>Qwen 4B workload timing</h2><div class="table-wrap"><table><thead><tr><th>Runtime</th><th>Task</th><th>Median total</th><th>Median first visible token</th><th>Format checks</th><th>Evidence</th></tr></thead><tbody>${llmRows}</tbody></table></div><p class="muted">The initial MLX answer paid first-generation warm-up; see the full run list. Final QVAC titles/summaries use the app's explicit JSON schemas. Output length varies, so small total-time differences are not pure token-throughput comparisons. Format validation does not establish factual accuracy.</p></section>
<section><h2>Original CAF / app conversion path</h2>${e2e ? `<pre>${escape(JSON.stringify(e2e.metrics, null, 2))}</pre><a href="artifacts/e2e.json">Full app-path metrics</a>` : '<p>Pending; no end-to-end claim yet.</p>'}</section>
<section><h2>Automated pipeline and release verification</h2><pre>${escape(JSON.stringify({ bridge: pipeline, packaged: packagedPipeline, verification }, null, 2))}</pre><p>Physical iPhone and Apple Watch were offline. No phone/watch inference performance or cross-device compatibility certification is claimed. GUI onboarding, permissions, clean-machine installs and field accuracy remain <strong>not-tested</strong> in this backend study.</p><p>Skill/tool matrix: Asana, Gmail, Calendar, Drive, Notion, Spotify, Weather, Apple Reminders, Notes and Obsidian are <strong>out of scope</strong>; this app integration does not expose those QVAC Assistant skills. No account or vault access was used.</p><p>Evidence method: automated process/SDK traces and machine-readable metrics. GUI video: <strong>evidence-gap</strong>; no manual UI pass is inferred.</p></section>
<section><h2>Issues and retained attempts</h2><table><thead><tr><th>Issue</th><th>Severity</th><th>Ownership</th><th>State</th></tr></thead><tbody>${issueRows}</tbody></table><p>Invalid records stay auditable and are excluded from the default view. Reviewer decisions persist locally in this browser; Invalid requires a reason.</p></section>
<section><h2>Version provenance</h2><pre>${escape(JSON.stringify({ sourceSHA: baseSHA, worktreeDirty: dirty, versions }, null, 2))}</pre><p><a href="artifacts/source-manifest.json">Source hashes</a>${capture ? ' · <a href="artifacts/capture.json">Packaged artifacts and checksums</a>' : ''}</p><p>Current published versions were selected. The released speech addon pins Speech Fabric 2026-10-12#1 and ggml-speech 2026-10-07#1. Unreleased source HEAD is not silently substituted.</p></section>
<section><h2>Recommendation and cleanup</h2><p>Keep updated QVAC Metal as the default QVAC speech path on this Mac. Keep TranscribePsy experimental until its smaller language set and quality are evaluated for the intended devices. The backend checks do not approve a public release: Developer ID/notarization, license notices, clean-machine and physical-device testing remain separate work.</p><p>Benchmark copies, model caches and failure evidence remain under the dedicated local workspace. Private transcripts and workload prompts are not served by this report. No recording was overwritten, no 1Password item was accessed, and no Keychain setting was changed.</p></section>`
const health = `<section><h2>Area health</h2><p>Backend assertions passed; visual and physical-device evidence is incomplete.</p><div class="cards">${[
  ['Speech', 'needs-double-check', 'Three-run timing and GPU routing passed. Real-call accuracy has no human reference.'],
  ['LLM', 'needs-double-check', 'Nine final format checks passed. Factual quality and full-library retrieval are not scored.'],
  ['Lifecycle and transport', 'needs-double-check', 'Cancellation, deadlines and UTF-8 regressions passed. No manual GUI footage.'],
  ['iPhone and Watch', 'not-tested', 'Simulator builds only. Physical hardware was offline.']
].map(([area, state, detail]) => `<div class="card"><strong>${area}</strong><p><span class="badge warn">${state}</span></p><p>${detail}</p></div>`).join('')}</div></section>`
const rendered = body.replace('<div class="filters">', health + '<div class="filters">')
  .replace('<option>Medium</option><option>Unclassified</option>', '<option>Medium</option><option>Low</option><option>Unclassified</option>')
await fs.writeFile(path.join(output, 'index.html'), page('DropSift backend benchmark', rendered))
console.log(output)
