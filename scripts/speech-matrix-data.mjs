import fs from 'node:fs/promises'
import path from 'node:path'
import {createHash} from 'node:crypto'

const [root, original] = process.argv.slice(2)
if (![root,original].every(x=>x&&path.isAbsolute(x))) throw new Error('Pass local workspace and reference manifest absolute paths')
const data = path.join(root,'data'), audio = path.join(data,'audio')
await fs.mkdir(audio,{recursive:true})
const source = JSON.parse(await fs.readFile(original,'utf8'))
const samples = [...source.samples]
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
function wav(pcm) {
  const header=Buffer.alloc(44)
  header.write('RIFF');header.writeUInt32LE(pcm.length+36,4);header.write('WAVEfmt ',8)
  header.writeUInt32LE(16,16);header.writeUInt16LE(1,20);header.writeUInt16LE(1,22)
  header.writeUInt32LE(16000,24);header.writeUInt32LE(32000,28);header.writeUInt16LE(2,32);header.writeUInt16LE(16,34)
  header.write('data',36);header.writeUInt32LE(pcm.length,40)
  return Buffer.concat([header,pcm])
}
async function save(id,pcm,reference,language,condition,extra={}) {
  const pcmPath=path.join(audio,id+'.pcm'), wavPath=path.join(audio,id+'.wav')
  const wave=wav(pcm)
  await fs.writeFile(pcmPath,pcm);await fs.writeFile(wavPath,wave)
  samples.push({id,pcm:pcmPath,wav:wavPath,reference,language,condition,durationSeconds:pcm.length/32000,
    pcmSHA256:hash(pcm),audioSHA256:hash(wave),...extra})
}
for (const duration of [0,0.01,0.1,0.5,1,10,60.1,180]) {
  await save('silence-length-'+duration+'s',Buffer.alloc(Math.round(duration*16000)*2),'','none','silence-matrix')
}
for (const language of ['en_us','it_it']) {
  const rows=source.samples.filter(s=>s.language===language&&s.condition==='clean')
  const clips=[]
  for(const row of rows){const bytes=await fs.readFile(row.pcm);if(hash(bytes)!==row.pcmSHA256)throw new Error('Reference PCM checksum mismatch');clips.push({row,bytes})}
  for(const duration of [0.01,0.1,0.5,1,5,10]){
    const size=Math.round(duration*16000)*2
    const bytes=Buffer.alloc(size);clips[0].bytes.copy(bytes,0,0,size)
    await save(language+'-partial-'+duration+'s',bytes,null,language,'partial-utterance',
      {note:'Cropped public speech; no word-level ground truth for the cropped boundary. Robustness/timing only, excluded from WER.'})
  }
  for(const duration of [29.9,30,30.1,59.9,60,60.1,119.9,120,120.1,300,900,3600,7200]){
    const bytes=Buffer.alloc(Math.round(duration*16000)*2), references=[],members=[]
    let cursor=0,index=0
    while(cursor<bytes.length){
      const clip=clips[index++%clips.length]
      if(cursor+clip.bytes.length>bytes.length)break
      clip.bytes.copy(bytes,cursor);cursor+=clip.bytes.length
      references.push(clip.row.reference);members.push(clip.row.id)
      cursor=Math.min(bytes.length,cursor+8000)
    }
    await save(language+'-length-'+duration+'s',bytes,references.join(' '),language,'length-composite',
      {members,note:'Repeated, independent reference utterances plus silence. Length/coverage stress, not a published long-form accuracy benchmark.'})
  }
}
const seen=new Set()
for(const sample of samples){if(seen.has(sample.id))throw new Error('Duplicate sample: '+sample.id);seen.add(sample.id)}
await fs.writeFile(path.join(data,'manifest.json'),JSON.stringify({...source,samples,
  matrixMethod:'Finite boundary/length coverage through 2 hours; never a guarantee for every possible recording. Cropped partial utterances excluded from WER. Synthetic composites excluded from headline published-model comparisons.'},null,2))
console.log(JSON.stringify({manifest:path.join(data,'manifest.json'),samples:samples.length,maxSeconds:Math.max(...samples.map(s=>s.durationSeconds))}))
