"""Offline, literal routing expectations: no catalogs, live readers or launches."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location("routing_plan", SOURCE)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
NOW = helper.utc("2026-11-15T00:00:00Z")
SHELL = shutil.which("bash")
QUALIFIED = {"avoidFor": "checked: task avoids exclusions", "fit": "approved for this task", "trial": "not a trial", "useFor": "task matches guidance"}


def window(remaining=50, seconds=2592000, reset="2026-12-01T00:00:00Z"):
    return {"remainingPercent": remaining, "resetsAt": reset, "status": "ok", "usedPercent": 100 - remaining, "windowSeconds": seconds}


def stream(windows=None):
    return json.dumps({"account": {"auth_index": None, "name": "fake", "plan": None}, "balances": [], "bonuses": [], "pool": "deliberately-not-the-registration", "windows": windows or {"monthly": window()}})


def technique(name="spawn_agent", kind="subagent", model="gpt-6.1-sol", pattern=False, agent=None):
    return {"agent": agent, "model": {"isPattern": pattern, "value": model}, "name": name, "node": {"command": "MUST NEVER EXECUTE THIS LAUNCH", "kind": kind, "modelArg": "slug", "notes": "caller binds task/output paths"}}


def route(name="sol", tier="strong", pool="outside", target="codex", techniques=None):
    return {"family": {"avoidFor": "sole judge", "effort": "prose is not an effort enum", "name": name, "tier": tier, "useFor": "writer-judge loop", "vendor": "provider"}, "pool": pool, "target": target, "techniques": techniques or [technique()]}


def manifest(routes=None, session=None):
    return {"manualRoutes": [route("manual", pool=None)], "readers": [{"command": "reader-outside", "name": "outside"}, {"command": "reader-session", "name": "session"}, {"command": "reader-hidden-runtime", "name": "hidden"}], "routes": routes or [route()], "runtime": "codex", "runtimes": ["codex"], "sessionPool": session}


def context(roles=("writer",), names=("sol",), techniques=None, non_interactive=False, effort="high"):
    return {"nonInteractive": non_interactive, "roles": {role: {"effort": effort, "families": {name: QUALIFIED for name in names}} for role in roles}, "techniques": techniques or [{"efforts": ["high"], "model": "gpt-6.1-sol", "runtime": "codex", "technique": "spawn_agent"}]}


class Routing(unittest.TestCase):
    def run_plan(self, config=None, launch_context=None, roles=("writer",), outputs=None):
        calls = []
        def reader(argv, **kwargs):
            self.assertEqual(argv[:4], [SHELL, "-euETo", "pipefail", "-c"])
            self.assertEqual(kwargs["timeout"], 10)
            command = argv[4].split("\n", 1)[1]
            calls.append(command)
            value = (outputs or {}).get(command, stream())
            if isinstance(value, Exception):
                raise value
            if isinstance(value, subprocess.CompletedProcess):
                return value
            return subprocess.CompletedProcess(argv, 0, value)
        with patch.object(helper.subprocess, "Popen", side_effect=AssertionError("delegate/probe launched")):
            result = helper.plan(config or manifest(), launch_context or context(roles), roles, NOW, SHELL, reader)
        return result, calls

    def test_inventory_one_snapshot_and_only_registered_commands(self):
        # Wrong: per-role reads, current-runtime filtering, trusting reader .pool.
        config = manifest()
        config["readers"].append({"command": "reader-outside", "name": "alias"})
        result, calls = self.run_plan(config, context(("writer", "judge")), ("writer", "judge"))
        self.assertEqual(calls, ["reader-outside", "reader-session", "reader-hidden-runtime"])
        self.assertEqual(sorted(result["pools"]), ["alias", "hidden", "outside", "session"])
        self.assertEqual(result["automaticRuntimes"], ["codex"])
        self.assertEqual(result["snapshot"], "2026-11-15T00:00:00+00:00")
        self.assertEqual(result["roles"]["judge"]["candidates"][0]["line"], "role=judge runtime=codex family=sol technique=spawn_agent model=gpt-6.1-sol effort=high")
        self.assertEqual(result["manualOnly"][0]["family"]["name"], "manual")

    def test_worst_window_month_duration(self):
        self.assertEqual(helper.measure(stream(), NOW), {"buffer": 0.5, "pace": 0.9375, "status": "measured"})
        self.assertEqual(helper.measure(stream({"monthly": window(), "5h": window(10, 18000, "2026-11-15T02:30:00Z")}), NOW), {"buffer": 0.1, "pace": 0.2, "status": "measured"})
        self.assertEqual(helper.measure(stream({"monthly": window(50, 2678400)}), NOW)["pace"], 0.96875)

    def test_comparative_session_and_strict_limiting_buffer(self):
        config = manifest([route("own", pool="session"), route("other")], "session")
        for own, other, expected in [(60, 45, "own"), (60, 60, "own"), (45, 60, "other"), (20, 10, "other"), (20.01, 10, "own")]:
            with self.subTest(own=own, other=other):
                result, _ = self.run_plan(config, context(names=("own", "other")), outputs={"reader-outside": stream({"5h": window(other, 18000, "2026-11-15T02:30:00Z")}), "reader-session": stream({"5h": window(own, 18000, "2026-11-15T02:30:00Z")})})
                self.assertEqual(result["roles"]["writer"]["candidates"][0]["launch"]["family"], expected)
        # Own pace leads despite the tighter buffer: max-share buffering fails.
        for remaining, expected in [(20, "other"), (20.01, "own")]:
            result, _ = self.run_plan(config, context(names=("own", "other")), outputs={"reader-session": stream({"monthly": window(60), "5h": window(remaining, 18000, "2026-11-15T00:30:00Z")})})
            self.assertEqual(result["roles"]["writer"]["candidates"][0]["launch"]["family"], expected)

    def test_unmeasured_streams_and_exhaustion(self):
        # Wrong: first-document-only parse, fabricated weekly resets, silent scopes.
        cases = [(stream() + "garbage", "Expecting value"), (stream() + "\n" + stream(), "account-to-route"), (stream({"5h": window(reset=None)}), "null reset"), (stream({"5h": window(reset="2026-11-14T00:00:00Z")}), "expired reset"), (stream({"5h:model": window()}), "model-scoped"), (stream({"5h": {"remainingPercent": 50}}), "windowSeconds"), (subprocess.TimeoutExpired("fake", 10), "timed out"), (subprocess.CompletedProcess("fake", 7, ""), "Reader exited 7"), (stream({"bad": []}), "window must be an object"), ("[]", "missing account"), (stream({"bad": window(float("nan"))}), "invalid remainingPercent"), (stream({"bad": window(reset="2027-01-01T00:00:00Z")}), "beyond window duration")]
        for value, reason in cases:
            with self.subTest(reason=reason):
                result, _ = self.run_plan(outputs={"reader-outside": value})
                self.assertEqual(result["pools"]["outside"]["status"], "unmeasured")
                self.assertIn(reason, result["pools"]["outside"]["reason"])
        result, _ = self.run_plan(outputs={"reader-outside": stream({"monthly": window(0)})})
        self.assertEqual(result["pools"]["outside"]["pace"], 0)
        self.assertEqual(result["roles"]["writer"]["candidates"], [])
        self.assertEqual(result["roles"]["writer"]["exclusions"][-1]["reason"], "pool exhausted")
        self.assertIn("buffer rule cannot be certified", result["warnings"][1])

    def test_schema_required_fields(self):
        # Wrong: accepting incomplete account/envelope records or non-string/null status.
        cases = [
            ("account", {}, "account requires auth_index, name and plan"),
            ("account", {"name": "fake", "plan": None}, "account requires auth_index, name and plan"),
            ("account", {"auth_index": None, "plan": None}, "account requires auth_index, name and plan"),
            ("account", {"auth_index": None, "name": "fake"}, "account requires auth_index, name and plan"),
            ("balances", None, "balances must be an array"),
            ("balances", {}, "balances must be an array"),
            ("bonuses", None, "bonuses must be an array"),
            ("bonuses", {}, "bonuses must be an array"),
            ("pool", None, "pool must be a nonempty string"),
            ("pool", {}, "pool must be a nonempty string"),
            ("status", {}, "window status must be a string or null"),
        ]
        for field, value, reason in cases:
            with self.subTest(field=field, value=value):
                document = json.loads(stream())
                record = document["windows"]["monthly"] if field == "status" else document
                if value is None:
                    del record[field]
                else:
                    record[field] = value
                result, _ = self.run_plan(outputs={"reader-outside": json.dumps(document)})
                self.assertEqual(result["pools"]["outside"]["status"], "unmeasured")
                self.assertIn(reason, result["pools"]["outside"]["reason"])

    def test_production_null_status_and_nullable_metadata(self):
        # Codex usage-cpa.sh emits null status, including for started windows.
        document = {"account": {"auth_index": "idx-one", "name": "personal-codex", "plan": "plus"}, "balances": [], "bonuses": [], "pool": "codex", "windows": {"5h": {"remainingPercent": 87.5, "resetsAt": "2026-11-15T02:30:00Z", "status": None, "usedPercent": 12.5, "windowSeconds": 18000}}}
        self.assertEqual(helper.measure(json.dumps(document), NOW), {"buffer": 0.875, "pace": 1.75, "status": "measured"})
        # The shared schema permits null account fields and any string status.
        document["account"] = {"auth_index": None, "name": None, "plan": None}
        document["windows"]["5h"]["status"] = ""
        self.assertEqual(helper.measure(json.dumps(document), NOW)["status"], "measured")

    def test_schema_account_types_and_utc_resets(self):
        # Wrong: presence-only account validation or normalizing non-UTC resets.
        cases = [
            ("account", "auth_index", 7, "account auth_index must be a string or null"),
            ("account", "name", [], "account name must be a string or null"),
            ("account", "plan", False, "account plan must be a string or null"),
            ("window", "resetsAt", "2026-11-15T03:30:00+01:00", "time must be UTC"),
            ("window", "resetsAt", "2026-11-14T21:30:00-05:00", "time must be UTC"),
        ]
        for section, field, value, reason in cases:
            with self.subTest(section=section, field=field, value=value):
                document = json.loads(stream())
                record = document["account"] if section == "account" else document["windows"]["monthly"]
                record[field] = value
                result, _ = self.run_plan(outputs={"reader-outside": json.dumps(document)})
                self.assertEqual(result["pools"]["outside"]["status"], "unmeasured")
                self.assertIn(reason, result["pools"]["outside"]["reason"])
        self.assertEqual(helper.measure(stream({"5h": window(reset="2026-11-15T02:30:00+00:00")}), NOW)["status"], "measured")

    def test_fit_only_and_measured_exclusion(self):
        config = manifest([route("unknown", pool=None), route()])
        result, _ = self.run_plan(config, context(names=("sol", "unknown")))
        self.assertEqual([c["launch"]["family"] for c in result["roles"]["writer"]["candidates"]], ["sol"])
        config["readers"] = []
        config["routes"] = [route(pool=None)]
        result, _ = self.run_plan(config)
        self.assertEqual(result["roles"]["writer"]["candidates"][0]["budget"], "fit-only; budget and session buffer unknown")

    def test_all_review_floors_and_unknown_role(self):
        roles = ("finder", "first-check", "second-check", "judge")
        for tier in ("small", "mid", "strong", "frontier"):
            family = "glm-flash" if tier in ("small", "mid") else "astra"
            candidate = route(family, tier)
            if tier in ("strong", "frontier"):
                candidate["family"]["useFor"] = "deep synthesis"
            result, _ = self.run_plan(manifest([candidate]), context(roles, (family,)), roles)
            for role in roles:
                self.assertEqual(bool(result["roles"][role]["candidates"]), tier in ("strong", "frontier"))
                if tier in ("small", "mid"):
                    self.assertEqual(result["roles"][role]["error"], "never step down a tier; report a loop failure.")
        with self.assertRaisesRegex(ValueError, "unknown role"):
            self.run_plan(roles=("planner",))
        result, _ = self.run_plan(launch_context=context(names=()))
        self.assertEqual(result["roles"]["writer"]["candidates"], [])

    def test_generated_agent_workflow_external_and_unresolved(self):
        agent = {"family": {"defaultEffort": "high", "name": "sol"}, "id": "gpt-6.1-sol"}
        techniques = [technique("Agent with generated agent file", agent=agent), technique("Workflow", "workflow"), technique("claude -p", "external")]
        evidence = [{"efforts": ["high"], "model": "gpt-6.1-sol", "runtime": "claude", "technique": name} for name in ("Agent with generated agent file", "Workflow", "claude -p")]
        config = manifest([route(target="claude", techniques=techniques)])
        result, _ = self.run_plan(config, context(techniques=evidence, effort=None))
        candidate = result["roles"]["writer"]["candidates"][0]
        self.assertEqual(candidate["line"], "role=writer runtime=claude family=sol technique=Agent with generated agent file model=gpt-6.1-sol effort=high")
        self.assertEqual(candidate["launch"]["agent"]["id"], "gpt-6.1-sol")
        for name, headless in [("Workflow", False), ("claude -p", False), ("claude -p", True), ("claude -p", None)]:
            result, _ = self.run_plan(config, context(techniques=[e for e in evidence if e["technique"] == name], non_interactive=headless))
            candidates = result["roles"]["writer"]["candidates"]
            self.assertEqual(bool(candidates), headless is False)
            if candidates:
                self.assertEqual(candidates[0]["line"], f"role=writer runtime=claude family=sol technique={name} model=gpt-6.1-sol effort=high")
        for field, value in [("model", "invented"), ("efforts", ["low"]), ("technique", "absent")]:
            ctx = context()
            ctx["techniques"][0][field] = value
            result, _ = self.run_plan(launch_context=ctx)
            self.assertEqual(result["roles"]["writer"]["candidates"], [])
        config = manifest([route(techniques=[technique(model="gpt-*-sol", pattern=True)])])
        result, _ = self.run_plan(config, context(effort=None))
        self.assertEqual(result["roles"]["writer"]["candidates"], [])
        result, _ = self.run_plan(config, context())
        self.assertEqual(result["roles"]["writer"]["candidates"][0]["launch"]["model"], "gpt-6.1-sol")

    def test_validation_before_readers_and_real_timeout(self):
        config = manifest(session="undeclared")
        with self.assertRaisesRegex(ValueError, "unknown session pool"):
            self.run_plan(config)
        config = manifest([route(pool="undeclared")])
        with self.assertRaisesRegex(ValueError, "unknown route pool"):
            self.run_plan(config)
        ctx = context()
        ctx["techniques"][0]["efforts"] = "high"
        with self.assertRaisesRegex(ValueError, "efforts list"):
            self.run_plan(launch_context=ctx)
        with patch.object(helper, "READER_TIMEOUT", 0.02):
            measured = helper.collect([{"command": "while :; do :; done", "name": "stuck"}], NOW, SHELL)
        self.assertEqual(measured["stuck"]["status"], "unmeasured")
        self.assertIn("timed out", measured["stuck"]["reason"])

    def test_real_cli_only_fake_reader_and_nonzero_loop(self):
        # Exact CLI path exercises shell collection; launch command is a sentinel.
        with tempfile.TemporaryDirectory(prefix="routing-plan-check-") as directory:
            root = Path(directory)
            config = manifest()
            log = root / "reads"
            config["readers"] = [
                {"name": name, "command": f"printf '{name}\\n' >> '{log}'; printf '%s' '{stream()}'"}
                for name in ("outside", "session", "hidden")
            ]
            config["readers"].append({"name": "alias", "command": config["readers"][0]["command"]})
            (root / "manifest.json").write_text(json.dumps(config))
            (root / "context.json").write_text(json.dumps(context()))
            command = [sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--reader-shell", SHELL, "--launch-context", str(root / "context.json"), "--now", "2026-11-15T00:00:00Z", "--role", "writer"]
            proc = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(log.read_text(), "outside\nsession\nhidden\n")
            self.assertEqual(json.loads(proc.stdout)["pools"]["outside"]["pace"], 0.9375)
            self.assertIn("technique=spawn_agent", proc.stderr)
            (root / "context.json").write_text(json.dumps(context(names=())))
            proc = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 1)
            self.assertIn("never step down a tier; report a loop failure.", proc.stderr)


if __name__ == "__main__":
    unittest.main()
