// Local synthetic measurements only. No production endpoints or credentials.
import { execFile, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { setTimeout as sleep } from 'node:timers/promises';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const db = process.env.SCALE_DB_CONTAINER;
const rest = process.env.SCALE_REST_CONTAINER;
const url = new URL(process.env.SCALE_RPC_URL);
if (!/^pos-scale-test-\d+-db$/.test(db ?? '') || url.hostname !== '127.0.0.1') {
  throw new Error('Disposable fixture and loopback URL required');
}
const output = resolve(process.argv[2]);
function sql(input, args = []) {
  return execFileSync('docker', ['exec', '-i', db, 'psql', '-XAt', '-v', 'ON_ERROR_STOP=1',
    '-U', 'postgres', '-d', 'payroll_test', ...args], { input, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 }).trim();
}
const apply = (path) => sql(readFileSync(path, 'utf8'));
const seed = (stores, historyDays=30) => sql(readFileSync('scripts/fixtures/scalability_seed.sql', 'utf8'), ['-v', `store_count=${stores}`, '-v', `history_days=${historyDays}`]);
const save = (name, data) => writeFileSync(resolve(output, name), `${JSON.stringify(data, null, 2)}\n`);
const uuid = (text) => {
  const s = createHash('md5').update(text).digest('hex');
  return `${s.slice(0,8)}-${s.slice(8,12)}-${s.slice(12,16)}-${s.slice(16,20)}-${s.slice(20)}`;
};
const storeId = (n) => `10000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
const queries = {
  fulfillment: `SELECT id,order_item_id,created_at FROM emergency_fulfillment_items WHERE queue_id='${uuid('queue-100-100')}' AND is_cancelled=false ORDER BY created_at,order_item_id`,
  payments: `SELECT id,amount,amount_portion FROM payments WHERE restaurant_id='${storeId(100)}' AND created_at>='2026-09-05 00:00+07' AND created_at<'2026-09-06 00:00+07' ORDER BY created_at,id`,
};
function plans() {
  return Object.fromEntries(Object.entries(queries).map(([key, query]) => [key,
    JSON.parse(sql(`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${query};`))[0]]));
}
// A selective day in a six-month retained history. With only 30 days densely
// clustered by store, PostgreSQL can rationally keep the old store-only index.
seed(100,180);
const before = plans();
apply('scripts/preflight_measured_operational_indexes.sql');
apply('supabase/migrations/20260905080000_measured_operational_indexes.sql');
apply('scripts/verify_measured_operational_indexes.sql');
const after = plans();
save('index-comparison.json', { measuredAt: new Date().toISOString(), historyDays:180, queries, before, after });
for (const [key, index] of Object.entries({ fulfillment: 'emergency_items_queue_open_created', payments: 'payments_store_created_id' })) {
  if (!JSON.stringify(after[key].Plan).includes(index)) throw new Error(`Expected measured index for ${key}`);
  if (before[key].Plan['Actual Rows'] !== after[key].Plan['Actual Rows']) throw new Error(`Row mismatch for ${key}`);
}
// Replay, rollback and reapply must all pass before running load scenarios.
apply('supabase/migrations/20260905080000_measured_operational_indexes.sql');
apply('scripts/verify_measured_operational_indexes.sql');
apply('scripts/rollback_measured_operational_indexes.sql');
if (sql("SELECT count(*) FROM pg_indexes WHERE indexname IN ('emergency_items_queue_open_created','payments_store_created_id');") !== '0') throw new Error('Rollback failed');
apply('supabase/migrations/20260905080000_measured_operational_indexes.sql');
apply('scripts/verify_measured_operational_indexes.sql');
console.log('SCALE_INDEX_COMPARISON=PASS');

function snapshot() {
  return JSON.parse(sql(`SELECT json_build_object('time',clock_timestamp(),'wal_bytes',(SELECT wal_bytes FROM pg_stat_wal),
    'db',(SELECT row_to_json(d) FROM (SELECT xact_commit,xact_rollback,blks_read,blks_hit,temp_bytes FROM pg_stat_database WHERE datname=current_database()) d),
    'statements',(SELECT coalesce(json_agg(s),'[]') FROM (SELECT queryid,calls,total_exec_time,rows,shared_blks_hit,shared_blks_read,temp_blks_written
      FROM pg_stat_statements WHERE dbid=(SELECT oid FROM pg_database WHERE datname=current_database()) ORDER BY total_exec_time DESC LIMIT 20) s));`));
}
function percentile(values, pct) {
  if (!values.length) return null;
  const sorted = [...values].sort((a,b) => a-b);
  return Number(sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * pct) - 1)].toFixed(2));
}
async function scenario(stores, users) {
  seed(stores);
  // Warm schema/plan/buffer paths once; this is not a cold-cache experiment.
  await fetch(new URL('/rpc/get_store_report_summary', url), {
    method: 'POST', headers: { 'content-type': 'application/json', 'x-test-actor': '20000000-0000-0000-0000-000000000003' },
    body: JSON.stringify({p_store_id:storeId(1),p_from_date:'2026-09-05',p_to_date:'2026-09-05'}),
  }).then(async r => { if (!r.ok) throw new Error(await r.text()); await r.text(); });
  sql('SELECT pg_stat_statements_reset();');
  const metricsBefore = snapshot();
  const samples = [], cpuSamples = [], samplingTasks = [];
  const start = performance.now(), durationMs = 20000, end = start + durationMs;
  let maxInFlight = 0, inFlight = 0;
  const sampler = setInterval(() => {
    // Keep container metric collection off the HTTP driver's event loop.
    samplingTasks.push(execFileAsync('docker', ['stats','--no-stream','--format','{{json .}}',db,rest],{encoding:'utf8'})
      .then(({stdout}) => cpuSamples.push({elapsedMs:Math.round(performance.now()-start),stats:stdout.trim().split('\n').map(JSON.parse)}))
      .catch(e => cpuSamples.push({error:e.name})));
  }, 5000);
  await Promise.all(Array.from({length:users}, async (_, user) => {
    // Spread initial arrivals over one second; then one request per VU at a
    // time, with five-second think time. This is explicitly a closed-loop test.
    await sleep((user % 100) * 10);
    const store = user % stores + 1;
    const kind = user % 10 < 7 ? 'queue_items' : user % 10 < 9 ? 'store_report' : 'all_store_report';
    const path = kind==='queue_items' ? 'fixture_kds_queue_items' : kind==='store_report' ? 'get_store_report_summary' : 'get_store_revenue_summary';
    const body = kind==='queue_items' ? {p_queue_id:uuid(`queue-${store}-${user%100+1}`)} : {
      ...(kind==='store_report' ? {p_store_id:storeId(store)} : {p_store_ids:Array.from({length:stores},(_,i)=>storeId(i+1))}),
      p_from_date:'2026-09-05',p_to_date:'2026-09-05',
    };
    while (performance.now()<end) {
      const at=performance.now();
      inFlight++; maxInFlight=Math.max(maxInFlight,inFlight);
      let status=0, bytes=0, valid=false, error=null;
      try {
        const response=await fetch(new URL(`/rpc/${path}`,url), {method:'POST',headers:{'content-type':'application/json',
          'x-test-actor':'20000000-0000-0000-0000-000000000003'},body:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
        status=response.status;
        const raw=await response.text(); bytes=Buffer.byteLength(raw);
        if (response.ok) {
          const value=JSON.parse(raw);
          // Exact fixture arithmetic: 33 POS payments + 3 delivery rows + one
          // Photo day = 3,400,000 per store, including 40,000 Photo net sales.
          valid=kind==='queue_items' ? Array.isArray(value)&&value.length===4 : kind==='store_report'
            ? value.dine_in+value.delivery===3400000
            : value.store_count===stores&&value.rows.every(r=>r.dine_in+r.delivery===3400000);
        } else {
          try { error=JSON.parse(raw).code ?? `HTTP_${status}`; }
          catch { error=`HTTP_${status}`; }
        }
      } catch(e) { error=e.name; }
      finally { inFlight--; }
      samples.push({kind,status,bytes,valid,error,ms:performance.now()-at});
      if(performance.now()<end) await sleep(Math.min(5000,end-performance.now()));
    }
  }));
  clearInterval(sampler);
  const elapsedMs=performance.now()-start;
  await Promise.all(samplingTasks);
  await sleep(1200); // stats flush; excluded from request throughput interval.
  const metricsAfter=snapshot();
  const grouped=Object.fromEntries(['queue_items','store_report','all_store_report'].map(kind=>{
    const rows=samples.filter(r=>r.kind===kind), latencies=rows.map(r=>r.ms);
    return [kind,{requests:rows.length,errors:rows.filter(r=>!r.valid).length,responseBytes:rows.reduce((s,r)=>s+r.bytes,0),
      p50Ms:percentile(latencies,.5),p95Ms:percentile(latencies,.95),p99Ms:percentile(latencies,.99)}];
  }));
  const result={measuredAt:new Date().toISOString(),stores,virtualUsers:users,durationMs,elapsedMs,maxInFlight,
    requests:samples.length,requestsPerSecond:samples.length/(elapsedMs/1000),errors:samples.filter(r=>!r.valid).length,
    errorCounts:samples.filter(r=>!r.valid).reduce((counts,r)=>{const key=r.error??'CONTENT_MISMATCH';counts[key]=(counts[key]??0)+1;return counts;},{}),
    grouped,cpuSamples,metricsBefore,metricsAfter,errorSamples:samples.filter(r=>!r.valid).slice(0,10)};
  save(`scenario-${stores}-${users}.json`,result);
  console.log(JSON.stringify({stores,users,requests:result.requests,errors:result.errors,maxInFlight,grouped}));
}
save('environment.json',{node:process.version,measuredAt:new Date().toISOString(),databaseImage:'supabase/postgres:17.6.1.104',
  postgrestImage:'supabase/postgrest:v14.5',dbCpuLimit:2,dbMemoryGiB:2,restCpuLimit:1,restMemoryMiB:512,dbPool:10,
  dataPerStore:{payments:1000,orders:1000,externalSales:100,photoDays:30,queues:100,queueItems:400},
  caveat:'Synthetic minimal schema and fixture RLS helpers; actual report SQL, extracted queue item SQL. No browser, full KDS RPC, write workload, Realtime server, Vercel, network egress billing or production capacity certification.'});
for(const [stores,users] of [[10,50],[50,300],[100,1000]]) await scenario(stores,users);
