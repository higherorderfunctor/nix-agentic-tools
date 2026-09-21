#!/usr/bin/env python3
"""Observe public Scribe behavior in disposable roots; no semantic evaluator."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time


FIXTURE = Path(__file__).resolve().parents[1]


class Workspace:
    def __init__(self, parent, name):
        self.root = parent / name
        self.root.mkdir(mode=0o700)
        (self.root / "documents").mkdir()
        for filename in ("grammar.sgra", "strictdoc_config.py"):
            shutil.copyfile(FIXTURE / filename, self.root / filename)
        shutil.copyfile(FIXTURE / "documents/seed.sdoc", self.root / "documents/seed.sdoc")
        self.socket_path = self.root / "rpc.sock"
        self.log = (self.root / "daemon.log").open("w+")
        self.process = None
        self.serial = 0
        try:
            self.start()
        except BaseException:
            self.stop()
            self.log.close()
            raise

    def start(self):
        env = {key: value for key, value in os.environ.items() if key != "SCRIBE_ROOT"}
        self.process = subprocess.Popen(
            ["scribe-daemon", "--root", str(self.root), "--socket", str(self.socket_path)],
            cwd=self.root,
            env=env,
            stdout=self.log,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.log.seek(0)
                raise RuntimeError(self.log.read())
            try:
                reply = self.rpc("daemon.ping", {})
                assert reply["result"]["root"] == str(self.root), reply
                return
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.1)
        raise RuntimeError("Daemon did not become ready within 30 seconds")

    def stop(self):
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            self.process = None

    def exchange(self, request):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(20)
            connection.connect(str(self.socket_path))
            connection.sendall(json.dumps(request).encode() + b"\n")
            with connection.makefile("rb") as reader:
                return json.loads(reader.readline())

    def request(self, method, params):
        self.serial += 1
        return {"id": self.serial, "jsonrpc": "2.0", "method": method, "params": params}

    def rpc(self, method, params):
        return self.exchange(self.request(method, params))

    def apply(self, **params):
        return self.rpc("scribe.apply", params)

    def new(self, uid, kind="FOO", flag="false", relations=None):
        fields = {"FLAG": flag} if kind == "FOO" else {}
        result = self.apply(
            op="new", type=kind, uid=uid, path=f"documents/{uid}.sdoc",
            fields=fields, relations=relations or [],
        )
        assert "result" in result, result
        return result

    def snapshot(self):
        return {
            str(path.relative_to(self.root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted((self.root / "documents").glob("*.sdoc"))
        }

    def reload(self):
        return self.rpc("workspace.reload", {})


def run():
    report = {
        "kind": "native-observations-not-semantic-approval",
        "observations": {},
        "runtime": {
            "devenv_lock_sha256": hashlib.sha256((FIXTURE / "devenv.lock").read_bytes()).hexdigest(),
            "grammar_sha256": hashlib.sha256((FIXTURE / "grammar.sgra").read_bytes()).hexdigest(),
            "interpreter": sys.executable,
            "profile_bin": str(FIXTURE / ".devenv/profile/bin"),
            "scribe_daemon": str(Path(shutil.which("scribe-daemon")).resolve()),
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        },
    }
    observations = report["observations"]
    with tempfile.TemporaryDirectory(prefix="sdoc-fixture-") as directory:
        parent = Path(directory)
        workspaces = []

        def workspace(name):
            result = Workspace(parent, name)
            workspaces.append(result)
            return result

        try:
            smoke = workspace("smoke")
            observations["discovery"] = smoke.rpc("rpc.discover", {})
            for uid in ("F0", "F1", "F2", "G0", "I0"):
                smoke.new(uid, flag="true" if uid == "F2" else "false")
            for child in ("F1", "F2"):
                reply = smoke.apply(op="relate", uid=child, role="H", target="F0")
                assert "result" in reply, reply
            observations["bar_new"] = smoke.new(
                "M", kind="BAR", relations=[{"role": "P", "target": "F0"}, {"role": "Q", "target": "F2"}],
            )
            bar_text = (smoke.root / "documents/M.sdoc").read_text()
            assert "TYPE: Parent" in bar_text and "TYPE: Child" in bar_text, bar_text
            observations["bar_authored_document"] = bar_text
            before = smoke.snapshot()
            before_node = smoke.apply(op="show", uid="I0")
            observations["dry_run"] = smoke.apply(op="set", uid="I0", fields={"FLAG": "true"}, dry_run=True)
            assert "result" in observations["dry_run"]
            assert smoke.snapshot() == before
            assert smoke.apply(op="show", uid="I0")["result"] == before_node["result"]
            observations["invalid_flag_refusal"] = smoke.apply(op="set", uid="I0", fields={"FLAG": "invalid"})
            assert "error" in observations["invalid_flag_refusal"]
            assert smoke.snapshot() == before
            assert smoke.apply(op="show", uid="I0")["result"] == before_node["result"]
            observations["unknown_target_refusal"] = smoke.apply(op="relate", uid="I0", role="R", target="MISSING")
            assert "error" in observations["unknown_target_refusal"]
            assert smoke.snapshot() == before
            assert smoke.apply(op="show", uid="I0")["result"] == before_node["result"]
            observations["set"] = smoke.apply(op="set", uid="I0", fields={"FLAG": "true"})
            assert "result" in observations["set"]
            assert "FLAG: true" in (smoke.root / "documents/I0.sdoc").read_text()
            observations["unrelate"] = smoke.apply(op="unrelate", uid="F1", role="H", target="F0")
            assert "result" in observations["unrelate"]
            observations["reload"] = smoke.reload()
            assert "result" in observations["reload"]
            observations["check"] = smoke.apply(op="check")
            assert "0 finding(s)" in observations["check"]["result"]["text"]
            held = {uid: smoke.apply(op="show", uid=uid)["result"] for uid in ("I0", "F1", "M")}
            assert "FLAG: true" in held["I0"]["text"]
            assert "ROLE: H" not in held["F1"]["text"]
            assert "TYPE: Parent" in held["M"]["text"] and "TYPE: Child" in held["M"]["text"]
            persisted = smoke.snapshot()
            smoke.stop()
            smoke.start()
            observations["cold_restart"] = smoke.rpc("workspace.describe", {})
            assert "result" in observations["cold_restart"]
            assert smoke.snapshot() == persisted
            restarted = {uid: smoke.apply(op="show", uid=uid)["result"] for uid in ("I0", "F1", "M")}
            assert restarted == held
            observations["cold_restart_nodes"] = restarted

            cycle = workspace("mixed-cycle")
            cycle.new("A")
            cycle.new("B")
            cycle.new("Z0", kind="BAZ", relations=[{"role": "R", "target": "A"}])
            reply = cycle.apply(op="relate", uid="A", role="H", target="B")
            assert "result" in reply, reply
            before = cycle.snapshot()
            observations["mixed_cycle"] = cycle.apply(op="relate", uid="Z0", role="Q", target="B")
            observations["mixed_cycle_changed_files"] = cycle.snapshot() != before
            observations["mixed_cycle_check"] = cycle.apply(op="check")
            observations["mixed_cycle_reload"] = cycle.reload()

            batch = workspace("rpc-array")
            batch.new("I0")
            batch.new("I1")
            requests = [
                batch.request("scribe.apply", {"op": "set", "uid": "I0", "fields": {"FLAG": "true"}}),
                batch.request("scribe.apply", {"op": "set", "uid": "I1", "fields": {"FLAG": "invalid"}}),
            ]
            observations["rpc_array"] = batch.exchange(requests)
            observations["rpc_array_first_write_persisted"] = "FLAG: true" in (batch.root / "documents/I0.sdoc").read_text()
            observations["rpc_array_reload"] = batch.reload()
            # cspell:ignore postreload
            observations["rpc_array_postreload_nodes"] = {
                uid: batch.apply(op="show", uid=uid) for uid in ("I0", "I1")
            }

            missing = workspace("missing-semantics")
            missing.new("F0")
            missing.new("F1", relations=[{"role": "H", "target": "F0"}])
            missing.new("F2", flag="true", relations=[{"role": "H", "target": "F0"}])
            missing.new("F2a", relations=[{"role": "H", "target": "F2"}])
            missing.new("Z0", kind="BAZ")
            observations["unimplemented_target_type"] = missing.apply(op="relate", uid="F1", role="R", target="Z0")
            observations["unimplemented_boundary"] = missing.apply(
                op="new", type="BAR", uid="M", path="documents/M.sdoc", fields={}, relations=[{"role": "P", "target": "F0"}, {"role": "Q", "target": "F2a"}],
            )
            observations["unimplemented_bar_cardinality"] = missing.apply(op="new", type="BAR", uid="INCOMPLETE", path="documents/INCOMPLETE.sdoc", fields={}, relations=[])
            observations["unimplemented_semantics_note"] = (
                "Recorded native outcomes only. Target types, closed-boundary traversal, and final BAR cardinality "
                "remain proposed/unimplemented; accepting these candidates is a gap, not a semantic pass."
            )
        finally:
            for item in reversed(workspaces):
                item.stop()
                item.log.close()
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = run()
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(rendered)
    else:
        print(rendered, end="")
