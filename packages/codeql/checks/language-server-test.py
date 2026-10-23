"""Exercise the shipped stdio LSP wrapper without creating a database."""

import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time


def run(command):
    started = time.monotonic()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "qlpack.yml").write_text(json.dumps({
            "dependencies": {"nix-agentic-tools/nix-queries": "*"},
            "name": "fixture/lsp", "version": "0.0.0",
        }))
        query = root / "fixture.ql"
        good = "import codeql.nix.Nix\nfrom AstNode n select n\n"
        bad = good.replace("select n", "select n, missingCodeqlLspFixture()")
        query.write_text(good)
        messages = queue.Queue()
        with (root / "stderr").open("w+") as stderr:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=stderr, cwd=root, start_new_session=True)

            def receive():
                try:
                    while True:
                        headers = {}
                        while (line := process.stdout.readline()) not in (b"\r\n", b"\n", b""):
                            key, value = line.decode().split(":", 1)
                            headers[key.lower()] = value.strip()
                        if not line:
                            raise EOFError("language server closed stdout")
                        message = json.loads(process.stdout.read(int(headers["content-length"])))
                        messages.put(message)
                except Exception as error:
                    messages.put(error)

            threading.Thread(target=receive, daemon=True).start()

            def send(method, params, identifier=None):
                message = {"jsonrpc": "2.0", "method": method, "params": params}
                if identifier is not None:
                    message["id"] = identifier
                body = json.dumps(message).encode()
                process.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
                process.stdin.flush()

            def until(predicate):
                deadline = time.monotonic() + 90
                while True:
                    message = messages.get(timeout=max(0, deadline - time.monotonic()))
                    if isinstance(message, Exception):
                        raise message
                    if predicate(message):
                        return message

            def diagnostics(accept):
                result = until(lambda message:
                    message.get("method") == "textDocument/publishDiagnostics"
                    and message["params"]["uri"] == query.as_uri()
                    and accept(message["params"]["diagnostics"]))
                return result["params"]["diagnostics"]

            try:
                send("initialize", {"processId": os.getpid(), "rootUri": root.as_uri(),
                     "capabilities": {}, "workspaceFolders": [{"uri": root.as_uri(), "name": "fixture"}]}, 1)
                result = until(lambda message: message.get("id") == 1)
                assert "result" in result, result
                send("initialized", {})
                # The MCP bridge sends an empty languageId for .ql files.
                send("textDocument/didOpen", {"textDocument": {
                    "uri": query.as_uri(), "languageId": "", "version": 1, "text": good}})
                initial = diagnostics(lambda errors: not errors)
                assert initial == [], initial
                print(f"initial diagnostics={len(initial)} elapsed={time.monotonic() - started:.3f}s", flush=True)
                query.write_text(bad)
                send("textDocument/didChange", {"textDocument": {"uri": query.as_uri(), "version": 2},
                                               "contentChanges": [{"text": bad}]})
                errors = diagnostics(lambda errors: any("missingCodeqlLspFixture" in error["message"] for error in errors))
                assert len(errors) == 1 and errors[0]["severity"] == 1, errors
                print(f"edited diagnostics={len(errors)} elapsed={time.monotonic() - started:.3f}s", flush=True)
                print(json.dumps(errors, sort_keys=True), flush=True)
                query.write_text(good)
                send("textDocument/didChange", {"textDocument": {"uri": query.as_uri(), "version": 3},
                                               "contentChanges": [{"text": good}]})
                recovered = diagnostics(lambda errors: not errors)
                assert recovered == [], recovered
                # A definition requires real library resolution, not merely the
                # empty diagnostics notification emitted before compilation.
                send("textDocument/definition", {"textDocument": {"uri": query.as_uri()},
                                                 "position": {"line": 1, "character": 7}}, 2)
                definition = until(lambda message: message.get("id") == 2)
                assert definition.get("result"), definition
                print("AstNode definition=" + json.dumps(definition["result"]), flush=True)
                send("shutdown", None, 3)
                until(lambda message: message.get("id") == 3)
                send("exit", None)
                process.stdin.close()
                assert process.wait(timeout=10) == 0
                print(f"recovered diagnostics={len(recovered)} total={time.monotonic() - started:.3f}s", flush=True)
            except Exception:
                stderr.flush()
                print((root / "stderr").read_text(), file=sys.stderr)
                raise
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()


if __name__ == "__main__":
    run(sys.argv[1:])
