"""Loopback-only, synthetic workload; one sequential read lane per terminal."""
import argparse, base64, concurrent.futures, hashlib, hmac, json, math, pathlib, random, threading, time, urllib.request, urllib.error
p=argparse.ArgumentParser();p.add_argument('url');p.add_argument('output',type=pathlib.Path);p.add_argument('--total',type=int,required=True);p.add_argument('--today',type=int,required=True);p.add_argument('--rounds',type=int,default=3);a=p.parse_args()
if not a.url.startswith('http://127.0.0.1:'):raise SystemExit('Loopback only')
def uid(n):return f'ba000000-0000-4000-8000-{n:012}'
def token(actor):
 enc=lambda x:base64.urlsafe_b64encode(json.dumps(x,separators=(',',':')).encode()).rstrip(b'=')
 msg=enc({'alg':'HS256','typ':'JWT'})+b'.'+enc({'role':'authenticated','sub':uid(900020+actor),'exp':int(time.time())+3600,'accessible_store_ids':['273b057e-3b69-46e3-93c1-6194c2802849']})
 return (msg+b'.'+base64.urlsafe_b64encode(hmac.new(b'jgb-isolated-jwt-secret-for-local-load-test',msg,hashlib.sha256).digest()).rstrip(b'=')).decode()
def rpc(name,body,actor):
 req=urllib.request.Request(a.url+'/rpc/'+name,data=json.dumps(body).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+token(actor)})
 start=time.perf_counter()
 try:
  with urllib.request.urlopen(req,timeout=45) as res:raw=res.read()
 except urllib.error.HTTPError as e:raise RuntimeError(f'{name} HTTP{e.code}: {e.read().decode()[:500]}') from None
 v=json.loads(raw);ms=(time.perf_counter()-start)*1000
 if name=='get_jeongabok_kds_tickets_v3':
  assert len(v['tickets'])==len(set(body['p_queue_ids']))
  for row in v['tickets']:
   t=row['ticket']
   if t is not None:
    assert t['kitchen_direct_to_floor']
    if actor!=1:assert t['floor_label']==('2F' if actor==2 else '3F')
 if name=='get_jeongabok_kds_completed_page_v1':assert len(v['orders'])<=50
 return {'rpc':name,'ms':ms,'bytes':len(raw)},v

def summarize(rows):
 ts=sorted(r['ms'] for r in rows);pct=lambda n:round(ts[max(0,math.ceil(len(ts)*n)-1)],3)
 return {'requests':len(rows),'p50_ms':pct(.5),'p95_ms':pct(.95),'p99_ms':pct(.99),'max_ms':round(ts[-1],3),'max_response_bytes':max(r['bytes'] for r in rows)}
ids=[uid(200000+n) for n in range(max(1,a.total-99),a.total+1)]
# Include explicit tombstones and repeat IDs in a bounded input.
ids=(ids+[uid(1)]*100)[:100]
work=[('get_kds_sync_config',{}),('get_jeongabok_kds_bootstrap_v3',{}),('get_kds_changes_v2',{'p_after_revision':0,'p_limit':100}),('get_jeongabok_kds_tickets_v3',{'p_queue_ids':ids[:50]}),('get_jeongabok_kds_tickets_v3',{'p_queue_ids':ids[50:]}),('get_jeongabok_kds_completed_page_v1',{'p_limit':50})]
for actor in (1,2,3,5):
 for name,body in work:rpc(name,body,actor)
result={'total_queues':a.total,'today_queues':a.today,'database':'PostgreSQL17.6 full production schema; synthetic rows only','line_distribution':{'80_queue_histogram':{'0':1,'1':17,'2':12,'3':12,'4':10,'5':3,'6':11,'7':4,'8':6,'9':3,'22':1}},'limits':{'db_cpu':2,'db_memory_mib':2048,'postgrest_cpu':1,'postgrest_memory_mib':512,'pool':10,'batch':50,'server_batch_cap':100,'history_page':50,'max_reads_per_terminal':1},'runs':[]}
for terminals in (4,8,40):
 barrier=threading.Barrier(terminals);active=[0]*terminals;peak=[0]*terminals
 def terminal(n):
  actor=(1,2,3,5)[n%4];rows=[];barrier.wait()
  for iteration in range(a.rounds):
   for name,body in work:
    active[n]+=1;peak[n]=max(peak[n],active[n]);assert active[n]==1
    try:row,_=rpc(name,body,actor);rows.append(row)
    finally:active[n]-=1
   time.sleep(random.Random(n*100+iteration).uniform(.02,.06))
  return rows
 start=time.perf_counter()
 with concurrent.futures.ThreadPoolExecutor(max_workers=terminals) as pool:rows=[r for batch in pool.map(terminal,range(terminals)) for r in batch]
 run={'terminals':terminals,'roles':['kitchen','stored2F','stored3F-A','stored3F-B'],'mode':'synchronized burst, faster than normal 5s watchdog','rounds':a.rounds,'duration_s':round(time.perf_counter()-start,3),'errors':0,'max_in_flight_per_terminal':max(peak),'metrics':{name:summarize([r for r in rows if r['rpc']==name]) for name in sorted({r['rpc'] for r in rows})}}
 result['runs'].append(run);print(json.dumps(run),flush=True)
a.output.write_text(json.dumps(result,indent=2)+'\n')
if max(r['metrics']['get_jeongabok_kds_tickets_v3']['max_response_bytes'] for r in result['runs'])>1048576:raise SystemExit('Batch >1MiB: reduce default to25 and rerun')
