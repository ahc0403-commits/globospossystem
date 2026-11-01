"""Transport/isolation guards only; actual Auth/SQL cases run in owned platform."""
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import unittest
import urllib.error
import urllib.request

spec=importlib.util.spec_from_file_location('runtime_gateway',Path(__file__).parents[1]/'runtime_gateway.py')
gateway=importlib.util.module_from_spec(spec);spec.loader.exec_module(gateway)


class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.seen=[]
        seen=self.seen
        class Target(BaseHTTPRequestHandler):
            def log_message(self,*_):pass
            def do_GET(self):
                seen.append((self.path,self.headers.get('Authorization')))
                self.send_response(200);self.send_header('Content-Length','2');self.end_headers();self.wfile.write(b'{}')
        self.target=ThreadingHTTPServer(('127.0.0.1',0),Target)
        self.gw=gateway.RuntimeGateway(project='fixture',run_id='a'*32,
          auth='http://127.0.0.1:'+str(self.target.server_address[1]),
          rest='http://127.0.0.1:'+str(self.target.server_address[1]),anon='fixture-anon',service='fixture-service')
        for server in (self.target,self.gw):
            threading.Thread(target=server.serve_forever,daemon=True).start()
            self.addCleanup(server.server_close);self.addCleanup(server.shutdown)

    def request(self,path,key='fixture-anon',headers=None):
        request=urllib.request.Request(self.gw.origin+path,headers={'apikey':key,**(headers or {})})
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:return opener.open(request,timeout=2)
        except urllib.error.HTTPError as error:return error

    def test_real_tcp_preserves_original_authorization_and_route(self):
        with self.request('/auth/v1/user',headers={'Authorization':'Bearer original-fixture-actor'}) as response:
            self.assertEqual(response.status,200)
        self.assertEqual(self.seen,[('/user','Bearer original-fixture-actor')])

    def test_wrong_project_key_never_reaches_upstream(self):
        with self.request('/rest/v1/orders?select=id',key='other-project') as response:
            self.assertEqual(response.status,401)
        self.assertEqual(self.seen,[])

    def test_services_not_prepared_are_explicit_not_fake_success(self):
        with self.request('/storage/v1/object/photo') as response:
            self.assertEqual(response.status,501)
        self.assertEqual(self.seen,[])

    def test_only_the_explicit_owned_pos_edge_is_routed(self):
        self.gw.additional_edges['/functions/v1/store-account-onboarding']='http://127.0.0.1:'+str(self.target.server_address[1])
        with self.request('/functions/v1/store-account-onboarding',headers={'Authorization':'Bearer original-operator'}) as response:
            self.assertEqual(response.status,200)
        self.assertEqual(self.seen,[('/','Bearer original-operator')])
        with self.request('/functions/v1/another-function') as response:self.assertEqual(response.status,501)

    def test_local_cors_is_narrow_and_does_not_allow_external_origins(self):
        for origin,allowed in [('http://127.0.0.1:1234',True),('https://external.invalid',False)]:
            with self.request('/rest/v1/orders',headers={'Origin':origin}) as response:
                self.assertEqual(response.headers.get('Access-Control-Allow-Origin'),origin if allowed else None)

    def test_physical_response_loss_occurs_after_upstream_and_preserves_metrics(self):
        self.gw.drop_next['rest/rpc/confirmed_operation']=1
        with self.assertRaises(OSError):
            self.request('/rest/v1/rpc/confirmed_operation')
        self.assertEqual(self.seen,[('/rpc/confirmed_operation',None)])
        self.assertEqual(self.gw.snapshot()['faultResponsesDropped'],1)
        self.assertEqual(self.gw.snapshot()['calls']['GET rest/rpc/confirmed_operation'],1)

    def test_parallel_limit_rejects_excess_without_starting_transport(self):
        for _ in range(16):self.gw.slots.acquire()
        try:
            with self.request('/rest/v1/orders') as response:self.assertEqual(response.status,503)
        finally:
            for _ in range(16):self.gw.slots.release()
        self.assertEqual(self.seen,[])
        self.assertEqual(self.gw.snapshot()['statuses']['capacity-503'],1)

    def test_only_numeric_private_origins_and_valid_loopback_cors(self):
        for bad in ['https://127.0.0.1','http://8.8.8.8','http://user:password@127.0.0.1','http://localhost']:
            with self.assertRaises(ValueError):gateway.owned_origin(bad)
        for bad in ['http://localhost.evil.invalid','http://user@localhost','http://localhost/path','https://localhost']:
            self.assertFalse(gateway.local_origin(bad))


if __name__=='__main__':unittest.main()
