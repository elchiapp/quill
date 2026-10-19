import { spawn } from 'node:child_process'
import fs from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
const [root,oldRoot,pid]=process.argv.slice(2), project=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..')
if(![root,oldRoot].every(p=>p&&path.isAbsolute(p)))throw new Error('Pass local workspace, public model workspace, and optional running matrix PID')
while(pid){try{process.kill(Number(pid),0)}catch{break}await new Promise(resolve=>setTimeout(resolve,3000))}
const folder=path.join(root,'verification');await fs.mkdir(folder,{recursive:true})
let timeline=[]
async function run(name,command,args,env={}){
  const out=path.join(folder,name);await fs.mkdir(out,{recursive:true})
  const startedAt=new Date().toISOString(),start=performance.now();console.log('BEGIN '+name)
  const child=spawn(command,args,{cwd:project,env:{...process.env,...env},stdio:['ignore','pipe','pipe']})
  child.stdout.on('data',bytes=>{void fs.appendFile(path.join(out,'stdout.log'),bytes)})
  child.stderr.on('data',bytes=>{void fs.appendFile(path.join(out,'stderr.log'),bytes)})
  const timer=setTimeout(()=>child.kill('SIGTERM'),30*60_000)
  const exitCode=await new Promise(resolve=>{child.once('error',()=>resolve(-1));child.once('exit',resolve)})
  clearTimeout(timer);timeline.push({name,startedAt,finishedAt:new Date().toISOString(),seconds:(performance.now()-start)/1000,exitCode})
  await fs.writeFile(path.join(folder,'timeline.json'),JSON.stringify(timeline,null,2));console.log('END '+name+' exit='+exitCode)
  return exitCode
}
if(await run('swift-regressions','swift',['test','-c','release'])!==0)throw new Error('Swift regressions failed; do not package')
if(await run('bridge-regressions',process.execPath,['--test','QVACBridge/speech-options.test.mjs'])!==0)throw new Error('Bridge regressions failed')
// Use the newest tested bridge. The running app is never touched by this harness.
for(const file of ['bridge.mjs','speech-options.mjs','fabric-speech.mjs'])await fs.copyFile(path.join(project,'QVACBridge',file),path.join(root,'runtime',file))
const model=path.join(oldRoot,'evidence/pipeline-smoke/cache/Models/parakeet-tdt-0.6b-v3.q8_0.gguf')
const psy=path.join(oldRoot,'models/gguf/transcribepsy-250m-eu-sub.gguf')
const coreml=path.join(oldRoot,'evidence/stage-coreml/model-cache/parakeet-tdt-0.6b-v3-coreml-20260928/parakeet-tdt-0.6b-v3.q8_0.gguf')
const e2e=await run('app-engine-e2e','swift',['test','-c','release','--skip-build','--filter','qvacSpeechMatrixEndToEnd'],{
  DROPSIFT_SPEECH_E2E_MANIFEST:path.join(root,'data/e2e-manifest.json'),DROPSIFT_SPEECH_E2E_OUTPUT:path.join(folder,'app-engine-e2e'),
  DROPSIFT_QVAC_RUNTIME_ROOT:path.join(root,'runtime'),DROPSIFT_QVAC_SPEECH_MODEL:model,DROPSIFT_QVAC_PSY_MODEL:psy})
if(e2e!==0)throw new Error('App conversion regression remains unresolved; do not package')
for(const route of ['sdk','fabricDirect'])await run('compute-switch-'+route,process.execPath,[path.join(project,'scripts/benchmark-qvac.mjs'),
  '--runtime-root',path.join(root,'runtime'),'--work-dir',path.join(folder,'compute-switch-'+route),'--action','compute-switch',
  '--speech-route',route,'--model-path',coreml,'--audio-root',path.join(root,'data/switch-fixture'),'--label','Same-process CPU/Core ML/Metal '+route])
// Nonzero silence controls distinguish exact-zero bypass from actual no-speech behavior.
const base=JSON.parse(await fs.readFile(path.join(root,'data/manifest.json'),'utf8')).samples.find(s=>s.id==='en_us-01-clean')
const samples=[base];let seed=20261019
function wav(bytes){const h=Buffer.alloc(44);h.write('RIFF');h.writeUInt32LE(bytes.length+36,4);h.write('WAVEfmt ',8);h.writeUInt32LE(16,16);h.writeUInt16LE(1,20);h.writeUInt16LE(1,22);h.writeUInt32LE(16000,24);h.writeUInt32LE(32000,28);h.writeUInt16LE(2,32);h.writeUInt16LE(16,34);h.write('data',36);h.writeUInt32LE(bytes.length,40);return Buffer.concat([h,bytes])}
for(const amplitude of [1,180])for(const duration of [0.01,0.1,1,10,60.1,180]){
  const id='non-speech-'+amplitude+'-'+duration,bytes=Buffer.alloc(Math.round(duration*16000)*2)
  for(let i=0;i<bytes.length;i+=2){seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;const value=Math.round(((seed>>>0)/4294967296*2-1)*amplitude);bytes.writeInt16LE(value,i)}
  const pcm=path.join(folder,id+'.pcm'),wave=path.join(folder,id+'.wav');await fs.writeFile(pcm,bytes);await fs.writeFile(wave,wav(bytes))
  samples.push({id,pcm,wav:wave,durationSeconds:duration,reference:'',language:'none',condition:'noise-only'})
}
const manifest=path.join(folder,'noise-manifest.json');await fs.writeFile(manifest,JSON.stringify({samples},null,2))
const observations=[]
for(const route of ['sdk','fabricDirect'])for(const speechModel of ['parakeet','transcribepsy']){
  const name='noise-'+route+'-'+speechModel
  await run(name,process.execPath,[path.join(project,'scripts/benchmark-qvac.mjs'),'--runtime-root',path.join(root,'runtime'),
    '--work-dir',path.join(folder,name),'--action','samples','--samples-file',manifest,'--model-path',speechModel==='parakeet'?model:psy,
    '--speech-route',route,'--speech-model',speechModel,'--acceleration','metal','--repeat','3','--label',name])
  try{const r=JSON.parse(await fs.readFile(path.join(folder,name,'result.json'),'utf8'));const negative=r.runs.filter(x=>x.sampleID.startsWith('non-speech-'));observations.push({lane:name,runs:negative.length,errorRuns:negative.filter(x=>x.error).length,falseSpeechRuns:negative.filter(x=>x.text?.trim()).length})}catch{}
}
await fs.writeFile(path.join(folder,'noise-observations.json'),JSON.stringify(observations,null,2))
await run('release-build','swift',['build','-c','release'])
console.log('VERIFICATION FINISHED. Packaging remains a separate signature/provenance gate.')
