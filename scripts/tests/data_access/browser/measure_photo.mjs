// Isolated headless Chrome profile; no user browser state or external pages.
import {createServer} from 'node:http';
import {readFile,mkdtemp,writeFile,rm} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {tmpdir} from 'node:os';
import path from 'node:path';
const [fixtureDir,beforeJs,workerJs,output]=process.argv.slice(2);
const chrome=process.env.CHROME_BIN??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const html=`<!doctype html><meta charset="utf-8"><title>Local Photo import measurement</title><script src="/before.js"></script><body>Isolated synthetic workload</body>`;
const server=createServer(async(req,res)=>{try{const url=new URL(req.url,'http://localhost');const file=url.pathname==='/before.js'?beforeJs:url.pathname==='/photo_import_worker.js'?workerJs:url.pathname.startsWith('/fixture-')?path.join(fixtureDir,`photo_${url.pathname.substring(9)}.xlsx`):null;res.setHeader('Content-Type',file?.endsWith('.js')?'text/javascript':file?'application/octet-stream':'text/html');res.end(file?await readFile(file):html);}catch{res.statusCode=404;res.end();}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));const url=`http://127.0.0.1:${server.address().port}/`;
const profile=await mkdtemp(path.join(tmpdir(),'pos-photo-chrome-'));
const processChrome=spawn(chrome,['--headless=new','--disable-gpu',`--user-data-dir=${profile}`,'--remote-debugging-port=0','about:blank'],{stdio:'ignore'});
let socket;
try{
 let port;for(var i=0;i<100;i++){try{port=Number((await readFile(path.join(profile,'DevToolsActivePort'),'utf8')).split('\n')[0]);break;}catch{await new Promise(r=>setTimeout(r,50));}}
 if(!port)throw new Error('Chrome debugger did not start');
 const tab=await(await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`,{method:'PUT'})).json();
 socket=new WebSocket(tab.webSocketDebuggerUrl);await new Promise((r,j)=>{socket.onopen=r;socket.onerror=j;});
 let sequence=0;const pending=new Map();socket.onmessage=e=>{const v=JSON.parse(e.data);if(v.id){const p=pending.get(v.id);pending.delete(v.id);v.error?p.reject(new Error(JSON.stringify(v.error))):p.resolve(v.result);}};
 const call=(method,params={})=>new Promise((resolve,reject)=>{const id=++sequence;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params}));});
 await call('Runtime.enable');for(var i=0;i<100;i++){const r=await call('Runtime.evaluate',{expression:'typeof parsePhotoFixture',returnByValue:true});if(r.result.value==='function')break;await new Promise(r=>setTimeout(r,50));}
 const records=[];
 for(const rows of [100,1000,10000,10001]){
  for(var repeat=0;repeat<20;repeat++)for(const mode of ['before','after']){
   await call('HeapProfiler.collectGarbage');
   const expr=`(async()=>{
     const data=new Uint8Array(await(await fetch('/fixture-${rows}')).arrayBuffer());
     const gaps=[];let previous=performance.now(),running=true;
     function frame(now){gaps.push(now-previous);previous=now;if(running)requestAnimationFrame(frame);}
     requestAnimationFrame(frame);await new Promise(requestAnimationFrame);
     const start=performance.now();let result;
     if('${mode}'==='before')result=JSON.parse(parsePhotoFixture(data));
     else { const worker=new Worker('/photo_import_worker.js');try{result=await new Promise((resolve,reject)=>{worker.onmessage=e=>resolve(JSON.parse(e.data));worker.onerror=e=>reject(new Error(e.message));worker.postMessage(data);});}finally{worker.terminate();} }
     const ms=performance.now()-start;await new Promise(requestAnimationFrame);running=false;
     return {ms,max_frame_gap_ms:Math.max(...gaps),frames:gaps.length,rows:result.rows instanceof Array?result.rows.length:result.rows??0,rejected:!!result.error};
   })()`;
   const r=await call('Runtime.evaluate',{expression:expr,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));const v=r.result.value;
   if(rows<=10000&&(v.rows!==rows||v.rejected))throw new Error(JSON.stringify({rows,mode,v}));if(rows===10001&&!v.rejected)throw new Error('Over-limit accepted');
   records.push({mode,workload_rows:rows,repeat,...v});
  }
  console.log(`CHROME_PHOTO_ROWS=${rows}`);
 }
 await writeFile(output,JSON.stringify({environment:'Isolated desktop headless Chrome; immutable pre-change parser on main thread versus current built worker and real JSON transfer. Synthetic exact same XLSX bytes; 20 interleaved warm samples. rAF gaps are browser event-loop/frame scheduling gaps, not physical-device Flutter raster timings. Native AOT RSS measured separately; browser heap peak not claimed.',records},null,2));
}finally{socket?.close();const closed=new Promise(r=>processChrome.once('exit',r));processChrome.kill();await closed;server.closeAllConnections();await new Promise(r=>server.close(r));await rm(profile,{recursive:true,force:true,maxRetries:5,retryDelay:100});}
