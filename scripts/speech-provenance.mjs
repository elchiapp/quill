import fs from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { createHash } from 'node:crypto'
const exec=promisify(execFile), root=path.resolve(process.argv[2]), project=process.cwd()
const hash=async file=>createHash('sha256').update(await fs.readFile(file)).digest('hex')
const files=['QVACBridge/bridge.mjs','QVACBridge/speech-options.mjs','QVACBridge/fabric-speech.mjs','QVACBridge/package-lock.json',
  'Sources/dropsift/Transcription/QVACTranscriptionEngine.swift','Sources/dropsift/Transcription/ParakeetEngine.swift',
  'scripts/benchmark-qvac.mjs','scripts/speech-matrix-native.cpp','scripts/run-speech-matrix.mjs']
const snapshot={}
for(const name of files)snapshot[name]=await hash(path.join(project,name))
const packages={}
for(const name of ['@qvac/inference','@qvac/asr-ggml','@qvac/llm-llamacpp','@qvac/ocr-ggml','bare']) {
  const json=JSON.parse(await fs.readFile(path.join(root,'runtime/node_modules',name,'package.json'),'utf8'))
  packages[name]=json.version
}
const git=async(folder,...args)=>(await exec('git',['-C',folder,...args])).stdout.trim()
const result={recordedAt:new Date().toISOString(),sourceSHA:await git(project,'rev-parse','HEAD'),
  workingTree:await git(project,'status','--short'),sourceFileSHA256:snapshot,
  intendedVersion:(await fs.readFile('VERSION','utf8')).trim(),intendedBuild:(await fs.readFile('BUILD_NUMBER','utf8')).trim(),
  channel:'local Developer ID candidate; notarization not approved',workflowRun:'local; no CI run',
  bundleID:(await exec('/usr/libexec/PlistBuddy',['-c','Print :CFBundleIdentifier','Packaging/Info.plist'])).stdout.trim(),hardware:{chip:os.cpus()[0].model,logicalCPUs:os.cpus().length,memoryBytes:os.totalmem(),arch:os.arch()},
  OS:(await exec('/usr/bin/sw_vers',[])).stdout.trim(),packages,
  fabricSpeechSHA:await git(path.join(root,'fabric-speech'),'rev-parse','HEAD'),
  ggmlSHA:await git(path.join(root,'fabric-speech/engines/parakeet/ggml'),'rev-parse','HEAD'),
  transcribepsySHA:await git('/Users/marco/src/codex-workspaces/dropsift-qvac-benchmark-20261018/transcribepsy','rev-parse','HEAD'),
  topology:'desktop-1; isolated sequential worker; no peer mesh',
  scope:'ASR speed/accuracy/length/compute routing; app format conversion and settings. No private-call WER or DER certification.',
  timing:'Per-sample request wall time; warmup and preparation separate. Three repeats through 300 s, one above 300 s. Sequential inference. Controller wall time can include a deliberate between-lane compilation pause; do not use controller wall time as inference speed.',
  provenanceLimits:['Early CPU/Metal lanes used the retained bridge-before-prepare-guard snapshot. Inference algorithms and weights were unchanged.',
    'The first Core ML disable-flag attempt and Bare proxy preparation error are quarantined, not qualified Core ML results.',
    'Upstream C++ Core ML-all is labeled from actual encoderBackend. CPU/ANE policy uses the exact cpu_and_ane token.',
    'Requested Core ML and encoderUsedCoreml do not prove physical ANE execution. No hardware trace is claimed.',
    'Mac results do not certify iPhone or Apple Watch. No credentials were read for this test run.']}
await fs.writeFile(path.join(root,'evidence/provenance.json'),JSON.stringify(result,null,2))
console.log('Wrote local speech provenance')
