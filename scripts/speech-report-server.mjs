import http from 'node:http'
import fs from 'node:fs/promises'
import path from 'node:path'
const root=path.resolve(process.argv[2]), port=Number(process.argv[3]??8791)
http.createServer(async(req,res)=>{
  let name
  try{name=decodeURIComponent(new URL(req.url,'http://127.0.0.1').pathname).replace(/^\//,'')}catch{res.writeHead(400);res.end('Invalid URL');return}
  const allowed=/^report\/(?:issues\/)?[\w.-]+\.(?:html|json|jpg|png|mp4)$/.test(name)
    || /^(?:matrix\.json|supplemental-matrix\.json|morning-todos\.txt|evidence\/provenance\.json)$/.test(name)
    || /^lanes\/[\w-]+\/(?:result\.json|stdout\.log|stderr\.log)$/.test(name)
  if(!allowed){res.writeHead(403);res.end('Not a report asset');return}
  try{const bytes=await fs.readFile(path.join(root,name));const types={'.html':'text/html; charset=utf-8','.json':'application/json','.jpg':'image/jpeg','.png':'image/png','.mp4':'video/mp4'};res.setHeader('Content-Type',types[path.extname(name)]??'text/plain; charset=utf-8');res.end(bytes)}
  catch{res.writeHead(404);res.end('Evidence not available')}
}).listen(port,'127.0.0.1',()=>console.log('Report: http://127.0.0.1:'+port+'/report/index.html'))
