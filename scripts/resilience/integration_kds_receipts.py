#!/usr/bin/env python3
"""Actual PostgreSQL receipt/ACL fixture, not a production-schema restoration."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT/'supabase/migrations/20261101045728_kds_progress_receipt_reconciliation.sql'
ACTOR = '10000000-0000-4000-8000-000000000001'
PROFILE = '20000000-0000-4000-8000-000000000001'
STORE = '30000000-0000-4000-8000-000000000001'
SESSION = '40000000-0000-4000-8000-000000000001'
EVENT = '50000000-0000-4000-8000-000000000001'
REQUEST = '60000000-0000-4000-8000-000000000001'


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


class KdsReceiptsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container='pos-kds-receipts-'+uuid.uuid4().hex[:12]
        cls.call(['docker','run','-d','--rm','--network','none','--memory','512m','--cpus','1',
                  '--name',cls.container,'-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:17.6'])
        cls.addClassCleanup(lambda:cls.call(['docker','rm','-f',cls.container],check=False))
        for _ in range(60):
            if cls.call(['docker','exec',cls.container,'pg_isready','-U','postgres'],check=False).returncode==0:
                break
            time.sleep(.5)
        else:
            raise RuntimeError('Owned KDS fixture did not become ready')
        cls.sql((ROOT/'test/fixtures/kds_progress_receipts.sql').read_text())
        cls.sql(MIGRATION.read_text())

    @staticmethod
    def call(argv,text=None,check=True):
        result=subprocess.run(argv,input=text,text=True,capture_output=True,timeout=60)
        if check and result.returncode:
            raise AssertionError(result.stderr[-3000:])
        return result

    @classmethod
    def sql(cls,body,check=True):
        return cls.call(['docker','exec','-i',cls.container,'psql','-X','-U','postgres','-d','postgres',
                        '-v','ON_ERROR_STOP=1','-Atq'],body,check)

    def read(self,ids,store=STORE,actor=ACTOR):
        query='SELECT public.get_kds_progress_receipts_v1('+literal(store)+',ARRAY['
        query+=','.join(literal(x) for x in ids)+']::uuid[]);'
        return self.sql("SET ROLE authenticated;SET request.jwt.claim.sub="+literal(actor)+';'+query)

    def test_normal_event_and_jeongabok_request_resolve_to_the_same_authoritative_event(self):
        rows=json.loads(self.read([EVENT,REQUEST]).stdout)
        self.assertEqual({r['event_id'] for r in rows},{EVENT,REQUEST})
        self.assertEqual({r['actual_event_id'] for r in rows},{EVENT})
        self.assertTrue(all(r['session_id']==SESSION and r['delta']==1 for r in rows))
        self.assertNotIn('response',json.dumps(rows))

    def test_another_actor_in_the_same_store_cannot_read_or_claim_the_receipt(self):
        rows=json.loads(self.read([EVENT,REQUEST],actor=ACTOR[:-1]+'2').stdout)
        self.assertEqual(rows,[])

    def test_another_store_and_inactive_actor_are_denied(self):
        for actor,store in [(ACTOR,STORE[:-1]+'2'),(ACTOR[:-1]+'3',STORE)]:
            with self.assertRaisesRegex(AssertionError,'permission|privilege'):
                self.read([EVENT],store=store,actor=actor)

    def test_unknown_empty_duplicate_and_oversized_requests(self):
        self.assertEqual(json.loads(self.read([]).stdout),[])
        self.assertEqual(json.loads(self.read([EVENT[:-1]+'9']).stdout),[])
        self.assertEqual(len(json.loads(self.read([EVENT,EVENT]).stdout)),1)
        with self.assertRaisesRegex(AssertionError,'KDS_RECEIPT_BATCH_INVALID'):
            self.read([EVENT]*101)

    def test_anonymous_role_and_private_table_reads_remain_denied(self):
        result=self.sql("SET ROLE anon;SELECT public.get_kds_progress_receipts_v1("+literal(STORE)+",'{}'::uuid[]);",False)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.sql("SELECT has_table_privilege('authenticated','public.emergency_kitchen_batch_actions','SELECT');").stdout.strip(),'f')
        self.assertEqual(self.sql("SELECT has_function_privilege('anon','public.get_kds_progress_receipts_v1(uuid,uuid[])','EXECUTE');").stdout.strip(),'f')

    def test_parallel_receipt_reads_never_modify_native_receipts(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            values=list(pool.map(lambda _:json.loads(self.read([EVENT,REQUEST]).stdout),range(20)))
        self.assertTrue(all(len(rows)==2 for rows in values))
        self.assertEqual(self.sql('SELECT count(*) FROM public.emergency_kitchen_batch_actions;').stdout.strip(),'1')
        self.assertEqual(self.sql('SELECT count(*) FROM public.emergency_fulfillment_events;').stdout.strip(),'1')

    def test_z_hundred_receipts_among_one_hundred_thousand_rows_remain_bounded(self):
        # Fixed synthetic scale; no production business rows or side effects.
        result=self.sql("""
INSERT INTO public.emergency_fulfillment_events(event_id,session_id,restaurant_id,actor_user_id,
  order_item_id,stage,delta,details)
SELECT ('70000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 '40000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001',
 '20000000-0000-4000-8000-000000000001','80000000-0000-4000-8000-000000000001',
 'floor_served',1,'{}' FROM generate_series(1,100000)n;
ANALYZE public.emergency_fulfillment_events;
SET ROLE authenticated;SET request.jwt.claim.sub='10000000-0000-4000-8000-000000000001';
DO $$ DECLARE ids uuid[]; value jsonb; start_time timestamptz; durations double precision[]='{}';
 i integer; p95 double precision;
BEGIN
 SELECT array_agg(('70000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid)
 INTO ids FROM generate_series(1,100)n;
 FOR i IN 1..30 LOOP
  start_time=clock_timestamp();
  value=public.get_kds_progress_receipts_v1('30000000-0000-4000-8000-000000000001',ids);
  durations=array_append(durations,extract(epoch FROM clock_timestamp()-start_time)*1000);
  IF jsonb_array_length(value)<>100 OR octet_length(value::text)>65536 THEN
   RAISE EXCEPTION 'KDS_RECEIPT_SCALE_OR_SIZE_FAILED';END IF;
 END LOOP;
 SELECT percentile_cont(.95) WITHIN GROUP(ORDER BY x) INTO p95 FROM unnest(durations)x;
 RAISE NOTICE 'KDS_RECEIPT_METRICS=%',jsonb_build_object('synthetic_event_rows',100001,
  'requests_per_rpc',100,'calls',30,'p95_server_ms',p95,'response_bytes',octet_length(value::text));
 IF p95>500 THEN RAISE EXCEPTION 'KDS_RECEIPT_FIXTURE_LATENCY_FAILED';END IF;
END $$;
""")
        print(result.stderr.strip(),flush=True)


if __name__=='__main__':
    unittest.main()
