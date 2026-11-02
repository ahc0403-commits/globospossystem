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
    try {if(await evaluate('typeof globosOrderIntentJournal === "function"')) return;}
    catch (_) { /* navigation may temporarily replace the execution context */ }
    await delay(50);
  }
  throw Error('Order journal bridge did not initialize');
}

before(async()=>{
  const source=fs.readFileSync(path.resolve(__dirname,'../../../web/order_intent_journal.js'),'utf8');
  const html=fs.readFileSync(path.resolve(__dirname,'../../../web/index.html'),'utf8');
  assert.ok(html.indexOf('src="order_intent_journal.js"') < html.indexOf('src="flutter_bootstrap.js"'),'Journal must load before Flutter');
  server=http.createServer((req,res)=>{
    res.writeHead(200,{'content-type':'text/html; charset=utf-8'});
    res.end('<!doctype html><title>Isolated journal fixture</title><script>'+source+'</script>');
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  profile=fs.mkdtempSync(path.join(os.tmpdir(),'pos-order-browser-'));
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
  await evaluate(`(async()=>{for(const name of ['globos-pos-order-intents-v1']) {
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


const record=(n,target='table-'+n)=>({version:1,operation:'op-'+n,project:'https://fixture.invalid',actor:'actor',store:'store',kind:'create',target,payload:JSON.stringify({p_store_id:'store',p_table_id:target,p_items:[{menu_item_id:'menu',quantity:1}],p_business_date:'2026-11-02'}),createdAt:1000+n,revision:1,phase:'prepared'});
function call(action,input){return evaluate('globosOrderIntentJournal('+JSON.stringify(action)+','+JSON.stringify(JSON.stringify(input))+').then(JSON.parse)');}

test('20 independent transactions share the original intent for the same table',async()=>{
 const result=await evaluate(`Promise.all(${JSON.stringify(Array.from({length:20},(_,n)=>record(n,'same')))}.map(record=>globosOrderIntentJournal('claim',JSON.stringify({record})).then(JSON.parse)))`);
 assert.equal(new Set(result.map(r=>r.operation)).size,1);
 assert.equal((await call('list',{project:'https://fixture.invalid',actor:'actor',store:'store'})).length,1);
});
test('unknown request survives a full page reopen and refuses payload mutation',async()=>{
 const original=await call('claim',{record:record(1)});
 const unknown={...original,phase:'unknown',revision:2};
 await call('update',{record:unknown,expectedRevision:1});await command('Page.reload');await ready();
 assert.deepEqual(await call('claim',{record:record(2,'table-1')}),unknown);
 await assert.rejects(call('retire',{record:unknown,expectedRevision:2}),/ORDER_JOURNAL_UNRESOLVED/);
 await assert.rejects(call('update',{record:{...unknown,payload:record(3).payload,phase:'confirmed',revision:3},expectedRevision:2}),/ORDER_JOURNAL_(IDENTITY_CHANGED|PAYLOAD_INVALID)/);
});
test('settlement is scoped, atomic and retains rejected requests for review',async()=>{
 for(let n=0;n<3;n++)await call('claim',{record:record(n)});
 await call('settle',{project:'https://fixture.invalid',actor:'other',store:'store',operations:['op-0']});
 assert.equal((await call('list',{project:'https://fixture.invalid',actor:'actor',store:'store'})).length,3);
 await call('settle',{project:'https://fixture.invalid',actor:'actor',store:'store',operations:['op-0'],rejected:['op-1']});
 const rows=await call('list',{project:'https://fixture.invalid',actor:'actor',store:'store'});
 assert.equal(rows.length,2);assert.equal(rows.find(r=>r.operation==='op-1').phase,'rejected');
 assert.deepEqual(await call('list',{project:'other',actor:'actor',store:'store'}),[]);
});
test('capacity failure preserves the original unresolved order',async()=>{
 await call('claim',{record:record(0)});
 const oversized=record(1);oversized.payload=JSON.stringify({...JSON.parse(oversized.payload),notes:'x'.repeat(256*1024)});
 await assert.rejects(call('claim',{record:oversized}),/ORDER_JOURNAL_INVALID/);
 assert.equal((await call('list',{project:'https://fixture.invalid',actor:'actor',store:'store'})).length,1);
});
