"""Bounded loopback adapter to this run's Auth/REST services, never production.

This replaces local API routing only. GoTrue verifies users and PostgREST applies
the actual JWT roles/RLS. No Auth, SQL, Edge or business result is simulated.
"""
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import hashlib
import hmac
import ipaddress
import json
import select
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def local_origin(value):
    parsed = urllib.parse.urlparse(value)
    return (parsed.scheme == 'http' and parsed.hostname in {'localhost', '127.0.0.1'}
            and not parsed.username and not parsed.password and not parsed.path
            and not parsed.query and not parsed.fragment)


def owned_origin(value):
    parsed = urllib.parse.urlparse(value)
    if (parsed.scheme != 'http' or parsed.username or parsed.password or parsed.path
            or parsed.query or parsed.fragment or parsed.port is None or parsed.port<=0):
        raise ValueError('Only an owned private HTTP service origin is allowed')
    if not ipaddress.ip_address(parsed.hostname).is_private:
        raise ValueError('Fixture target must be a private numeric address')
    return value


class RuntimeGateway(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self, *, project, run_id, auth, rest, anon, service):
        self.project, self.run_id = project, run_id
        self.targets = {'auth': owned_origin(auth), 'rest': owned_origin(rest)}
        self.keys = (anon, service)
        self.edge = None
        self.additional_edges = {}
        self.slots = threading.BoundedSemaphore(16)
        self.thread_slots = threading.BoundedSemaphore(48)
        self.websocket_slots = threading.BoundedSemaphore(32)
        self.websocket_target = None
        self.websocket_tenant = None
        self.websocket_connections = set()
        self.websocket_peak = self.websocket_bytes = 0
        self.guard = threading.Lock()
        self.counts, self.statuses = Counter(), Counter()
        self.active, self.max_active = 0, 0
        self.total_bytes, self.max_response_bytes = 0, 0
        self.latencies = [0] * 11
        self.websocket_lifetimes = [0] * 11
        self.drop_next = Counter()
        self.dropped = 0
        super().__init__(('127.0.0.1', 0), GatewayHandler)

    @property
    def origin(self):
        return 'http://127.0.0.1:' + str(self.server_address[1])

    def process_request(self, request, address):
        if not self.thread_slots.acquire(blocking=False):
            with self.guard:
                self.statuses['capacity-503'] += 1
            request.sendall(b'HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.thread_slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.thread_slots.release()

    def server_close(self):
        with self.guard:
            connections=list(self.websocket_connections)
        for pair in connections:
            for connection in pair:
                try:connection.shutdown(socket.SHUT_RDWR)
                except OSError:pass
        super().server_close()

    def snapshot(self):
        with self.guard:
            return {'calls': dict(self.counts), 'statuses': dict(self.statuses),
                    'active': self.active, 'maxActive': self.max_active,
                    'totalResponseBytes': self.total_bytes, 'maxResponseBytes': self.max_response_bytes,
                    'latencyBucketsSeconds': ['.01', '.05', '.1', '.25', '.5', '1', '2', '5', '10', '30', '>30'],
                    'latencyCounts': list(self.latencies),'websocketLifetimeCounts':list(self.websocket_lifetimes),
                    'faultResponsesDropped': self.dropped,
                    'websocketActive':len(self.websocket_connections),'websocketPeak':self.websocket_peak,
                    'websocketTransferredBytes':self.websocket_bytes}


class GatewayHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass  # Never log credentials, query strings, bodies or per-row IDs.

    def _reply(self, status, body, headers=None):
        self.send_response(status)
        for name, value in (headers or {}).items():
            if name.lower() not in {'content-length', 'transfer-encoding', 'connection', 'access-control-allow-origin'}:
                self.send_header(name, value)
        origin = self.headers.get('Origin', '')
        if local_origin(origin):
            self.send_header('Access-Control-Allow-Origin', origin)
            self.send_header('Access-Control-Allow-Headers', 'authorization,apikey,content-type,x-client-info,accept-profile,content-profile,prefer,range')
            self.send_header('Access-Control-Allow-Methods', 'GET,HEAD,POST,PATCH,PUT,DELETE,OPTIONS')
            self.send_header('Access-Control-Expose-Headers', 'content-range,range-unit,preference-applied,location')
            self.send_header('Vary', 'Origin')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)
        self.close_connection = True

    def _handle(self):
        start = time.monotonic()
        gateway = self.server
        route = 'unrouted'
        status, size = 500, 0
        websocket = self.command=='GET' and urllib.parse.urlsplit(self.path).path=='/realtime/v1/websocket'
        capacity=gateway.websocket_slots if websocket else gateway.slots
        if not capacity.acquire(blocking=False):
            with gateway.guard:gateway.statuses['capacity-503']+=1
            self._reply(503,b'')
            return
        with gateway.guard:
            gateway.active += 1
            gateway.max_active = max(gateway.max_active, gateway.active)
        try:
            self.connection.settimeout(15)
            parsed = urllib.parse.urlsplit(self.path)
            if websocket:
                status=self._websocket(parsed)
                route='realtime/websocket'
                return
            if self.command == 'OPTIONS':
                status = 204
                self._reply(status, b'')
                return
            if parsed.path == '/health':
                status = 200
                body = json.dumps({'kind':'owned-local-gateway', 'project':gateway.project, 'runId':gateway.run_id}).encode()
                self._reply(status, body, {'Content-Type':'application/json'})
                return
            supplied = self.headers.get('apikey', '')
            signed_or_public_file = self.command in {'GET','HEAD'} and (
                parsed.path.startswith('/storage/v1/object/sign/') or parsed.path.startswith('/storage/v1/object/public/'))
            if not signed_or_public_file and not any(hmac.compare_digest(supplied.encode(), key.encode()) for key in gateway.keys):
                status = 401
                self._reply(status, b'{"code":"FIXTURE_PROJECT_KEY_REQUIRED"}', {'Content-Type':'application/json'})
                return
            if self.headers.get('Transfer-Encoding'):
                status = 411
                self._reply(status, b'')
                return
            length = int(self.headers.get('Content-Length', '0'))
            if length < 0 or length > 5 * 1024 * 1024:
                status = 413
                self._reply(status, b'')
                return
            body = self.rfile.read(length) if length else None
            if body is not None and len(body) != length:
                raise ValueError('Incomplete fixture request')
            if parsed.path.startswith('/auth/v1/'):
                target = gateway.targets['auth'] + self.path[len('/auth/v1'):]
                route = 'auth/' + parsed.path.split('/')[3]
            elif parsed.path.startswith('/rest/v1/'):
                target = gateway.targets['rest'] + self.path[len('/rest/v1'):]
                route = 'rest/' + '/'.join(parsed.path.split('/')[3:5])
            elif parsed.path.startswith('/storage/v1/') and gateway.targets.get('storage'):
                target = gateway.targets['storage'] + self.path[len('/storage/v1'):]
                route = 'storage/' + '/'.join(parsed.path.split('/')[3:5])
            elif parsed.path == '/functions/v1/pos-bridge' and gateway.edge:
                target = owned_origin(gateway.edge) + '/'
                route = 'edge/pos-bridge'
            elif parsed.path in gateway.additional_edges:
                target = owned_origin(gateway.additional_edges[parsed.path]) + '/'
                route = 'edge/' + parsed.path.rsplit('/',1)[-1]
            else:
                status = 501
                self._reply(status, b'{"code":"FIXTURE_SERVICE_NOT_PREPARED"}', {'Content-Type':'application/json'})
                return
            headers = {k:v for k,v in self.headers.items()
                       if k.lower() not in {'host','content-length','connection','accept-encoding','transfer-encoding'}}
            headers['Accept-Encoding'] = 'identity'
            request = urllib.request.Request(target, data=body, headers=headers, method=self.command)
            # No ambient proxy can redirect fixture traffic to an external host.
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            try:
                response = opener.open(request, timeout=30)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                result = response.read(4 * 1024 * 1024 + 1)
                if len(result) > 4 * 1024 * 1024:
                    status = 502
                    self._reply(status, b'{"code":"FIXTURE_RESPONSE_BOUND"}', {'Content-Type':'application/json'})
                    return
                status, size = response.status, len(result)
                with gateway.guard:
                    drop = gateway.drop_next[route] > 0
                    if drop:
                        gateway.drop_next[route] -= 1
                        gateway.dropped += 1
                if drop:
                    self.close_connection = True  # Commit happened; acknowledgement is lost.
                    return
                self._reply(status, result, dict(response.headers))
        except (OSError, ValueError, urllib.error.URLError):
            status = 502
            try:
                self._reply(status, b'{"code":"FIXTURE_TRANSPORT_FAILURE"}', {'Content-Type':'application/json'})
            except OSError:
                pass
        finally:
            capacity.release()
            elapsed = time.monotonic() - start
            bounds = [.01,.05,.1,.25,.5,1,2,5,10,30]
            with gateway.guard:
                gateway.active -= 1
                gateway.counts[self.command + ' ' + route] += 1
                gateway.statuses[str(status)] += 1
                gateway.total_bytes += size
                gateway.max_response_bytes = max(size, gateway.max_response_bytes)
                buckets=gateway.websocket_lifetimes if websocket else gateway.latencies
                buckets[next((i for i,b in enumerate(bounds) if elapsed <= b), 10)] += 1

    def _websocket(self,parsed):
        """Forward RFC6455 bytes to this run's actual server, with bounded buffers.

        No message decoding, authorization response or business event is forged.
        HTTP has separate capacity so idle channels cannot starve reads/writes.
        """
        gateway=self.server
        query=urllib.parse.parse_qs(parsed.query,max_num_fields=12)
        keys=query.get('apikey',[])
        origin=self.headers.get('Origin','')
        if (len(self.path)>16384 or len(keys)!=1 or not any(
            hmac.compare_digest(keys[0].encode(),key.encode()) for key in gateway.keys)):
            self._reply(401,b'');return 401
        if origin and not local_origin(origin):
            self._reply(403,b'');return 403
        key=self.headers.get('Sec-WebSocket-Key','')
        try:valid_key=len(base64.b64decode(key,validate=True))==16
        except (ValueError,base64.binascii.Error):valid_key=False
        if (self.headers.get('Upgrade','').lower()!='websocket' or
            'upgrade' not in [x.strip().lower() for x in self.headers.get('Connection','').split(',')] or
            self.headers.get('Sec-WebSocket-Version')!='13' or not valid_key or
            self.headers.get('Content-Length','0')!='0' or self.headers.get('Transfer-Encoding')):
            self._reply(400,b'');return 400
        if not gateway.websocket_target:
            self._reply(501,b'');return 501
        target=urllib.parse.urlsplit(owned_origin(gateway.websocket_target))
        tenant=gateway.websocket_tenant
        if tenant not in {'realtime-pos','realtime-office'}:
            raise ValueError('Owned Realtime tenant missing')
        upstream=socket.create_connection((target.hostname,target.port),timeout=10)
        pair=(self.connection,upstream)
        try:
            # Only the expected handshake fields reach the private server.
            request=('GET /socket/websocket?'+parsed.query+' HTTP/1.1\r\nHost: '+tenant+
              '\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13'+
              '\r\nSec-WebSocket-Key: '+key+'\r\n\r\n')
            upstream.sendall(request.encode('ascii'))
            header=bytearray();deadline=time.monotonic()+10
            # Read exactly through the header, preserving the first event byte.
            while not header.endswith(b'\r\n\r\n'):
                if len(header)>=16384 or time.monotonic()>deadline:
                    raise ValueError('Realtime handshake bound')
                part=upstream.recv(1)
                if not part:raise ValueError('Realtime handshake ended')
                header.extend(part)
            lines=bytes(header).decode('latin-1').split('\r\n')
            headers={k.lower().strip():v.strip() for line in lines[1:] if ':' in line for k,v in [line.split(':',1)]}
            accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            status_line=lines[0].split(' ')
            if (len(status_line)<2 or status_line[1]!='101' or headers.get('sec-websocket-accept')!=accept or
                headers.get('upgrade','').lower()!='websocket'):
                self._reply(502,b'');return 502
            self.send_response(101)
            self.send_header('Upgrade','websocket');self.send_header('Connection','Upgrade')
            self.send_header('Sec-WebSocket-Accept',accept);self.end_headers();self.wfile.flush()
            self.close_connection=True
            with gateway.guard:
                gateway.websocket_connections.add(pair)
                gateway.websocket_peak=max(gateway.websocket_peak,len(gateway.websocket_connections))
            for connection in pair:connection.settimeout(5)
            started=last=time.monotonic()
            try:
                while time.monotonic()-started<13*60*60 and time.monotonic()-last<120:
                    readable,_,_=select.select(pair,[],[],1)
                    for source in readable:
                        chunk=source.recv(16384)
                        if not chunk:return 101
                        destination=upstream if source is self.connection else self.connection
                        destination.sendall(chunk)
                        last=time.monotonic()
                        with gateway.guard:gateway.websocket_bytes+=len(chunk)
            except OSError:
                pass  # Either endpoint closed; never append HTTP to WS bytes.
            return 101
        finally:
            with gateway.guard:gateway.websocket_connections.discard(pair)
            upstream.close()

    do_GET = do_HEAD = do_POST = do_PATCH = do_PUT = do_DELETE = do_OPTIONS = _handle
