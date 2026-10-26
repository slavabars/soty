#!/usr/bin/env python3
"""Soty relay host probe: WebSocket handshake + HELLO -> WELCOME.

Verifies that a relay endpoint is reachable and that the Ed25519 identity it
answers with is the expected one — the same check the app performs when it
pins a host, so a green run here means a device will accept the invite.

    scripts/host_probe.py ws://85.198.75.50:3100/ws fad55cc7…4e82
    scripts/host_probe.py wss://price.dcns.ru/soty-ws dba88ecc…b014

Exit code 0 only when the identity matches. Works for ws:// and wss:// (the
TLS cert is verified against the system CA, like on a real device).
"""
from __future__ import annotations

import base64
import json
import os
import socket
import ssl
import struct
import sys

HELLO = {"type": "HELLO", "myPeerId": "11" * 32, "capabilities": [], "myAddrs": []}


def recvn(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed mid-frame")
        buf += chunk
    return buf


def client_frame(payload: bytes) -> bytes:
    """Text frame, client-to-server, masked (RFC 6455 requires the mask)."""
    mask = os.urandom(4)
    n = len(payload)
    head = b"\x81" + (bytes([0x80 | n]) if n < 126 else bytes([0xFE]) + struct.pack(">H", n))
    return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def read_frame(sock: socket.socket) -> tuple[int, bytes]:
    b0, b1 = recvn(sock, 2)
    length = b1 & 0x7F
    if length == 126:
        length = struct.unpack(">H", recvn(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recvn(sock, 8))[0]
    mask = recvn(sock, 4) if b1 & 0x80 else b""
    data = recvn(sock, length) if length else b""
    if mask:
        data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    return b0 & 0x0F, data


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 64
    url = sys.argv[1]
    expected = sys.argv[2] if len(sys.argv) > 2 else None

    secure, _, rest = url.partition("://")
    hostport, _, path = rest.partition("/")
    host, _, port = hostport.partition(":")
    port = int(port or 443)
    if secure not in ("ws", "wss"):
        print(f"bad scheme: {url}")
        return 64

    sock = socket.create_connection((host, port), timeout=15)
    if secure == "wss":
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)  # verifies cert + hostname
        ctx.load_default_certs()
        sock = ctx.wrap_socket(sock, server_hostname=host)
        print(f"tls      {sock.version()} {host}:{port} cert-ok")
    sock.settimeout(15)

    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        f"GET /{path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
        f"Connection: upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n".encode()
    )
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(1)
        if not chunk:
            print("handshake: connection closed")
            return 1
        head += chunk
    status = head.split(b"\r\n")[0].decode()
    print(f"upgrade  {status}")
    if "101" not in status:
        return 1

    sock.sendall(client_frame(json.dumps(HELLO).encode()))
    opcode, data = read_frame(sock)
    if opcode != 1:
        print(f"unexpected opcode {opcode}")
        return 1
    msg = json.loads(data)
    identity = msg.get("identity", "")
    print(f"welcome  identity={identity}")
    print(f"         caps={msg.get('capabilities')} "
          f"retention={msg.get('retentionSeconds')}s "
          f"maxFrame={msg.get('maxEnvelopeSize')}")
    sock.close()

    if expected is None:
        return 0
    if identity != expected:
        print(f"MISMATCH: expected {expected}")
        return 1
    print("pin      OK (identity matches the pinned ed25519 key)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
