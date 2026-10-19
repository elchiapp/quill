import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import vm from 'node:vm'

test('report script parses and inline invalidation requires a reason, persists, and keeps history',async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'dropsift-report-test-'))
  try{
    await fs.mkdir(path.join(root,'report'),{recursive:true});await fs.mkdir(path.join(root,'evidence'))
    await fs.writeFile(path.join(root,'report/metrics.json'),JSON.stringify({method:'test',limits:[],lanes:{}}))
    await promisify(execFile)(process.execPath,['scripts/speech-matrix-report.mjs',root])
    const html=await fs.readFile(path.join(root,'report/index.html'),'utf8'),script=html.match(/<script>([\s\S]*)<\/script>/)[1]
    assert.equal(script.includes('prompt('),false);assert.equal(script.includes('alert('),false)
    const elements=new Map(),saved=new Map()
    function element(id){if(!elements.has(id))elements.set(id,{value:id.startsWith('f-')?'all':'',checked:false,hidden:true,innerHTML:'',textContent:'',
      classList:{toggle(){}},append(){},querySelector(){return {}},focus(){this.focused=true}});return elements.get(id)}
    const context={document:{getElementById:element,createElement:()=>element('label-'+elements.size)},
      localStorage:{getItem:k=>saved.get(k)??null,setItem:(k,v)=>saved.set(k,v)},window:{},location:{hash:''},Date,console}
    vm.createContext(context);new vm.Script(script).runInContext(context)
    context.window.judge('QVAC-0018',false)
    assert.equal(saved.size,0);assert.equal(element('dashboard-reason-QVAC-0018').focused,true)
    element('dashboard-reason-QVAC-0018').value='Synthetic adjudication test'
    context.window.judge('QVAC-0018',false)
    let state=JSON.parse([...saved.values()][0]);assert.equal(state['QVAC-0018'].valid,false)
    assert.equal(element('issues').innerHTML.includes('Long-form accuracy remains a review gate'),false)
    context.window.judge('QVAC-0018',true)
    state=JSON.parse([...saved.values()][0]);assert.equal(state['QVAC-0018'].valid,true)
    assert.equal(state['QVAC-0018'].history.length,2)
    assert.equal(state['QVAC-0018'].history[0].reason,'Synthetic adjudication test')
    assert.equal(element('issues').innerHTML.includes('Long-form accuracy remains a review gate'),true)
  }finally{await fs.rm(root,{recursive:true,force:true})}
})
