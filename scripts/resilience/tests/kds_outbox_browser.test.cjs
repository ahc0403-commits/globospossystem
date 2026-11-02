'use strict';
// Actual isolated Chromium IndexedDB. No user browser/profile or production URL.
const {test,before,beforeEach,after}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const http=require('node:http');
const {spawn,execFileSync}=require('node:child_process');
const {createHash}=require('node:crypto');
const {setTimeout:delay}=require('node:timers/promises');
let browser,server,socket,profile,sequence=0;
const pending=new Map();
const chromium=process.env.CHROMIUM_BIN||process.env.CHROME_EXECUTABLE||'chromium';

function command(method,params={}) {
  return new Promise((resolve,reject)=>{
    const id=++sequence;
    const timer=setTimeout(()=>{pending.delete(id);reject(Error('Owned Chromium command timeout'));},20000);
    pending.set(id,{resolve,reject,timer});
    socket.send(JSON.stringify({id,method,params}));
  });
}
async function evaluate(expression) {
  const value=await command('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});
  if(value.exceptionDetails) throw Error(value.exceptionDetails.exception?.description||'Browser fixture failed');
  return value.result.value;
}
async function ready() {
  for(let i=0;i<100;i++) {
    try {if(await evaluate('typeof globosEmergencyProgressJournalPut === "function"')) return;}
    catch (_) { /* navigation may temporarily replace the execution context */ }
    await delay(50);
  }
  throw Error('Progress journal bridge did not initialize');
}

before(async()=>{
  const html=fs.readFileSync(path.resolve(__dirname,'../../../web/index.html'),'utf8');
  const source=html.match(/\(\(\) => \{\s*const outboxDbName[\s\S]*?\n    \}\)\(\);/)?.[0];
  assert.ok(source,'Extract the actual complete outbox/voice closure');
  server=http.createServer((req,res)=>{
    res.writeHead(200,{'content-type':'text/html; charset=utf-8'});
    res.end('<!doctype html><title>Isolated journal fixture</title><script>'+source+'</script>');
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  profile=fs.mkdtempSync(path.join(os.tmpdir(),'pos-kds-browser-'));
  browser=spawn(chromium,['--headless','--no-sandbox','--disable-dev-shm-usage',
    '--disable-gpu','--disable-background-networking','--disable-component-update',
    '--disable-sync','--no-first-run','--no-default-browser-check',
    '--remote-debugging-address=127.0.0.1','--remote-debugging-port=0',
    '--user-data-dir='+profile,'http://127.0.0.1:'+server.address().port+'/fixture'],{stdio:'ignore'});
  let target;
  for(let i=0;i<100;i++) {
    try {
      const port=Number(fs.readFileSync(path.join(profile,'DevToolsActivePort'),'utf8').split('\n')[0]);
      const pages=await fetch('http://127.0.0.1:'+port+'/json/list',{signal:AbortSignal.timeout(1000)}).then(r=>r.json());
      target=pages.find(p=>p.type==='page'&&p.url.endsWith('/fixture'));
      if(target) break;
    } catch (_) { /* bounded startup only */ }
    await delay(50);
  }
  assert.ok(target,'Owned Chromium fixture target must exist');
  socket=new WebSocket(target.webSocketDebuggerUrl);
  socket.addEventListener('message',event=>{
    const result=JSON.parse(event.data);const waiter=pending.get(result.id);
    if(!waiter) return;
    pending.delete(result.id);clearTimeout(waiter.timer);
    result.error?waiter.reject(Error(result.error.message)):waiter.resolve(result.result);
  });
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  await ready();
  process.stdout.write('# '+execFileSync(chromium,['--version'],{encoding:'utf8'}).trim()+'; source SHA256 '+createHash('sha256').update(source).digest('hex')+'\n');
});

beforeEach(async()=>{
  await evaluate(`(async()=>{for(const name of ['globos-pos-emergency','globos-pos-progress-journal-v1']) {
    await new Promise((resolve,reject)=>{const r=indexedDB.deleteDatabase(name);r.onsuccess=resolve;r.onerror=()=>reject(r.error);r.onblocked=()=>reject(Error('Fixture database remained open'));});
  }})()`);
});

after(async()=>{
  for(const waiter of pending.values()){clearTimeout(waiter.timer);waiter.reject(Error('Fixture closing'));}
  pending.clear();socket?.close();
  if(browser&&browser.exitCode===null) {
    const stopped=new Promise(resolve=>browser.once('exit',resolve));
    browser.kill('SIGTERM');await Promise.race([stopped,delay(2000)]);
    if(browser.exitCode===null){browser.kill('SIGKILL');await stopped;}
  }
  if(server){server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
  if(profile) fs.rmSync(profile,{recursive:true,force:true});
});

test('older clients cannot see or transmit a prepared progress record',async()=>{
  const value=await evaluate(`(async()=>{
    await globosEmergencyProgressJournalPut('progress-1',JSON.stringify({_outbox_progress_journal:1,_outbox_phase:'prepared',_outbox_created_at:100}));
    await globosEmergencyOutboxPut('legacy-1',JSON.stringify({kind:'complete_order'}));
    return {legacy:JSON.parse(await globosEmergencyOutboxReadAll()).map(r=>r.id),progress:JSON.parse(await globosEmergencyProgressJournalReadAll()).map(r=>r.id)};
  })()`);
  assert.deepEqual(value,{legacy:['legacy-1'],progress:['progress-1']});
});

test('phase updates retain the original intent time and do not reorder it',async()=>{
  const value=await evaluate(`(async()=>{
    await globosEmergencyProgressJournalPut('first',JSON.stringify({_outbox_created_at:100,_outbox_phase:'prepared'}));
    await globosEmergencyProgressJournalPut('second',JSON.stringify({_outbox_created_at:200,_outbox_phase:'prepared'}));
    await globosEmergencyProgressJournalPut('first',JSON.stringify({_outbox_created_at:100,_outbox_phase:'queued'}));
    return JSON.parse(await globosEmergencyProgressJournalReadAll()).map(r=>[r.id,r.createdAt]);
  })()`);
  assert.deepEqual(value,[['first',100],['second',200]]);
});

test('progress cleanup preserves all legacy records',async()=>{
  const value=await evaluate(`(async()=>{
    await globosEmergencyOutboxPut('same-id',JSON.stringify({kind:'legacy'}));
    await globosEmergencyProgressJournalPut('same-id',JSON.stringify({_outbox_created_at:100}));
    await globosEmergencyProgressJournalDelete('same-id');
    return [JSON.parse(await globosEmergencyOutboxReadAll()).length,JSON.parse(await globosEmergencyProgressJournalReadAll()).length];
  })()`);
  assert.deepEqual(value,[1,0]);
});

test('a checksum failure is reported instead of becoming an empty journal',async()=>{
  const value=await evaluate(`(async()=>{
    await globosEmergencyProgressJournalPut('corrupt',JSON.stringify({_outbox_created_at:100}));
    const record=JSON.parse(await globosEmergencyProgressJournalReadAll())[0];
    const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('globos-pos-progress-journal-v1',1);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
    await new Promise((resolve,reject)=>{const tx=db.transaction('progress-outbox','readwrite');tx.objectStore('progress-outbox').put({...record,payload:'{"corrupt":true}'});tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);});db.close();
    try{await globosEmergencyProgressJournalReadAll();return false;}catch(error){return String(error).includes('KDS_OUTBOX_CHECKSUM_MISMATCH');}
  })()`);
  assert.equal(value,true);
});

test('capacity is bounded at 1000 while updates remain permitted',async()=>{
  const value=await evaluate(`(async()=>{
    for(let i=0;i<1000;i++) await globosEmergencyProgressJournalPut('item-'+i,JSON.stringify({_outbox_created_at:100+i}));
    let rejected=false;try{await globosEmergencyProgressJournalPut('overflow','{}');}catch(error){rejected=String(error).includes('KDS_OUTBOX_CAPACITY_EXCEEDED');}
    await globosEmergencyProgressJournalPut('item-0',JSON.stringify({_outbox_created_at:100,_outbox_phase:'queued'}));
    return {rejected,count:JSON.parse(await globosEmergencyProgressJournalReadAll()).length};
  })()`);
  assert.deepEqual(value,{rejected:true,count:1000});
});

test('a real page reload retains committed progress records',async()=>{
  await evaluate(`globosEmergencyProgressJournalPut('persisted',JSON.stringify({_outbox_created_at:100}))`);
  await command('Page.reload');await ready();
  assert.deepEqual(await evaluate(`(async()=>JSON.parse(await globosEmergencyProgressJournalReadAll()).map(r=>r.id))()`),['persisted']);
});
