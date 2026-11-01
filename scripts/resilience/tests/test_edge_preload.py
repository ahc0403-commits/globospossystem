"""Actual Deno listener adapter, independent of expensive database fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import urllib.request

ROOT=Path(__file__).resolve().parents[3]
DENO=os.environ.get('POS_FIXTURE_DENO')
CACHE=os.environ.get('POS_FIXTURE_DENO_CACHE')


@unittest.skipUnless(DENO and CACHE,'Explicit owned Deno/cache required')
class EdgePreloadTests(unittest.TestCase):
    def execute(self,body,function='complete-initial-password-change',mismatch=False):
        with tempfile.TemporaryDirectory(prefix='edge-preload-contract-') as directory:
            area=Path(directory);source=area/'supabase/functions'/function/'index.ts'
            source.parent.mkdir(parents=True);source.write_text(body)
            ready=area/'ready.json';env=dict(os.environ)
            env.update(DENO_DIR=CACHE,DENO_NO_PACKAGE_JSON='1',DENO_TLS_CA_STORE='system',
              POS_FIXTURE_EDGE_SOURCE=source.as_uri() if not mismatch else source.as_uri()+'-different',
              POS_FIXTURE_RUN_ID='b'*32,POS_FIXTURE_EDGE_FUNCTION=function,POS_FIXTURE_EDGE_READY=str(ready))
            with (area/'log').open('w+') as log:
                child=subprocess.Popen([DENO,'run','--no-config','--no-npm','--frozen','--cached-only',
                  '--lock='+str(ROOT/'supabase/functions/complete-initial-password-change/deno.lock'),
                  '--allow-env','--allow-net=127.0.0.1','--allow-write='+str(ready),
                  '--preload='+str(ROOT/'scripts/resilience/office_edge_runtime.ts'),str(source)],
                  env=env,stdout=log,stderr=subprocess.STDOUT)
                try:
                    for _ in range(100):
                        if ready.exists() or child.poll() is not None:break
                        time.sleep(.02)
                    if mismatch:
                        self.assertFalse(ready.exists());self.assertIsNotNone(child.poll());return
                    self.assertTrue(ready.exists(),(log.seek(0),log.read()))
                    record=json.loads(ready.read_text());self.assertEqual(record['pid'],child.pid)
                    self.assertEqual(record['runId'],'b'*32)
                    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
                    with opener.open('http://127.0.0.1:'+str(record['port']),timeout=2) as response:
                        self.assertEqual(response.read(),b'main=true')
                finally:
                    if child.poll() is None:child.terminate()
                    child.wait(timeout=5)

    def test_modern_listener_retains_import_meta_main(self):
        self.execute('if(import.meta.main) Deno.serve(()=>new Response("main="+import.meta.main));','store-account-onboarding')

    def test_actual_legacy_std_listener_retains_import_meta_main(self):
        self.execute('import {serve} from "https://deno.land/std@0.177.0/http/server.ts";\n'
          'if(import.meta.main) serve(()=>new Response("main="+import.meta.main));')

    def test_mismatched_entrypoint_cannot_emit_owned_readiness(self):
        self.execute('Deno.serve(()=>new Response("unsafe"));',mismatch=True)


if __name__=='__main__':unittest.main()
