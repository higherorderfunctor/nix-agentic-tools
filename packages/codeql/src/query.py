"""Local query transport; CodeQL owns compilation, evaluation and JSON decoding."""

import argparse
import contextlib
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time


def command(argv):
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout


def runtime_directory():
    root = os.environ.get("XDG_RUNTIME_DIR")
    return Path(root) / "ai-service-codeql-query" if root else Path(tempfile.gettempdir()) / f"ai-service-{os.getuid()}-codeql-query"


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or path.stat().st_uid != os.getuid() or not path.is_dir():
        raise RuntimeError(f"expected an owned directory, not a symlink: {path}")
    path.chmod(0o700)
    return path


def publish(path, content):
    # The stable path must never expose an empty or partially written pack file.
    with tempfile.TemporaryDirectory(prefix=".publish-", dir=path.parent) as temporary:
        staged = Path(temporary) / path.name
        staged.write_text(content)
        staged.replace(path)


def database_path(value):
    path = Path(value).absolute()
    if path.is_dir():
        return path / "db" if (path / "db").is_dir() else path
    for checkout in (Path.cwd(), *Path.cwd().parents):
        candidate = checkout / ".devenv/state/codeql" / value / "db"
        if candidate.is_dir():
            return candidate
    raise RuntimeError(f"database {value!r} is absent; create it before querying")


def resolve_database(path):
    # Keep the lexical path: resolving it once at daemon startup pins generations.
    logical = Path(path)
    db = logical.resolve(strict=True)
    # Pin the engine to the resolved generation across a live-link swap.
    # Legacy publications of plain directories can keep it beside the db alias.
    candidates = [db.parent / "engine", logical.parent / "engine"]
    for candidate in candidates:
        engine = candidate / "bin/codeql"
        if engine.is_file() and os.access(engine, os.X_OK):
            # Preserve the wrapper's location even when bin/codeql is a symlink.
            return db, str(candidate.resolve() / "bin/codeql")
    raise RuntimeError(f"no executable engine/bin/codeql beside {logical} or {db}")


def decode(engine, result, sort_key):
    return json.loads(command([engine, "bqrs", "decode", "--format=json", f"--sort-key={sort_key}", str(result)]))


class QueryServer:
    """One synchronous RPC stream per DB; distinct DBs never share a JVM."""

    def __init__(self, db, engine, cache, threads, ram):
        self.db = str(db)
        self.log = tempfile.TemporaryFile()
        ram_args = json.loads(command([engine, "resolve", "ram", f"--ram={ram}", "--format=json"]))
        self.process = subprocess.Popen(
            [engine, "execute", "query-server2", f"--threads={threads}", f"--common-caches={cache}", *ram_args],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, start_new_session=True,
        )
        self.sequence = 0
        try:
            registered = self.request("evaluation/registerDatabases", {"databases": [self.db]})
            if self.db not in registered["registeredDatabases"]:
                raise RuntimeError(f"query-server2 did not register {self.db}")
        except BaseException:
            self.close()
            raise

    def request(self, method, body):
        self.sequence += 1
        data = json.dumps({"jsonrpc": "2.0", "id": self.sequence, "method": method,
                           "params": {"body": body, "progressId": self.sequence}}).encode()
        self.process.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
        self.process.stdin.flush()
        while True:
            headers = {}
            while True:
                line = self.process.stdout.readline()
                if not line:
                    self.log.seek(0)
                    raise RuntimeError("query-server2 exited: " + self.log.read().decode(errors="replace"))
                if line in (b"\r\n", b"\n"):
                    break
                name, value = line.decode().split(":", 1)
                headers[name.lower()] = value.strip()
            message = json.loads(self.process.stdout.read(int(headers["content-length"])))
            if message.get("id") == self.sequence:
                if "error" in message:
                    raise RuntimeError(message["error"].get("message", str(message["error"])))
                return message["result"]

    def run(self, query, output):
        offset = os.fstat(self.log.fileno()).st_size
        result = self.request("evaluation/runQuery", {
            "additionalPacks": [str(query.parent)], "db": self.db,
            "externalInputs": {}, "outputPath": str(output), "queryPath": str(query),
            "singletonExternalInputs": {}, "target": {"query": {}},
        })
        if result["resultType"] != 0:
            self.log.seek(offset)
            details = self.log.read().decode(errors="replace").strip()
            message = result.get("message") or f"query failed: {result['resultType']}"
            raise RuntimeError("\n".join(filter(None, [message, details])))

    def close(self):
        if self.process.poll() is None:
            # Killing the session also reaches a launcher child JVM on shutdown.
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait()
        self.process.stdin.close()
        self.process.stdout.close()
        self.log.close()


