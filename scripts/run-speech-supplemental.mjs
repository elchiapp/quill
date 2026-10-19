import { spawn, execFile } from 'node:child_process'
import fs from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { createHash } from 'node:crypto'

const [root, oldRoot, matrixPID] = process.argv.slice(2)
if (![root, oldRoot].every(p => p && path.isAbsolute(p))) throw new Error('Pass isolated root, previous public-assets root, and matrix PID')
const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
while (matrixPID) {
  try { process.kill(Number(matrixPID), 0) } catch { break }
  await new Promise(resolve => setTimeout(resolve, 3000))
}
const manifest = JSON.parse(await fs.readFile(path.join(root, 'data/manifest.json'), 'utf8'))
const tsv = path.join(root, 'data/public-samples.tsv')
await fs.writeFile(tsv, manifest.samples.map(s => [s.id,s.pcm,s.durationSeconds].join('\t')).join('\n')+'\n')
const models = {
  parakeet: path.join(oldRoot,'evidence/pipeline-smoke/cache/Models/parakeet-tdt-0.6b-v3.q8_0.gguf'),
  psy: path.join(oldRoot,'models/gguf/transcribepsy-250m-eu-sub.gguf'),
  parakeetCoreML: path.join(oldRoot,'evidence/stage-coreml/model-cache/parakeet-tdt-0.6b-v3-coreml-20260928/parakeet-tdt-0.6b-v3.q8_0.gguf'),
  psyCoreML: path.join(oldRoot,'models/coreml/transcribepsy-250m-eu-sub-coreml.gguf')
}
const entries = [
  ['upstream-parakeet-metal','fabric-matrix',models.parakeet,'metal'],
  ['upstream-transcribepsy-metal','fabric-matrix',models.psy,'metal'],
  ['upstream-parakeet-coreml','fabric-matrix',models.parakeetCoreML,'coreml'],
  ['standalone-transcribepsy-coreml','psy-matrix',models.psyCoreML,'coreml']
]
let timeline=[]
async function run(name, command, args, env={}) {
  const folder=path.join(root,'lanes',name);await fs.mkdir(folder,{recursive:true})
  const start=performance.now(),startedAt=new Date().toISOString()
  console.log('BEGIN '+name+' '+startedAt)
  const child=spawn(command,args,{cwd:project,env:{...process.env,...env},stdio:['ignore','pipe','pipe']})
  child.stdout.on('data',bytes=>{void fs.appendFile(path.join(folder,'stdout.log'),bytes)})
  child.stderr.on('data',bytes=>{void fs.appendFile(path.join(folder,'stderr.log'),bytes)})
  const timer=setTimeout(()=>child.kill('SIGTERM'),45*60_000)
  const exitCode=await new Promise(resolve=>{child.once('error',e=>{console.error(String(e));resolve(-1)});child.once('exit',resolve)})
  clearTimeout(timer)
  const record={lane:name,startedAt,finishedAt:new Date().toISOString(),wallSeconds:(performance.now()-start)/1000,exitCode}
  timeline.push(record);await fs.writeFile(path.join(root,'supplemental-matrix.json'),JSON.stringify(timeline,null,2))
  console.log('END '+name+' exit='+exitCode)
  return record
}
// Corrective run: the earlier SDK/Core ML attempt was quarantined because a
// presence-based disable flag accidentally selected CPU. Preserve that attempt.
await run('sdk-parakeet-coreml',process.execPath,[path.join(project,'scripts/benchmark-qvac.mjs'),
  '--runtime-root',path.join(root,'runtime'),'--work-dir',path.join(root,'lanes/sdk-parakeet-coreml'),
  '--action','samples','--samples-file',path.join(root,'data/manifest.json'),'--model-path',models.parakeetCoreML,
  '--speech-route','sdk','--speech-model','parakeet','--acceleration','coreml','--repeat','3','--long-repeat','1','--label','sdk-parakeet-coreml'])
for (const [name,driver,model,compute] of entries) {
  const folder=path.join(root,'lanes',name);await fs.mkdir(folder,{recursive:true})
  const output=path.join(folder,'result.json')
  const record=await run(name,path.join(root,driver),[model,tsv,output,compute,'3',name])
  try {
    const result=JSON.parse(await fs.readFile(output,'utf8'))
    result.finishedAt=record.finishedAt;result.modelSHA256=createHash('sha256').update(await fs.readFile(model)).digest('hex')
    result.routeBoundary='Supplemental upstream C++ API, 60-second outer chunks; not the packaged SDK/addon'
    await fs.writeFile(output,JSON.stringify(result,null,2))
  } catch(error) { console.error(name+': result unavailable: '+String(error)) }
}
// Production AVFoundation conversion, not only pre-normalized raw PCM.
const first=manifest.samples.find(s=>s.id==='en_us-01-clean')
const e2e=manifest.samples.filter(s=>['en_us-01-clean','it_it-01-clean','en_us-length-60.1s','en_us-length-7200s'].includes(s.id))
const ffmpeg=process.env.DROPSIFT_FFMPEG ?? '/opt/homebrew/bin/ffmpeg'
const aac=path.join(root,'data/stereo-44100.m4a')
await promisify(execFile)(ffmpeg,['-hide_banner','-loglevel','error','-y','-i',first.wav,'-ar','44100','-ac','2','-c:a','aac',aac])
e2e.push({...first,id:'stereo-44100-aac',wav:aac})
const e2eManifest=path.join(root,'data/e2e-manifest.json')
await fs.writeFile(e2eManifest,JSON.stringify({samples:e2e},null,2))
await run('app-engine-e2e','swift',['test','-c','release','--skip-build','--filter','qvacSpeechMatrixEndToEnd'],{
  DROPSIFT_SPEECH_E2E_MANIFEST:e2eManifest,DROPSIFT_SPEECH_E2E_OUTPUT:path.join(root,'lanes/app-engine-e2e'),
  DROPSIFT_QVAC_RUNTIME_ROOT:path.join(root,'runtime'),DROPSIFT_QVAC_SPEECH_MODEL:models.parakeet,DROPSIFT_QVAC_PSY_MODEL:models.psy
})
const switchAudio=path.join(root,'data/switch-fixture')
await fs.mkdir(switchAudio,{recursive:true})
await fs.copyFile(first.pcm,path.join(switchAudio,'system-000.pcm'))
await run('download-switch-recovery',process.execPath,[path.join(project,'scripts/benchmark-qvac.mjs'),
  '--runtime-root',path.join(root,'runtime'),'--work-dir',path.join(root,'lanes/download-switch-recovery'),
  '--action','speech-switch','--speech-route','fabricDirect','--speech-model','transcribepsy','--acceleration','metal',
  '--audio-root',switchAudio,'--label','Public asset download, route switch and missing-model recovery'])
for (const route of ['sdk','fabricDirect']) await run('speaker-smoke-'+route,process.execPath,[path.join(project,'scripts/benchmark-qvac.mjs'),
  '--runtime-root',path.join(root,'runtime'),'--work-dir',path.join(root,'lanes','speaker-smoke-'+route),
  '--action','diarize','--speech-route',route,'--acceleration','metal',
  '--model-cache',path.join(oldRoot,'evidence/pipeline-smoke/cache/Models'),
  '--audio-root',switchAudio,'--label','Speaker smoke '+route])
console.log('SUPPLEMENTAL FINISHED')
