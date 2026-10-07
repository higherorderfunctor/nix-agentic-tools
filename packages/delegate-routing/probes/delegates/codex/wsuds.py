#!/usr/bin/env python3
"""stdio <-> WebSocket-over-unix-socket bridge for the shared app-server daemon.

usage: wsuds.py <socket path>

The daemon's control socket (<CODEX_HOME>/app-server-control/app-server-control.sock) accepts a
WebSocket upgrade, not raw JSON lines, so `codex app-server proxy` alone is not a JSON-RPC client.
This bridge does the client handshake, sends every stdin line as one masked text frame and prints
every received text frame as one line. EOF on stdin or SIGTERM closes the connection: a client
disconnect, while the daemon keeps running.
"""
import base64, os, socket, struct, sys, threading

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
os.chdir(os.path.dirname(os.path.abspath(sys.argv[1])))  # AF_UNIX paths cap at 107 bytes: connect relative
s.connect(os.path.basename(sys.argv[1]))
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf:
    chunk = s.recv(4096)
    if not chunk: sys.exit("wsuds: socket closed during handshake")
    buf += chunk
head, buf = buf.split(b"\r\n\r\n", 1)
if b" 101 " not in head.split(b"\r\n")[0]: sys.exit("wsuds: handshake refused: " + head.decode(errors="replace"))
lock = threading.Lock()

def send(op, payload):
    mask = os.urandom(4)
    n = len(payload)
    hdr = bytes([0x80 | op]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n))
    with lock: s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

def read(n):
    global buf
    while len(buf) < n:
        chunk = s.recv(65536)
        if not chunk: raise EOFError
        buf += chunk
    out, buf = buf[:n], buf[n:]
    return out

def reader():
    msg = b""
    try:
        while True:
            b0, b1 = read(2)
            n = b1 & 0x7F
            if n == 126: n = struct.unpack(">H", read(2))[0]
            elif n == 127: n = struct.unpack(">Q", read(8))[0]
            mask = read(4) if b1 & 0x80 else None
            data = read(n)
            if mask: data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            op = b0 & 0x0F
            if op == 9: send(10, data)  # ping -> pong
            elif op == 8: break
            elif op in (0, 1, 2):
                msg += data
                if b0 & 0x80:
                    sys.stdout.write(msg.decode() + "\n"); sys.stdout.flush(); msg = b""
    except EOFError:
        pass
    os._exit(0)

threading.Thread(target=reader, daemon=True).start()
for line in sys.stdin:
    if line.strip(): send(1, line.strip().encode())
send(8, b"")
