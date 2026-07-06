#!/usr/bin/env python3
"""mTLS verification for the nats role.

Usage: nats_mtls_check.py <host> <port> <ca> <client_cert> <client_key>

Proves three things against a live nats-server:
  1. the plaintext INFO banner advertises tls_required + tls_verify + jetstream
  2. a client WITHOUT a certificate is rejected (TLS 1.3 surfaces the
     CERTIFICATE_REQUIRED alert on the first I/O after the handshake, so
     handshake success alone proves nothing — only a PONG would)
  3. a client with a cert signed by the CA completes CONNECT/PING -> PONG
"""
import json
import socket
import ssl
import sys

host, port = sys.argv[1], int(sys.argv[2])
ca, crt, key = sys.argv[3], sys.argv[4], sys.argv[5]

PING = b'CONNECT {"verbose":false,"pedantic":false,"tls_required":true,"protocol":1}\r\nPING\r\n'


def tcp():
    return socket.create_connection((host, port), timeout=10)


# 1. Plaintext INFO banner (NATS is not implicit-TLS).
s = tcp()
banner = s.recv(4096).decode()
s.close()
info = json.loads(banner[len("INFO "):banner.index("\r\n")])
assert info["tls_required"], banner
assert info["tls_verify"], banner
assert info["jetstream"], banner

# Certs are CN-based test material; we verify the CHAIN against the CA but
# not the hostname (we connect by address).
ctx = ssl.create_default_context(cafile=ca)
ctx.check_hostname = False

# 2. Certless client must NOT get service. Only a PONG counts as failure —
# an SSL alert, a closed connection or a NATS -ERR are all rejections.
s = tcp()
s.recv(4096)
try:
    ss = ctx.wrap_socket(s)
    ss.sendall(PING)
    data = ss.recv(4096)
    if b"PONG" in data:
        sys.exit("FAIL: certless client got PONG — mTLS is not enforced")
except ssl.SSLError:
    pass
finally:
    s.close()

# 3. CA-signed client cert: full round trip.
ctx.load_cert_chain(crt, key)
s = tcp()
s.recv(4096)
ss = ctx.wrap_socket(s)
ss.sendall(PING)
resp = ss.recv(4096)
assert b"PONG" in resp, resp
print("OK: banner advertises mTLS+JetStream; certless rejected; mTLS PING->PONG")
