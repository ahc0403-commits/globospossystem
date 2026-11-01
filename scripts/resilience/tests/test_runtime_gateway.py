"""Transport/isolation guards only; actual Auth/SQL cases run in owned platform."""
import importlib.util
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import socket
import time
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
                if self.headers.get('Upgrade')=='websocket':
                    seen.append(('tenant',self.headers.get('Host')))
                    key=self.headers['Sec-WebSocket-Key']
                    accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                    self.send_response(101);self.send_header('Upgrade','websocket')
                    self.send_header('Connection','Upgrade');self.send_header('Sec-WebSocket-Accept',accept);self.end_headers()
                    data=self.connection.recv(16384)
                    if data:self.connection.sendall(data)
                    self.close_connection=True
                    return
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

    def test_signed_file_without_project_key_reaches_real_storage_signature_checks(self):
        self.gw.targets['storage']='http://127.0.0.1:'+str(self.target.server_address[1])
        with self.request('/storage/v1/object/sign/bucket/file?token=fixture-signature',key='') as response:
            self.assertEqual(response.status,200)
        self.assertEqual(self.seen,[('/object/sign/bucket/file?token=fixture-signature',None)])

    def test_private_storage_listing_still_requires_project_key(self):
        self.gw.targets['storage']='http://127.0.0.1:'+str(self.target.server_address[1])
        with self.request('/storage/v1/bucket',key='') as response:self.assertEqual(response.status,401)
        self.assertEqual(self.seen,[])

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

    def websocket(self,key='fixture-anon',origin=None):
        connection=socket.create_connection(self.gw.server_address,timeout=2)
        request=('GET /realtime/v1/websocket?apikey='+key+'&vsn=1.0.0 HTTP/1.1\r\nHost: localhost\r\n'
          'Upgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\n'
          'Sec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\n'+('Origin: '+origin+'\r\n' if origin else '')+'\r\n')
        connection.sendall(request.encode());header=b''
        while not header.endswith(b'\r\n\r\n'):header+=connection.recv(1)
        return connection,header

    def test_websocket_rejects_wrong_project_external_origin_and_unprepared_server(self):
        for key,origin,expected in [('another-project',None,b'401'),('fixture-anon','https://external.invalid',b'403'),('fixture-anon',None,b'501')]:
            with self.subTest(status=expected):
                connection,header=self.websocket(key,origin)
                connection.close();self.assertIn(expected,header.split(b'\r\n')[0])
        self.assertEqual(self.seen,[])

    def test_actual_tcp_upgrade_preserves_bytes_rewrites_only_tenant_and_closes(self):
        self.gw.websocket_target='http://127.0.0.1:'+str(self.target.server_address[1])
        self.gw.websocket_tenant='realtime-pos'
        # All HTTP slots occupied: a WebSocket has separate bounded capacity.
        for _ in range(16):self.gw.slots.acquire()
        try:connection,header=self.websocket()
        finally:
            for _ in range(16):self.gw.slots.release()
        with connection:
            self.assertIn(b'101',header.split(b'\r\n')[0])
            payload=b'\x81\x80\x00\x01\x02\x03'
            connection.sendall(payload);self.assertEqual(connection.recv(len(payload)),payload)
        for _ in range(100):
            if self.gw.snapshot()['websocketActive']==0:break
            time.sleep(.01)
        self.assertIn(('tenant','realtime-pos'),self.seen)
        self.assertEqual(self.gw.snapshot()['websocketPeak'],1)
        self.assertEqual(self.gw.snapshot()['websocketTransferredBytes'],len(payload)*2)
        self.assertEqual(self.gw.snapshot()['websocketActive'],0)
        self.assertEqual(sum(self.gw.snapshot()['latencyCounts']),0)
        self.assertEqual(sum(self.gw.snapshot()['websocketLifetimeCounts']),1)

    def test_websocket_capacity_has_an_explicit_limit(self):
        for _ in range(32):self.gw.websocket_slots.acquire()
        try:
            connection,header=self.websocket();connection.close()
            self.assertIn(b'503',header.split(b'\r\n')[0])
        finally:
            for _ in range(32):self.gw.websocket_slots.release()
        self.assertEqual(self.seen,[])


if __name__=='__main__':unittest.main()
