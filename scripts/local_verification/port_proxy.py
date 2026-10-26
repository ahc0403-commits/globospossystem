"""Loopback TCP bridge to an owned fixture IP inside the local Docker engine.

No listener is published externally. Docker Desktop's host-loopback forwarding
is not assumed reachable from a tool container. Only bytes are relayed; neither
credentials nor SQL/HTTP payloads are logged.
"""
import os
import selectors
import socket
import sys
import threading


def relay(client, host, port):
    try:
        target = socket.create_connection((host, port), timeout=10)
    except OSError:
        client.close()
        return
    with client, target, selectors.DefaultSelector() as selector:
        client.setblocking(False)
        target.setblocking(False)
        selector.register(client, selectors.EVENT_READ, target)
        selector.register(target, selectors.EVENT_READ, client)
        while selector.get_map():
            for key, _ in selector.select(timeout=60):
                try:
                    data = key.fileobj.recv(65536)
                    if not data:
                        return
                    # Fixtures use bounded local requests. Block only while this
                    # connection's peer drains its buffer; no global request loop.
                    peer = key.data
                    peer.setblocking(True)
                    peer.sendall(data)
                    peer.setblocking(False)
                except OSError:
                    return


def serve(fd, host, port):
    with socket.socket(fileno=fd) as listener:
        while True:
            client, _ = listener.accept()
            threading.Thread(target=relay, args=(client, host, port), daemon=True).start()


if __name__ == '__main__':
    serve(int(sys.argv[1]), sys.argv[2], int(sys.argv[3]))
