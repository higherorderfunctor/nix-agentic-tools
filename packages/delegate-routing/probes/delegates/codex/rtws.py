#!/usr/bin/env python3
"""Minimal Realtime WebSocket mock for codex:P6.realtime (stdlib only, no TLS).

usage: rtws.py <port> <outdir>

Accepts any number of WebSocket upgrades on 127.0.0.1:<port>. Logs the request line and every
client text frame as one JSON line to <outdir>/rt.jsonl ({"path": ...} then {"frame": <json>}).
Answers each `session.update` with `session.updated` (the client waits for it) and ignores the rest.
Point Codex at it with `experimental_realtime_ws_base_url = "http://127.0.0.1:<port>"` and
`[realtime] transport = "websocket"`.
"""
import base64, hashlib, json, os, socket, struct, sys, threading

port, out = int(sys.argv[1]), sys.argv[2]
os.makedirs(out, exist_ok=True)
log_lock = threading.Lock()
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def log(rec):
    with log_lock, open(os.path.join(out, "rt.jsonl"), "a") as f:
        f.write(json.dumps(rec) + "\n")


def recv_exact(conn, buf, n):
    while len(buf) < n:
        chunk = conn.recv(65536)
        if not chunk:
            raise EOFError
        buf += chunk
    return buf[:n], buf[n:]


def send_text(conn, text):
    payload = text.encode()
    n = len(payload)
    if n < 126:
        hdr = bytes([0x81, n])
    elif n < 65536:
        hdr = bytes([0x81, 126]) + struct.pack(">H", n)
    else:
        hdr = bytes([0x81, 127]) + struct.pack(">Q", n)
    conn.sendall(hdr + payload)


def serve(conn):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            return
        buf += chunk
    head, buf = buf.split(b"\r\n\r\n", 1)
    lines = head.decode(errors="replace").split("\r\n")
    headers = {k.strip().lower(): v.strip() for k, _, v in (line.partition(":") for line in lines[1:])}
    log({"path": lines[0].split(" ")[1] if " " in lines[0] else lines[0]})
    accept = base64.b64encode(hashlib.sha1(headers.get("sec-websocket-key", "").encode() + GUID).digest()).decode()
    conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    fragments = b""
    try:
        while True:
            h, buf = recv_exact(conn, buf, 2)
            fin, op, masked, n = h[0] & 0x80, h[0] & 0x0F, h[1] & 0x80, h[1] & 0x7F
            if n == 126:
                ext, buf = recv_exact(conn, buf, 2)
                n = struct.unpack(">H", ext)[0]
            elif n == 127:
                ext, buf = recv_exact(conn, buf, 8)
                n = struct.unpack(">Q", ext)[0]
            mask = b""
            if masked:
                mask, buf = recv_exact(conn, buf, 4)
            data, buf = recv_exact(conn, buf, n)
            if masked:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if op == 0x8:  # close
                conn.sendall(bytes([0x88, 0]))
                return
            if op == 0x9:  # ping -> pong
                conn.sendall(bytes([0x8A, len(data)]) + data)
                continue
            if op in (0x1, 0x0):
                fragments += data
                if not fin:
                    continue
                text, fragments = fragments.decode(errors="replace"), b""
                try:
                    frame = json.loads(text)
                except ValueError:
                    frame = {"raw": text}
                log({"frame": frame})
                if frame.get("type") == "session.update":
                    session = dict(frame.get("session") or {}, id="sess_probe")
                    send_text(conn, json.dumps({"type": "session.updated", "session": session}))
    except (EOFError, ConnectionResetError, BrokenPipeError):
        return
    finally:
        conn.close()


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(8)
while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