class Session:
    def __init__(self):
        self.lock = threading.Lock()
        self.server = None
        self.identity = None
        self.used = time.monotonic()

    def close(self):
        if self.server:
            try:
                if self.server.process.poll() is None:
                    self.server.request("evaluation/deregisterDatabases", {"databases": [self.server.db]})
            finally:
                self.server.close()
                self.server = None
                self.identity = None


class Daemon:
    def __init__(self, state, threads, ram, idle):
        self.cache = private_directory(state / "common-caches")
        self.threads, self.ram, self.idle = threads, ram, idle
        self.bindings = {}
        self.sessions = {}
        self.lock = threading.Lock()

    def query(self, request):
        logical = request["database"]
        db, engine = resolve_database(logical)
        identity = (db, engine)
        with self.lock:
            previous = self.bindings.get(logical)
            self.bindings[logical] = identity
            session = self.sessions.setdefault(db, Session())
            obsolete = self.sessions.get(previous[0]) if previous and previous[0] != db else None
        if obsolete:
            with obsolete.lock:
                with self.lock:
                    unused = all(bound[0] != previous[0] for bound in self.bindings.values())
                if unused:
                    obsolete.close()
        with session.lock:
            if session.server and (session.identity != identity or session.server.process.poll() is not None):
                session.close()
            try:
                if session.server is None:
                    session.server = QueryServer(db, engine, self.cache, self.threads, self.ram)
                    session.identity = identity
                with tempfile.TemporaryDirectory(prefix="query-", dir=self.cache.parent) as temporary:
                    output = Path(temporary) / "result.bqrs"
                    session.server.run(Path(request["query"]), output)
                    return decode(engine, output, request["sort_key"])
            finally:
                session.used = time.monotonic()

    def reap(self):
        with self.lock:
            sessions = list(self.sessions.items())
            bindings = list(self.bindings.items())
        for logical, identity in bindings:
            try:
                current = resolve_database(logical)
            except (OSError, RuntimeError):
                current = None
            if current != identity:
                with self.lock:
                    if self.bindings.get(logical) == identity:
                        del self.bindings[logical]
        for db, session in sessions:
            if not session.lock.acquire(blocking=False):
                continue
            try:
                with self.lock:
                    unused = all(bound[0] != db for bound in self.bindings.values())
                if unused or time.monotonic() - session.used > self.idle:
                    session.close()
            except (OSError, RuntimeError) as error:
                print(f"codeql-query: {error}", file=sys.stderr)
            finally:
                session.lock.release()

    def close(self):
        for session in self.sessions.values():
            session.close()


class UnixServer(socketserver.ThreadingUnixStreamServer):
    # Server close joins requests before the JVMs and their output dirs go away.
    daemon_threads = False

    def __init__(self, *args):
        self.clients = set()
        self.clients_lock = threading.Lock()
        super().__init__(*args)

    def get_request(self):
        client, address = super().get_request()
        with self.clients_lock:
            self.clients.add(client)
        return client, address

    def close_request(self, client):
        with self.clients_lock:
            self.clients.discard(client)
        super().close_request(client)

    def server_close(self):
        # Unblock incomplete reads; complete requests still finish and send results.
        with self.clients_lock:
            for client in self.clients:
                with contextlib.suppress(OSError):
                    client.shutdown(socket.SHUT_RD)
        super().server_close()

    def service_actions(self):
        self.daemon.reap()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            request = json.loads(self.rfile.readline())
            response = {"result": self.server.daemon.query(request)}
        except (OSError, RuntimeError, ValueError, KeyError) as error:
            response = {"error": str(error)}
        try:
            self.wfile.write(json.dumps(response).encode() + b"\n")
        except BrokenPipeError:
            pass


def serve(args):
    sock = Path(args.socket)
    private_directory(sock.parent)
    state = private_directory(Path(args.state_dir).absolute())
    # An advisory lock makes stale-socket cleanup safe against another daemon.
    with (sock.parent / "daemon.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError(f"another daemon owns {sock}") from None
        if sock.exists():
            sock.unlink()
        daemon = Daemon(state, args.threads, args.ram, args.idle_seconds)
        with UnixServer(str(sock), Handler) as server:
            sock.chmod(0o600)
            server.daemon = daemon
            def stop(_signum, _frame):
                threading.Thread(target=server.shutdown, daemon=True).start()
            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGINT, stop)
            try:
                server.serve_forever(poll_interval=1)
            finally:
                # server_close joins active requests before close() releases DBs.
                server.server_close()
                daemon.close()
                sock.unlink(missing_ok=True)


def run(args):
    logical = database_path(args.database)
    db, engine = resolve_database(logical)
    cache_root = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "codeql-query"
    private_directory(cache_root)
    with contextlib.ExitStack() as stack:
        if args.expression is not None:
            digest = hashlib.sha256((engine + "\0" + str(logical) + "\0" + args.expression).encode()).hexdigest()
            # Stable query names let the compiler reuse plans across invocations.
            directory = private_directory(cache_root / "expressions" / digest)
            query = directory / "Query.ql"
            manifest = directory / "qlpack.yml"
            if not manifest.exists():
                languages = json.loads(command([engine, "resolve", "database", "--format=json", str(db)]))["languages"]
                packs = json.loads(command([engine, "resolve", "qlpacks", "--format=json"]))
                libraries = sorted(name for name in packs if any(name.endswith(f"/{language}-all") for language in languages))
                if len(libraries) != len(languages):
                    raise RuntimeError("cannot identify one *-all library per database language; use a query file in a QL pack")
                publish(manifest, json.dumps({"name": "local/inline-query", "version": "0.0.0", "dependencies": {name: "*" for name in libraries}}))
            if not query.exists():
                publish(query, args.expression)
        else:
            query = Path(args.query).resolve(strict=True)
        request = {"database": str(logical), "query": str(query), "sort_key": args.sort_key}
        response = None
        if not args.no_daemon:
            client = stack.enter_context(socket.socket(socket.AF_UNIX))
            try:
                client.connect(args.socket)
            except OSError as error:
                if error.errno not in (errno.ENOENT, errno.ECONNREFUSED):
                    raise
            else:
                client.sendall(json.dumps(request).encode() + b"\n")
                stream = stack.enter_context(client.makefile("rb"))
                payload = stream.readline()
                if not payload:
                    raise RuntimeError("daemon disconnected; retry the query")
                response = json.loads(payload)
                if "error" in response:
                    raise RuntimeError(response["error"])
        if response is None:
            temporary = stack.enter_context(tempfile.TemporaryDirectory(prefix="query-", dir=cache_root))
            output = Path(temporary) / "result.bqrs"
            command([engine, "query", "run", str(query), f"--database={db}", f"--output={output}",
                     f"--common-caches={cache_root / 'common-caches'}", f"--threads={args.threads}", f"--ram={args.ram}"])
            response = {"result": decode(engine, output, args.sort_key)}
        print(json.dumps(response["result"], separators=(",", ":")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=str(runtime_directory() / "query.sock"))
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--ram", type=int, default=6000)
    subparsers = parser.add_subparsers(dest="action", required=True)
    daemon = subparsers.add_parser("serve", help="serve queries on a local Unix socket")
    daemon.add_argument("--state-dir", required=True)
    daemon.add_argument("--idle-seconds", type=float, default=300)
    query = subparsers.add_parser("run", help="query a database name or path; print sorted BQRS JSON")
    query.add_argument("--no-daemon", action="store_true")
    query.add_argument("--sort-key", default="0", help="zero-based BQRS column indexes, comma separated")
    query.add_argument("database")
    source = query.add_mutually_exclusive_group(required=True)
    source.add_argument("query", nargs="?")
    source.add_argument("-e", "--expression")
    args = parser.parse_args()
    try:
        serve(args) if args.action == "serve" else run(args)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"codeql-query: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
