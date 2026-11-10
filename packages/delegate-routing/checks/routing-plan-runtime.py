"""Offline, literal routing expectations: no catalogs, live readers or launches."""
# cspell:ignore hihg pidfile rescanned sool
from copy import deepcopy
import gzip
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shlex
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import call, patch

SOURCE = Path(sys.argv.pop(1)).resolve()
FIXTURE = Path(sys.argv.pop(1)).resolve()
CODEX_CACHE = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location("routing_plan", SOURCE)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
NOW = helper.utc("2026-11-15T00:00:00Z")
SHELL = shutil.which("bash")


def window(remaining=50, seconds=2592000, reset="2026-12-01T00:00:00Z"):
    return {"remainingPercent": remaining, "resetsAt": reset, "status": "ok", "usedPercent": 100 - remaining, "windowSeconds": seconds}


def stream(windows=None):
    return json.dumps({"account": {"auth_index": None, "name": "fake", "plan": None}, "balances": [], "bonuses": [], "pool": "deliberately-not-the-registration", "windows": windows or {"monthly": window()}})


def technique(name="spawn_agent", kind="subagent", model="gpt-6.1-sol", pattern=False, agent=None):
    return {"agent": agent, "model": {"isPattern": pattern, "value": model}, "name": name, "node": {"command": "MUST NEVER EXECUTE THIS LAUNCH", "kind": kind, "modelArg": "slug", "notes": "caller binds task/output paths"}}


def route(name="sol", tier="strong", pool="outside", target="codex", techniques=None, default=None):
    return {"family": {"avoidFor": "sole judge", "defaultEffort": default, "effort": "prose is not an effort enum", "name": name, "tier": tier, "useFor": "writer-judge loop", "vendor": "provider"}, "pool": pool, "target": target, "techniques": techniques or [technique()]}


def manifest(routes=None, session=None):
    return {"familyNames": [r["family"]["name"] for r in (routes or [route()])] + ["manual", "dormant"], "effortLevels": ["minimal", "low", "medium", "high", "xhigh", "max"], "manualRoutes": [route("manual", pool=None)], "pickerEntries": [], "readers": [{"command": "reader-outside", "name": "outside"}, {"command": "reader-session", "name": "session"}, {"command": "reader-hidden-runtime", "name": "hidden"}], "routes": routes or [route()], "runtime": "codex", "runtimes": ["codex"], "sessionPool": session}


def context(roles=("writer",), names=("sol",), techniques=None, non_interactive=False, effort="high"):
    return {"taskSummary": "bounded source change", "nonInteractive": non_interactive, "roles": {role: {"effort": effort} for role in roles}, "techniques": techniques or [{"efforts": ["high"], "model": "gpt-6.1-sol", "runtime": "codex", "technique": "spawn_agent"}]}


def picker_child_exited(child):
    try:
        os.kill(child, 0)
        # A killed child that nobody has reaped yet still answers signal 0.
        return Path("/proc").is_dir() and Path(f"/proc/{child}/stat").read_text().rpartition(")")[2].split()[0] == "Z"
    except (FileNotFoundError, ProcessLookupError):
        return True


class Routing(unittest.TestCase):
    def run_plan(self, config=None, launch_context=None, roles=("writer",), outputs=None, now=NOW):
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
        with patch.object(helper.subprocess, "Popen", side_effect=AssertionError("delegate/probe launched")), patch("time.sleep"):
            result = helper.plan(config or manifest(), launch_context or context(roles), roles, now, SHELL, reader)
        return result, calls

    def request_errors(self, config=None, launch_context=None, roles=("writer",)):
        # Every refusal happens before a Reader or picker could run.
        with patch.object(helper, "collect", side_effect=AssertionError("Readers invoked")), patch.object(helper, "run_picker", side_effect=AssertionError("picker invoked")):
            with self.assertRaises(helper.InvalidRequest) as caught:
                helper.plan(config or manifest(), launch_context or context(roles), roles, NOW, SHELL)
        return caught.exception.errors

    def picker_fixture(self, routes=None, roles=("writer",)):
        config, ctx = manifest(routes), context(roles)
        ctx["proposerFamily"] = "dormant"
        config["pickerEntries"] = [{"runtime": "codex", "technique": "one-shot", "family": "sol", "model": "gpt-6.1-sol", "effort": "medium", "pool": "outside", "command": "printf fake", "toolFree": True}]
        return config, ctx

    def decisions(self, *items):
        return json.dumps({"decisions": [{"decision": decision, "family": family, "reason": "bounded role fit", "role": role} for role, family, decision in items], "schemaVersion": 1}).encode()

    def test_picker_judges_role_before_measured_preference(self):
        # Wrong: pool preference removes unmeasured choices before semantic judgment,
        # or one family-global verdict forces writer and judge to share a decision.
        config, ctx = self.picker_fixture([route(), route("other", pool=None), route("small", tier="small")], ("writer", "judge"))
        raw = self.decisions(("writer", "sol", "keep"), ("writer", "other", "keep"), ("writer", "small", "exclude"), ("judge", "sol", "exclude"), ("judge", "other", "keep"))
        with patch.object(helper, "run_picker", return_value=raw) as picker:
            result, _ = self.run_plan(config, ctx, ("writer", "judge"))
        picker.assert_called_once()
        payload = picker.call_args.args[1]
        self.assertEqual([(x["role"], x["name"]) for x in payload["families"]], [("writer", "sol"), ("writer", "other"), ("writer", "small"), ("judge", "sol"), ("judge", "other")])
        self.assertNotIn("pools", payload)
        self.assertNotIn("command", json.dumps(payload))
        self.assertEqual([x["launch"]["family"] for x in result["roles"]["writer"]["candidates"]], ["sol"])
        self.assertEqual([x["launch"]["family"] for x in result["roles"]["judge"]["candidates"]], ["other"])
        self.assertEqual(result["picker"]["provenance"], {"runtime": "codex", "technique": "one-shot", "family": "sol", "model": "gpt-6.1-sol", "effort": "medium"})
        self.assertNotIn(helper.PICKER_WARNING, result["warnings"])

    def test_picker_hard_gates_and_avoid_partition_are_prompt_data(self):
        # Wrong: excluded, unreachable, exhausted or scoped-refused families reach
        # judgment; or avoided fallback requires a second unbounded inference.
        config, ctx = self.picker_fixture([route(), route("excluded"), route("dead", pool="hidden"), route("spent", pool="session"), route("scoped")])
        ctx["roles"]["writer"].update(avoid=["sol"], exclude=["excluded"])
        outputs = {"reader-hidden-runtime": subprocess.CompletedProcess([], 1, "secret", "private"), "reader-session": stream({"monthly": window(0)}), "reader-outside": stream({"monthly": window(), "weekly:scoped": window(0)})}
        with patch.object(helper, "run_picker", return_value=self.decisions(("writer", "sol", "keep"))) as picker:
            result, _ = self.run_plan(config, ctx, outputs=outputs)
        self.assertEqual(picker.call_args.args[1]["families"], [{"name": "sol", "tier": "strong", "useFor": "writer-judge loop", "avoidFor": "sole judge", "defaultEffort": None, "role": "writer", "avoided": True, "effectiveEffort": "high"}])
        self.assertEqual(result["roles"]["writer"]["candidates"][0]["launch"]["family"], "sol")

    def test_picker_order_skip_identity_and_loud_fallback(self):
        # Wrong: unknown identity is invented, self-picker runs, a command that is
        # not on PATH runs, or an unproven no-tools promise is treated as removal.
        config, ctx = self.picker_fixture()
        original = config["pickerEntries"][0]
        config["pickerEntries"] = [dict(original, toolFree=False), dict(original, command="no-such-delegate-binary --flag"), dict(original, family="dormant"), original]
        with patch.object(helper, "run_picker", return_value=self.decisions(("writer", "sol", "keep"))) as picker:
            result, _ = self.run_plan(config, ctx)
        self.assertEqual(picker.call_args.args[0], original)
        self.assertEqual(picker.call_count, 1)
        self.assertIn("picker", result)
        for identity in (None, "sol"):
            ctx["proposerFamily"] = identity
            config["pickerEntries"] = [original]
            with self.subTest(identity=identity), patch.object(helper, "run_picker", side_effect=AssertionError("unavailable picker ran")):
                result, _ = self.run_plan(config, ctx)
                self.assertIn(helper.PICKER_WARNING, result["warnings"])
                self.assertEqual(len(result["roles"]["writer"]["candidates"]), 1)

    def test_unknown_non_null_proposer_is_rejected_before_readers(self):
        # Wrong: a misspelled known proposer silently disables judgment after
        # spending a Reader snapshot instead of refusing malformed caller input.
        config, ctx = self.picker_fixture()
        ctx["proposerFamily"] = "not-configured"
        self.assertEqual(self.request_errors(config, ctx), [{"path": "launchContext.proposerFamily", "message": "unknown family name; allowed: dormant, manual, sol"}])

    def test_picker_reach_and_pool_gates_allow_headless_internal_call(self):
        # Wrong: worker headless policy forbids the authorized internal picker;
        # Reader/scoped/session exclusions or ordered external-runtime reaches
        # are ignored when choosing the picker itself.
        config, ctx = self.picker_fixture([route(), route("other", pool=None)])
        original = config["pickerEntries"][0]
        ctx["nonInteractive"] = True
        other = original | {"runtime": "claude", "technique": "claude -p", "model": "claude-sonnet-4-5", "family": "other", "pool": None}
        config["pickerEntries"] = [original, other]
        for status in ("unreachable", "exhausted", "scoped", "buffer"):
            config["sessionPool"] = "outside" if status == "buffer" else None
            outputs = {"reader-outside": subprocess.CompletedProcess([], 1, "", "private") if status == "unreachable" else stream({"monthly": window(0 if status == "exhausted" else 20 if status == "buffer" else 50), **({"weekly:sol": window(0)} if status == "scoped" else {})})}
            with self.subTest(status=status), patch.object(helper, "run_picker", return_value=self.decisions(("writer", "other", "keep"))) as picker:
                result, _ = self.run_plan(config, ctx, outputs=outputs)
                self.assertEqual(picker.call_args.args[0], other)
                self.assertEqual(picker.call_count, 1)
                self.assertEqual(result["picker"]["provenance"]["runtime"], "claude")

    def test_picker_one_transient_retry_and_no_malformed_retry(self):
        # Wrong: malformed results retry; transient failures never retry or retry
        # indefinitely; subprocess diagnostics leak into warning/provenance output.
        config, ctx = self.picker_fixture()
        valid = self.decisions(("writer", "sol", "keep"))
        for failure in (OSError("private"), subprocess.TimeoutExpired("secret", 90), subprocess.CalledProcessError(1, "secret", stderr="private")):
            with self.subTest(failure=type(failure)), patch.object(helper, "run_picker", side_effect=[failure, valid]) as picker:
                result, _ = self.run_plan(config, ctx)
                self.assertEqual(picker.call_count, 2)
                self.assertIn("picker", result)
                self.assertNotIn("private", json.dumps(result))
        config["pickerEntries"] *= 2
        with patch.object(helper, "run_picker", side_effect=[b"malformed private", valid]) as picker:
            result, _ = self.run_plan(config, ctx)
        self.assertEqual(picker.call_count, 2)
        self.assertIn("picker", result)
        with patch.object(helper, "run_picker", side_effect=OSError("private")) as picker:
            result, _ = self.run_plan(config, ctx)
        self.assertEqual(picker.call_count, 4)
        self.assertEqual(result["warnings"].count(helper.PICKER_WARNING), 1)
        self.assertNotIn("private", json.dumps(result))

    def test_picker_strict_pair_coverage_and_all_excluded(self):
        # Wrong: duplicate keys/pairs, non-finite values, bad Unicode, unknown roles,
        # extra fields/documents or partial role/family coverage are accepted.
        valid = self.decisions(("writer", "sol", "keep"))
        mutations = [valid + b"{}", valid.replace(b'"schemaVersion": 1', b'"schemaVersion": 1, "schemaVersion": 1'), valid.replace(b'"schemaVersion": 1', b'"schemaVersion": NaN'), valid.replace(b'"bounded role fit"', b'"\\ud800"'), valid.replace(b'"writer"', b'"judge"'), self.decisions(("writer", "sol", "keep"), ("writer", "sol", "exclude")), b'{"decisions":[],"schemaVersion":1}', valid.replace(b'"reason":', b'"extra":true,"reason":')]
        for raw in mutations:
            with self.subTest(raw=raw), self.assertRaises((ValueError, UnicodeError)):
                helper.picker_decisions(raw, {("writer", "sol")})
        config, ctx = self.picker_fixture()
        with patch.object(helper, "run_picker", return_value=self.decisions(("writer", "sol", "exclude"))):
            result, _ = self.run_plan(config, ctx)
        self.assertEqual(result["roles"]["writer"]["candidates"], [])
        self.assertIn("error", result["roles"]["writer"])
        self.assertNotIn(helper.PICKER_WARNING, result["warnings"])

    def test_closed_context_refuses_essays_before_readers(self):
        # Wrong: old family qualification essays survive the schema boundary.
        for key in ("families", "fit", "useFor", "avoidFor", "trial"):
            ctx = context()
            ctx["roles"]["writer"][key] = {}
            with self.subTest(key=key):
                self.assertEqual(self.request_errors(launch_context=ctx), [{"path": f"launchContext.roles.writer.{key}", "message": "unknown key; allowed: avoid, effort, exclude"}])
        ctx = context()
        ctx["essay"] = "unused"
        self.assertEqual(self.request_errors(launch_context=ctx), [{"path": "launchContext.essay", "message": "unknown key; allowed: nonInteractive, proposerFamily, roles, taskSummary, techniques"}])

    def test_request_errors_list_every_problem_with_paths(self):
        # Wrong: the first fault hides the rest, a misspelled effort becomes a silent
        # loop failure after Readers, or an absent nonInteractive crashes late.
        ctx = {"taskSummary": " ", "proposerFamily": "sool", "roles": {"writer": {"effort": "hihg", "avoid": ["sol", "nope"], "exclude": "sol", "fit": 1}, "wizard": {}}, "techniques": [{"runtime": "codex", "technique": "x", "model": "", "efforts": ["high", "hihg"]}, "bare"], "extra": 1}
        config = manifest(session="undeclared")
        config["routes"][0]["pool"] = "ghost"
        names = "dormant, manual, sol"
        efforts = "minimal, low, medium, high, xhigh, max"
        configuration = "configuration fault, not caller-fixable: "
        self.assertEqual(self.request_errors(config, ctx, ("writer", "oracle")), [
            {"path": "argv.role[1]", "message": "unknown role; allowed: finder, first-check, investigator, judge, mechanical, planner, second-check, writer"},
            {"path": "manifest.sessionPool", "message": configuration + "unregistered pool undeclared; registered: hidden, outside, session"},
            {"path": "manifest.routes[0].pool", "message": configuration + "unregistered pool ghost; registered: hidden, outside, session"},
            {"path": "launchContext.extra", "message": "unknown key; allowed: nonInteractive, proposerFamily, roles, taskSummary, techniques"},
            {"path": "launchContext.taskSummary", "message": "must be a non-empty UTF-8 string of at most 65536 bytes"},
            {"path": "launchContext.nonInteractive", "message": "required; true, false or null"},
            {"path": "launchContext.proposerFamily", "message": f"unknown family name; allowed: {names}"},
            {"path": "launchContext.techniques[0].model", "message": "must be a non-empty string"},
            {"path": "launchContext.techniques[1]", "message": "must be an object"},
            {"path": "launchContext.roles.writer.avoid[1]", "message": f"unknown family name; allowed: {names}"},
            {"path": "launchContext.roles.writer.exclude", "message": "must be a list of family names"},
            {"path": "launchContext.roles.writer.effort", "message": f"unknown effort; allowed: {efforts}"},
            {"path": "launchContext.roles.writer.fit", "message": "unknown key; allowed: avoid, effort, exclude"},
            {"path": "launchContext.roles.wizard", "message": "unknown role; allowed: finder, first-check, investigator, judge, mechanical, planner, second-check, writer"},
        ])
        ctx = context()
        del ctx["nonInteractive"]
        self.assertEqual(self.request_errors(launch_context=ctx), [{"path": "launchContext.nonInteractive", "message": "required; true, false or null"}])
        for key, value in (("taskSummary", "x" * 65537), ("roles", []), ("techniques", {})):
            ctx = context() | {key: value}
            self.assertEqual(len(self.request_errors(launch_context=ctx)), 1)

    def test_off_scale_observed_efforts_are_accepted_but_role_requests_are_not(self):
        # Wrong: Codex introspection that lists `ultra` (or Kimchi `off`) refuses a
        # valid caller; or a role request for `ultra` slips through to a silent loop failure.
        ctx = context()
        ctx["techniques"][0]["efforts"] = ["high", "ultra", "off"]
        result, _ = self.run_plan(manifest(), ctx)
        self.assertEqual([item["launch"]["effort"] for item in result["roles"]["writer"]["candidates"]], ["high"])
        ctx = context(effort="ultra")
        self.assertEqual(self.request_errors(launch_context=ctx), [{"path": "launchContext.roles.writer.effort", "message": "unknown effort; allowed: minimal, low, medium, high, xhigh, max"}])

    def test_claude_text_output_with_trailing_newline_is_a_valid_answer(self):
        # Wrong: the shipped claude template redirects the model's plain-text reply
        # (reply plus a final newline) to the output file; a parser that needs the
        # bare JSON bytes refuses every real answer.
        config, ctx = self.picker_fixture()
        reply = self.decisions(("writer", "sol", "keep")).decode()
        entry = config["pickerEntries"][0] | {"command": f"printf '%s\\n' {shlex.quote(reply)} > <output-file>"}
        raw = helper.run_picker(entry, {}, SHELL)
        self.assertEqual(raw, (reply + "\n").encode())
        self.assertEqual(helper.picker_decisions(raw, {("writer", "sol")})[0]["decision"], "keep")

    def test_cli_argument_and_file_faults_are_json_with_paths(self):
        # Wrong: a bad --now, unreadable --check-plan, missing manifest key, or a
        # manifest pool fault beside an unparseable context exits 2 with bare stderr.
        with tempfile.TemporaryDirectory(prefix="routing-plan-check-") as directory:
            root = Path(directory)
            config = manifest()
            (root / "manifest.json").write_text(json.dumps(config))
            (root / "context.json").write_text(json.dumps(context()))
            command = [sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--reader-shell", SHELL, "--launch-context", str(root / "context.json"), "--role", "writer"]

            def refused(extra):
                proc = subprocess.run(command + extra, capture_output=True, text=True)
                self.assertEqual(proc.returncode, 2)
                return json.loads(proc.stdout)
            document = refused(["--now", "garbage"])
            self.assertEqual([(e["path"]) for e in document["errors"]], ["argv.--now"])
            self.assertEqual(document["status"], "invalid-request")
            document = refused(["--check-plan", str(root / "absent.json")])
            self.assertEqual([e["path"] for e in document["errors"]], ["argv.--check-plan"])
            self.assertIn("absent.json", document["errors"][0]["message"])
            del config["effortLevels"], config["routes"]
            (root / "manifest.json").write_text(json.dumps(config))
            document = refused([])
            self.assertEqual([e["path"] for e in document["errors"]], ["manifest.effortLevels", "manifest.routes"])
            config = manifest(session="undeclared")
            (root / "manifest.json").write_text(json.dumps(config))
            (root / "context.json").write_text("{oops")
            document = refused([])
            self.assertEqual([e["path"] for e in document["errors"]], ["manifest.sessionPool", "launchContext"])

    def test_cli_malformed_manifest_and_bad_flags_report_every_schema_fault(self):
        # Wrong: a non-object manifest is matched as a string, a reader entry without
        # its keys is a traceback, or a bad --now hides the context's own faults.
        with tempfile.TemporaryDirectory(prefix="routing-plan-check-") as directory:
            root = Path(directory)
            (root / "context.json").write_text(json.dumps(context()))
            command = [sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--reader-shell", SHELL, "--launch-context", str(root / "context.json"), "--role", "writer"]

            def refused(config, extra=()):
                (root / "manifest.json").write_text(json.dumps(config))
                proc = subprocess.run(command + list(extra), capture_output=True, text=True)
                self.assertEqual(proc.returncode, 2, proc.stderr)
                self.assertNotIn("Traceback", proc.stderr)
                return [e["path"] for e in json.loads(proc.stdout)["errors"]]
            self.assertEqual(refused("routes, readers"), ["manifest"])
            self.assertEqual(refused([]), ["manifest"])
            config = manifest()
            config["readers"] = [{}]
            self.assertEqual(refused(config), ["manifest.readers[0].command", "manifest.readers[0].name"])
            config["readers"] = [{"command": "x"}, "outside"]
            self.assertEqual(refused(config), ["manifest.readers[0].name", "manifest.readers[1]"])
            config["readers"] = {"name": "outside"}
            self.assertEqual(refused(config), ["manifest.readers"])
            (root / "context.json").write_text(json.dumps({"taskSummary": "ok"}))
            self.assertEqual(refused(manifest(), ["--now", "garbage"]), ["launchContext.nonInteractive", "launchContext.techniques", "launchContext.roles", "argv.--now"])

    def test_cli_manifest_name_lists_are_configuration_faults(self):
        # Wrong: scalar or mixed-type name lists crash sorting/membership checks
        # or hide independent context and argv errors instead of refusing the manifest.
        with tempfile.TemporaryDirectory(prefix="routing-plan-check-") as directory:
            root = Path(directory)
            ctx = context() | {"proposerFamily": "sol", "taskSummary": ""}
            ctx["roles"]["writer"].update({"avoid": ["sol"], "exclude": ["manual"]})
            (root / "context.json").write_text(json.dumps(ctx))
            command = [sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--reader-shell", SHELL, "--launch-context", str(root / "context.json"), "--role", "writer", "--now", "garbage"]
            for field in ("effortLevels", "familyNames"):
                for value in (5, "high", ["high", 5], None, {"high": True}):
                    with self.subTest(field=field, value=value):
                        config = manifest()
                        config[field] = value
                        (root / "manifest.json").write_text(json.dumps(config))
                        proc = subprocess.run(command, capture_output=True, text=True)
                        self.assertNotIn("Traceback", proc.stderr)
                        self.assertEqual(proc.returncode, 2, proc.stderr)
                        document = json.loads(proc.stdout)
                        self.assertEqual(document["status"], "invalid-request")
                        self.assertEqual(document["errors"], [
                            {"path": f"manifest.{field}", "message": "configuration fault, not caller-fixable: must be a list of strings"},
                            {"path": "launchContext.taskSummary", "message": "must be a non-empty UTF-8 string of at most 65536 bytes"},
                            {"path": "argv.--now", "message": "garbage: Invalid isoformat string: 'garbage'"},
                        ])

    def test_cli_malformed_routes_keep_other_request_errors(self):
        # Wrong: malformed route entries crash normally and hide argv/context faults
        # beside a bad --now; context encoding failures are blamed on the manifest.
        with tempfile.TemporaryDirectory(prefix="routing-plan-check-") as directory:
            root = Path(directory)
            command = [sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--reader-shell", SHELL, "--launch-context", str(root / "context.json"), "--role", "nobody"]
            for kind in ("routes", "manualRoutes"):
                for value, path in (([1], f"manifest.{kind}[0]"), ([{key: value for key, value in route().items() if key != "pool"}], f"manifest.{kind}[0].pool"), (1, f"manifest.{kind}")):
                    config = manifest()
                    config[kind] = value
                    (root / "manifest.json").write_text(json.dumps(config))
                    (root / "context.json").write_text(json.dumps(context() | {"taskSummary": ""}))
                    for extra in ([], ["--now", "garbage"]):
                        with self.subTest(kind=kind, value=value, extra=extra):
                            proc = subprocess.run(command + extra, capture_output=True, text=True)
                            self.assertEqual(proc.returncode, 2, proc.stderr)
                            document = json.loads(proc.stdout)
                            self.assertEqual(document["status"], "invalid-request")
                            self.assertEqual([e["path"] for e in document["errors"]], ["argv.role[0]", path, "launchContext.taskSummary"] + (["argv.--now"] if extra else []))
            (root / "manifest.json").write_text(json.dumps(manifest()))
            (root / "context.json").write_text(json.dumps(context() | {"taskSummary": "\ud800"}))
            proc = subprocess.run(command + ["--now", "garbage"], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2, proc.stderr)
            self.assertEqual([e["path"] for e in json.loads(proc.stdout)["errors"]], ["argv.role[0]", "launchContext.taskSummary", "argv.--now"])

    def test_manifest_nested_shapes_are_refused_before_readers(self):
        # Wrong: route and picker shapes reach Readers, then crash without JSON.
        cases = [
            (("routes", 0, "family"), None, "manifest.routes[0].family"),
            (("routes", 0, "family", "name"), [], "manifest.routes[0].family.name"),
            (("routes", 0, "family", "tier"), None, "manifest.routes[0].family.tier"),
            (("routes", 0, "target"), None, "manifest.routes[0].target"),
            (("routes", 0, "techniques"), {}, "manifest.routes[0].techniques"),
            (("routes", 0, "techniques", 0, "model"), None, "manifest.routes[0].techniques[0].model"),
            (("routes", 0, "techniques", 0, "node", "kind"), [], "manifest.routes[0].techniques[0].node.kind"),
            (("manualRoutes", 0, "family"), None, "manifest.manualRoutes[0].family"),
            (("pickerEntries",), {}, "manifest.pickerEntries"),
            (("pickerEntries", 0), None, "manifest.pickerEntries[0]"),
            (("pickerEntries", 0, "command"), [], "manifest.pickerEntries[0].command"),
            (("pickerEntries", 0, "toolFree"), 1, "manifest.pickerEntries[0].toolFree"),
        ]
        for keys, value, expected in cases:
            with self.subTest(path=expected):
                config, ctx = self.picker_fixture()
                node = config
                for key in keys[:-1]:
                    node = node[key]
                node[keys[-1]] = value
                self.assertEqual([error["path"] for error in self.request_errors(config, ctx)], [expected])
        config, ctx = self.picker_fixture()
        del config["routes"][0]["family"]
        del config["routes"][0]["target"]
        del config["routes"][0]["techniques"]
        del config["pickerEntries"][0]["model"]
        self.assertEqual([error["path"] for error in self.request_errors(config, ctx)], [
            "manifest.routes[0].family", "manifest.routes[0].target",
            "manifest.routes[0].techniques", "manifest.pickerEntries[0].model",
        ])

    def test_cli_nested_manifest_faults_are_json_before_readers(self):
        # Wrong: valid pools hide missing route keys or malformed picker entries.
        with tempfile.TemporaryDirectory(prefix="routing-plan-check-") as directory:
            root = Path(directory)
            config, ctx = self.picker_fixture()
            log = root / "reads"
            for reader in config["readers"]:
                reader["command"] = f"printf x >> '{log}'"
            config["routes"][0] = {"pool": "outside"}
            config["pickerEntries"] = {}
            (root / "manifest.json").write_text(json.dumps(config))
            (root / "context.json").write_text(json.dumps(ctx))
            proc = subprocess.run([sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--launch-context", str(root / "context.json"), "--reader-shell", SHELL, "--role", "writer"], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2)
            document = json.loads(proc.stdout)
            self.assertEqual(document["status"], "invalid-request")
            self.assertEqual([error["path"] for error in document["errors"]], ["manifest.routes[0].family", "manifest.routes[0].target", "manifest.routes[0].techniques", "manifest.pickerEntries"])
            self.assertFalse(log.exists())

    def test_maximal_task_summary_reaches_the_picker(self):
        # Wrong: an accepted 65536-byte summary exceeds the framed prompt cap.
        config, ctx = self.picker_fixture()
        raw = self.decisions(("writer", "sol", "keep"))
        entry = config["pickerEntries"][0]
        entry["command"] = "printf '%s' " + shlex.quote(raw.decode()) + " > <output-file>"
        for summary in ("x" * 65536, "\x01" * 65536, "é" * 32768):
            with self.subTest(character=repr(summary[0])):
                ctx["taskSummary"] = summary
                with patch.object(helper, "collect", return_value={name: {"status": "unmeasured"} for name in ("hidden", "outside", "session")}):
                    result = helper.plan(config, ctx, ("writer",), NOW, SHELL)
                self.assertEqual(result["picker"]["decisions"], [{"decision": "keep", "family": "sol", "reason": "bounded role fit", "role": "writer"}])
                self.assertNotIn(helper.PICKER_WARNING, result["warnings"])

    def test_cli_invalid_request_is_json_on_stdout_and_exit_two(self):
        # Wrong: schema errors surface as a traceback or bare stderr text, run a
        # Reader, or leave stdout unparseable for the orchestrator.
        with tempfile.TemporaryDirectory(prefix="routing-plan-check-") as directory:
            root = Path(directory)
            log = root / "reads"
            config = manifest()
            config["readers"] = [{"name": "outside", "command": f"printf x >> '{log}'"}]
            (root / "manifest.json").write_text(json.dumps(config))
            (root / "context.json").write_text('{"taskSummary": "ok",\n "roles": {}, oops}')
            command = [sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--reader-shell", SHELL, "--launch-context", str(root / "context.json")]
            proc = subprocess.run(command + ["--role", "writer", "--role", "nobody"], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2)
            self.assertEqual(json.loads(proc.stdout), {"status": "invalid-request", "errors": [{"path": "argv.role[1]", "message": "unknown role; allowed: finder, first-check, investigator, judge, mechanical, planner, second-check, writer"}, {"path": "launchContext", "message": f"{root / 'context.json'}: line 2 col 15: Expecting property name enclosed in double quotes"}]})
            self.assertEqual(proc.stderr.splitlines()[0], "delegate-routing-plan: argv.role[1]: unknown role; allowed: finder, first-check, investigator, judge, mechanical, planner, second-check, writer")
            self.assertEqual(len(proc.stderr.splitlines()), 2)
            self.assertFalse(log.exists())
            proc = subprocess.run(command + ["--bogus"], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2)
            self.assertEqual(json.loads(proc.stdout)["errors"][0]["path"], "argv")
            self.assertFalse(log.exists())

    def test_picker_real_shell_literal_binding_and_bounds(self):
        # Wrong: template substitution executes a model as shell code; output and
        # prompt limits are decorative, or timeout leaves the one-shot process alive.
        config, _ = self.picker_fixture()
        entry = config["pickerEntries"][0] | {"model": "$(exit 7)", "command": "printf '%s' <model> > <output-file>"}
        self.assertEqual(helper.run_picker(entry, {}, SHELL), b"$(exit 7)")
        with patch.object(helper, "PICKER_OUTPUT_LIMIT", 2), self.assertRaisesRegex(ValueError, "output limit"):
            helper.run_picker(entry, {}, SHELL)
        with patch.object(helper, "PICKER_PROMPT_LIMIT", 2), self.assertRaisesRegex(ValueError, "prompt limit"):
            helper.run_picker(entry, {}, SHELL)
        with patch.object(helper, "PICKER_TIMEOUT", 0.02), self.assertRaises(subprocess.TimeoutExpired):
            helper.run_picker(entry | {"command": "while :; do :; done"}, {}, SHELL)

    def test_child_without_proc_is_alive_until_signal_zero_fails(self):
        # Wrong: an absent /proc stat file proves a surviving child exited.
        with patch.object(Path, "is_dir", return_value=False), patch.object(Path, "read_text", side_effect=FileNotFoundError), patch.object(os, "kill") as kill:
            self.assertFalse(picker_child_exited(123))
            kill.assert_called_once_with(123, 0)
        with patch.object(os, "kill", side_effect=ProcessLookupError):
            self.assertTrue(picker_child_exited(123))

    def test_picker_without_catalog_keeps_the_project_directory(self):
        # Wrong: Claude loses project settings when every picker runs in scratch.
        entry = self.picker_fixture()[0]["pickerEntries"][0] | {"command": "pwd > <output-file>"}
        self.assertEqual(helper.run_picker(entry, {}, SHELL).decode().strip(), str(Path.cwd()))

    def test_codex_picker_resolves_relative_home_before_changing_directory(self):
        # Wrong: the child resolves a relative CODEX_HOME inside picker scratch.
        entry = self.picker_fixture()[0]["pickerEntries"][0] | {"command": 'test -f <catalog-file>; test -f "$CODEX_HOME/models_cache.json"; case "$CODEX_HOME" in /*) printf absolute ;; *) printf relative ;; esac > <output-file>'}
        with self.codex_home():
            absolute = Path(os.environ["CODEX_HOME"])
            os.environ["CODEX_HOME"] = os.path.relpath(absolute)
            self.assertEqual(helper.run_picker(entry, {}, SHELL), b"absolute")

    def test_picker_output_overrun_kills_the_whole_process_group(self):
        # Wrong: a picker that writes past the limit and keeps running outlives the
        # call, or its children survive the kill.
        config, _ = self.picker_fixture()
        with tempfile.TemporaryDirectory(prefix="routing-plan-check-") as directory:
            pidfile = Path(directory) / "child.pid"
            command = f"sleep 60 & echo $! > '{pidfile}'; head -c 100 /dev/zero > <output-file>; wait"
            with patch.object(helper, "PICKER_OUTPUT_LIMIT", 10), patch.object(helper, "PICKER_TIMEOUT", 30), self.assertRaisesRegex(ValueError, "output limit"):
                helper.run_picker(config["pickerEntries"][0] | {"command": command}, {}, SHELL)
            child = int(pidfile.read_text())
            for _ in range(200):
                if picker_child_exited(child):
                    break
                time.sleep(0.01)
            else:
                os.kill(child, signal.SIGKILL)
                self.fail("picker child survived the output-limit kill")

    def test_picker_missing_output_is_malformed_not_transient(self):
        # Wrong: a picker that exits 0 without writing raises FileNotFoundError, an
        # OSError that the picker loop retries as a transient failure.
        config, _ = self.picker_fixture()
        config["pickerEntries"][0]["command"] = "true"
        with self.assertRaisesRegex(ValueError, "no output"):
            helper.run_picker(config["pickerEntries"][0], {}, SHELL)

    def test_picker_values_are_not_rescanned_for_tokens(self):
        # Wrong: a value containing a later token is rewritten by sequential replace.
        config, _ = self.picker_fixture()
        entry = config["pickerEntries"][0] | {"model": "x<output-file>y", "command": "printf '%s' <model> > <output-file>"}
        self.assertEqual(helper.run_picker(entry, {}, SHELL), b"x<output-file>y")

    def test_picker_needs_a_path_command_not_caller_evidence(self):
        # Wrong: the picker is skipped because the caller did not list its own
        # technique, or runs although its executable is absent.
        config, ctx = self.picker_fixture()
        self.assertEqual([item["technique"] for item in ctx["techniques"]], ["spawn_agent"])
        with patch.object(helper, "run_picker", return_value=self.decisions(("writer", "sol", "keep"))) as picker:
            result, _ = self.run_plan(config, ctx)
        self.assertEqual(picker.call_count, 1)
        self.assertNotIn(helper.PICKER_WARNING, result["warnings"])
        config["pickerEntries"][0]["command"] = "no-such-delegate-binary --flag"
        with patch.object(helper, "run_picker", side_effect=AssertionError("absent executable ran")):
            result, _ = self.run_plan(config, ctx)
        self.assertIn(helper.PICKER_WARNING, result["warnings"])

    def codex_home(self, models=None):
        """A scratch CODEX_HOME seeded from the fixture cache, with OPENAI* and CODEX* variables scrubbed."""
        directory = tempfile.TemporaryDirectory(prefix="routing-codex-home-")
        self.addCleanup(directory.cleanup)
        cache = json.loads(CODEX_CACHE.read_text())
        cache["models"] = cache["models"] if models is None else models
        (Path(directory.name) / "models_cache.json").write_text(json.dumps(cache))
        scrubbed = {key: value for key, value in os.environ.items() if not key.startswith(("CODEX", "OPENAI"))}
        return patch.dict(os.environ, scrubbed | {"CODEX_HOME": directory.name}, clear=True)

    def test_codex_picker_catalog_is_the_picked_model_with_every_tool_removed(self):
        # Wrong: the catalog keeps another model, keeps the live tool mode, shell,
        # apply_patch, clock, multi-agent or search settings, or drops other fields.
        live = json.loads(CODEX_CACHE.read_text())["models"][0]
        other = dict(live, slug="gpt-6-luna")
        entry = self.picker_fixture()[0]["pickerEntries"][0] | {"command": "cp <catalog-file> <output-file>"}
        with self.codex_home([other, live]):
            raw = helper.run_picker(entry, {}, SHELL)
        self.assertEqual(live["tool_mode"], "code_mode_only")
        expected = dict(live, tool_mode="direct", shell_type="disabled", apply_patch_tool_type=None, experimental_supported_tools=[], multi_agent_version=None, node_repl_disabled=True, supports_search_tool=False)
        self.assertEqual(json.loads(raw), {"models": [expected]})

    def test_codex_picker_without_a_catalog_entry_names_why_and_falls_back(self):
        # Wrong: a missing cache or model entry runs Codex on its default model
        # info (tools included), or fails with the bare warning and no reason.
        config, ctx = self.picker_fixture()
        config["pickerEntries"][0] |= {"command": "cp <catalog-file> <output-file>", "model": "gpt-6-luna"}
        with self.codex_home():
            cache = Path(os.environ["CODEX_HOME"]) / "models_cache.json"
            result, _ = self.run_plan(config, ctx)
            cache.unlink()
            missing, _ = self.run_plan(config, ctx)
        self.assertIn(helper.PICKER_WARNING + f" Unavailable: gpt-6-luna: no entry in Codex models cache {cache}.", result["warnings"])
        self.assertIn(helper.PICKER_WARNING + f" Unavailable: gpt-6-luna: Codex models cache {cache} unreadable (FileNotFoundError).", missing["warnings"])
        self.assertEqual(len(result["roles"]["writer"]["candidates"]), 1)

    @unittest.skipUnless(os.environ.get("CODEX_PICKER_COMMAND") and shutil.which("codex"), "needs the real codex binary and the shipped command in CODEX_PICKER_COMMAND")
    def test_codex_picker_request_has_no_tools_against_a_fake_provider(self):
        # Wrong: the shipped command sends a `tools` key or any tool item to the
        # Responses endpoint (flags alone leave code-mode exec and wait).
        requests = []
        reply = self.decisions(("writer", "sol", "keep")).decode()

        class Fake(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"models":[]}')

            def do_POST(self):
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                encoding = self.headers.get("Content-Encoding")
                if encoding == "gzip":
                    raw = gzip.decompress(raw)
                elif encoding == "zstd":
                    raw = subprocess.run(["zstd", "-d", "-q"], input=raw, capture_output=True, check=True).stdout
                requests.append(json.loads(raw))
                events = [{"type": "response.created", "response": {"id": "r"}}, {"type": "response.output_item.done", "item": {"type": "message", "role": "assistant", "id": "m", "content": [{"type": "output_text", "text": reply}]}}, {"type": "response.completed", "response": {"id": "r", "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}}}]
                body = "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                self.wfile.write(body)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        provider = ['model_provider="probe"', 'model_providers.probe.name="Probe"', f'model_providers.probe.base_url="http://127.0.0.1:{server.server_port}/v1"', 'model_providers.probe.wire_api="responses"', "model_providers.probe.requires_openai_auth=false", "model_providers.probe.supports_websockets=false"]
        command = os.environ["CODEX_PICKER_COMMAND"].replace("codex exec", "codex exec " + " ".join(f"-c {shlex.quote(item)}" for item in provider), 1)
        entry = self.picker_fixture()[0]["pickerEntries"][0] | {"command": command}
        with self.codex_home():
            raw = helper.run_picker(entry, {}, SHELL)
        self.assertEqual(raw.decode(), reply)
        self.assertEqual(len(requests), 1)
        self.assertNotIn("tools", requests[0])
        self.assertEqual([item for item in requests[0]["input"] if item.get("type") == "additional_tools" or "tool" in item.get("type", "")], [])

    def test_picker_is_not_called_without_an_eligible_family(self):
        # Wrong: a model call is spent when no role has a family to judge.
        config, ctx = self.picker_fixture([route("small", tier="small")], ("judge",))
        with patch.object(helper, "run_picker", side_effect=AssertionError("empty catalog judged")):
            result, _ = self.run_plan(config, ctx, ("judge",))
        self.assertEqual(result["roles"]["judge"]["candidates"], [])
        self.assertNotIn(helper.PICKER_WARNING, result["warnings"])

    def test_highest_version_among_observed_models_for_one_family(self):
        # Wrong: several observed models matching one pattern exclude the family,
        # or compare as strings (6.9 over 6.10) instead of version numbers.
        config = manifest([route(techniques=[technique(model="gpt-*-sol", pattern=True)])])
        observed = lambda model: {"efforts": ["high"], "model": model, "runtime": "codex", "technique": "spawn_agent"}
        ctx = context(techniques=[observed("gpt-6.9-sol"), observed("gpt-6.10-sol"), observed("gpt-6.1-sol"), observed("gpt-7-luna")])
        result, _ = self.run_plan(config, ctx)
        self.assertEqual([c["launch"]["model"] for c in result["roles"]["writer"]["candidates"]], ["gpt-6.10-sol"])
        self.assertEqual(result["roles"]["writer"]["exclusions"], [])

    def test_frozen_reader_corpus(self):
        # Wrong: idle null/skewed resets add window errors; envelopes lose registration identity, monthly duration or scoped pace.
        corpus = json.loads(FIXTURE.read_text())
        self.assertEqual(corpus["capturedAt"], "2026-11-10T00:08:41Z")
        # Literal expectations from capture fields and hand arithmetic, not measure().
        expected = {
            "anthropic-api": (0.671126133525, 0.959027001303174),
            "claude": (0.09, 1.1761706173426392),
            "codex": (0.67, 1.8244426034650434),
            "opencode-go": (0.23, 0.34550405357278063),
            "z-ai": (0.6, 1.0483952514813841),
        }
        self.assertEqual(set(corpus["readers"]), set(expected))
        self.assertEqual(corpus["readers"]["anthropic-api"]["windows"]["monthly"]["windowSeconds"], 2592000)
        self.assertEqual(corpus["readers"]["opencode-go"]["windows"]["monthly"]["windowSeconds"], 2678400)
        config = manifest([route("fable" if name == "claude" else name, pool=name) for name in expected])
        config["readers"] = [{"command": f"reader-{name}", "name": name} for name in expected]
        ctx = context(names=tuple(r["family"]["name"] for r in config["routes"]))
        ctx["roles"]["writer"].update({"avoid": [], "exclude": []})
        outputs = {f"reader-{name}": json.dumps(document) for name, document in corpus["readers"].items()}
        for session, order in [
            (None, ["codex", "claude", "z-ai", "anthropic-api", "opencode-go"]),
            ("claude", ["codex", "z-ai", "anthropic-api", "opencode-go"]),
        ]:
            with self.subTest(session=session):
                config["sessionPool"] = session
                result, calls = self.run_plan(config, ctx, outputs=outputs, now=helper.utc(corpus["capturedAt"]))
                self.assertEqual(calls, [r["command"] for r in config["readers"]])
                self.assertEqual(set(result["pools"]), set(expected))
                for name, (buffer, pace) in expected.items():
                    with self.subTest(pool=name):
                        pool = result["pools"][name]
                        self.assertEqual(pool["status"], "measured")
                        self.assertNotIn("windowErrors", pool)
                        self.assertAlmostEqual(pool["buffer"], buffer)
                        self.assertAlmostEqual(pool["pace"], pace)
                self.assertAlmostEqual(result["pools"]["claude"]["scopedPaces"]["7d:fable"], 6.795652455757471)
                candidates = result["roles"]["writer"]["candidates"]
                self.assertEqual([c["pool"] for c in candidates], order)
                for candidate in candidates:
                    self.assertAlmostEqual(candidate["pace"], expected[candidate["pool"]][1])
                self.assertEqual(result["roles"]["writer"]["exclusions"], [] if session is None else [{"family": "fable", "reason": "session buffer must be strictly greater than 20%", "runtime": "codex"}])

    def test_shared_avoid_ranking_all_roles(self):
        # Wrong: avoid is ignored, hard exclusion, or a review-only policy.
        roles = tuple(helper.ROLE_TIERS)
        config = manifest([route("fast", pool="outside"), route("normal", pool="session"), route("other", pool="hidden")])
        ctx = context(roles, ("fast", "normal", "other"))
        outputs = {"reader-outside": stream({"monthly": window(80)}), "reader-session": stream({"monthly": window(40)}), "reader-hidden-runtime": stream({"monthly": window(60)})}
        for role in roles:
            ctx["roles"][role]["avoid"] = ["other", "fast", "fast"]
        result, _ = self.run_plan(config, ctx, roles, outputs)
        for role in roles:
            with self.subTest(role=role):
                candidates = result["roles"][role]["candidates"]
                self.assertEqual([c["launch"]["family"] for c in candidates], ["normal", "fast", "other"])
                self.assertNotIn("fallback", candidates[0]["launch"])
                self.assertEqual(candidates[1]["launch"]["fallback"], {"kind": "avoided-family", "resolvedEffort": "high", "launchEffort": "high"})
                self.assertFalse(any(w.startswith(f"WARNING: {role}:") for w in result["warnings"]))
        for request in ctx["roles"].values():
            request["avoid"] = ["normal", "other", "fast"]
        result, _ = self.run_plan(config, ctx, roles, outputs)
        for role in roles:
            with self.subTest(role=role, all_avoided=True):
                self.assertEqual([c["launch"]["family"] for c in result["roles"][role]["candidates"]], ["fast", "other", "normal"])

    def test_non_avoided_first_pick_has_no_fallback_warning(self):
        # Wrong: retained avoided alternatives warn when the selected family is not avoided.
        ctx = context(("first-check",), ("glm", "sol"))
        ctx["roles"]["first-check"]["avoid"] = ["sol"]
        result, _ = self.run_plan(manifest([route("sol"), route("glm")]), ctx, ("first-check",))
        candidates = result["roles"]["first-check"]["candidates"]
        self.assertEqual([candidate["launch"]["family"] for candidate in candidates], ["glm", "sol"])
        self.assertEqual(candidates[1]["launch"]["fallback"], {"kind": "avoided-family", "resolvedEffort": "high", "launchEffort": "high"})
        self.assertEqual([warning for warning in result["warnings"] if warning.startswith("WARNING: first-check:")], [])

    def test_only_avoided_candidates_warn_once_per_role(self):
        # Wrong: every retained fallback warns or selection is reported as a failure.
        roles = ("first-check", "second-check", "judge")
        ctx = context(roles, ("glm", "sol"))
        for request in ctx["roles"].values():
            request["avoid"] = ["glm", "sol"]
        result, _ = self.run_plan(manifest([route("sol"), route("glm")]), ctx, roles)
        self.assertEqual([warning for warning in result["warnings"] if warning.startswith(tuple(f"WARNING: {role}:" for role in roles))], [
            "WARNING: first-check: no non-avoided candidate; using fallback glm at effort high. Report this to the user.",
            "WARNING: second-check: no non-avoided candidate; using fallback glm at effort high. Report this to the user.",
            "WARNING: judge: no non-avoided candidate; using fallback glm at effort high. Report this to the user.",
        ])

    def test_role_lists_validation_and_exclusion(self):
        # Wrong: malformed/unknown lists survive until Readers, or overlap avoids.
        roles = tuple(helper.ROLE_TIERS)
        config = manifest([route(), route(target="claude"), route("other")])
        for role in roles:
            for field in ("avoid", "exclude"):
                for value in (None, "sol", {}, [1], [True], [""], ["unknown"], ["provider"], ["s*"]):
                    with self.subTest(role=role, field=field, value=value):
                        ctx = context((role,), ("sol", "other"))
                        ctx["roles"][role][field] = value
                        with patch.object(helper, "collect", side_effect=AssertionError("invalid lists reached Readers")):
                            errors = self.request_errors(config, ctx, (role,))
                            self.assertEqual([error["path"] for error in errors], [f"launchContext.roles.{role}.{field}" + ("[0]" if isinstance(value, list) else "")])
            for lists in ({}, {"avoid": [], "exclude": []}, {"avoid": ["manual", "dormant"], "exclude": ["dormant"]}):
                ctx = context((role,), ("sol", "other"))
                ctx["roles"][role].update(lists)
                result, _ = self.run_plan(config, ctx, (role,))
                self.assertEqual([c["launch"]["family"] for c in result["roles"][role]["candidates"]], ["other", "sol"])
            ctx["roles"][role].update({"avoid": ["sol"], "exclude": ["sol", "sol"]})
            excluded_config = deepcopy(config)
            excluded_config["routes"][0]["family"]["tier"] = "invalid"
            result, _ = self.run_plan(excluded_config, ctx, (role,))
            self.assertEqual([c["launch"]["family"] for c in result["roles"][role]["candidates"]], ["other"])
            self.assertEqual([e["reason"] for e in result["roles"][role]["exclusions"] if e["family"] == "sol"], ["excluded by caller", "excluded by caller"])
            ctx["roles"][role]["exclude"] = ["other", "sol", "sol"]
            result, _ = self.run_plan(config, ctx, (role,))
            self.assertEqual(result["roles"][role]["candidates"], [])
            self.assertEqual([e["reason"] for e in result["roles"][role]["exclusions"]], ["excluded by caller"] * 3)

    def test_avoid_partitions_and_global_session_pace(self):
        # Wrong: avoided measurement erases fit-only, or avoid bypasses session pace.
        roles = tuple(helper.ROLE_TIERS)
        for session in (None, "session"):
            config = manifest([route("normal", pool=None if session is None else "session"), route("fast")] + ([route("unbound", pool=None)] if session else []), session)
            ctx = context(roles, ("normal", "fast", "unbound"))
            for request in ctx["roles"].values():
                request["avoid"] = ["fast"]
            outputs = {"reader-outside": stream({"monthly": window(80)}), "reader-session": stream({"monthly": window(40)})}
            result, _ = self.run_plan(config, ctx, roles, outputs)
            for role in roles:
                with self.subTest(role=role, session=session):
                    candidates = result["roles"][role]["candidates"]
                    self.assertEqual([c["launch"]["family"] for c in candidates], ["normal", "fast"] if session is None else ["unbound", "fast"])
                    if session is None:
                        self.assertEqual(candidates[0]["budget"], "fit-only; budget and session buffer unknown")
                    else:
                        self.assertIn("another fitting pool is ahead of session pace", [e["reason"] for e in result["roles"][role]["exclusions"]])

    def test_family_defaults_and_supported_fallback_effort(self):
        # Wrong: agent-only defaults, caller-ordered/lexical bumps, or top refusal.
        roles = tuple(helper.ROLE_TIERS)
        for default, override, supported, avoided, expected in [
            ("medium", None, ["high", "medium"], False, "medium"),
            ("medium", None, ["high", "medium"], True, "high"),
            ("high", None, ["max", "high"], True, "max"),
            ("high", None, ["max", "xhigh", "high"], True, "xhigh"),
            ("medium", "high", ["max", "high", "xhigh"], True, "xhigh"),
            ("max", None, ["max", "low"], True, "max"),
            (None, None, [], True, None),
            ("high", None, [], True, None),
            ("high", "max", [], True, None),
            (None, None, [], False, None),
        ]:
            for kind in ("subagent", "workflow", "external"):
                config = manifest([route(default=default, techniques=[technique(kind=kind)])])
                ctx = context(roles, effort=override)
                ctx["techniques"][0]["efforts"] = supported
                for request in ctx["roles"].values():
                    request["avoid"] = ["sol"] if avoided else []
                result, _ = self.run_plan(config, ctx, roles)
                for role in roles:
                    with self.subTest(role=role, default=default, override=override, supported=supported, avoided=avoided, kind=kind):
                        self.assertTrue(result["roles"][role]["candidates"], "family default/omission must resolve a launch")
                        candidate = result["roles"][role]["candidates"][0]
                        self.assertEqual(candidate["launch"]["effort"], expected)
                        if expected is None:
                            self.assertNotIn("effort=", candidate["line"])
                        if avoided:
                            self.assertEqual(candidate["launch"]["fallback"], {"kind": "avoided-family", "resolvedEffort": override or default, "launchEffort": expected})
        for default, override, supported in [(None, None, ["high"]), ("medium", None, ["high"]), ("high", "low", ["high", "max"]), ("ultra", None, ["high"])]:
            with self.subTest(unsupported=(default, override, supported)):
                ctx = context(roles, effort=override)
                ctx["techniques"][0]["efforts"] = supported
                for request in ctx["roles"].values():
                    request["avoid"] = ["sol"]
                result, _ = self.run_plan(manifest([route(default=default)]), ctx, roles)
                self.assertTrue(all(not result["roles"][role]["candidates"] for role in roles))

    def test_no_effort_support_omits_every_role_pin(self):
        # Empty support overrides defaults and requests on every launch kind.
        roles = tuple(helper.ROLE_TIERS)
        for default, override in [("high", None), (None, "max"), ("high", "low")]:
            for avoided in (False, True):
                for kind in ("subagent", "workflow", "external"):
                    config = manifest([route(default=default, techniques=[technique(kind=kind)])])
                    ctx = context(roles, effort=override)
                    ctx["techniques"][0]["efforts"] = []
                    for request in ctx["roles"].values():
                        request["avoid"] = ["sol"] if avoided else []
                    result, _ = self.run_plan(config, ctx, roles)
                    for role in roles:
                        with self.subTest(role=role, default=default, override=override, avoided=avoided, kind=kind):
                            self.assertEqual(result["roles"][role]["exclusions"], [])
                            candidate = result["roles"][role]["candidates"][0]
                            self.assertIsNone(candidate["launch"]["effort"])
                            self.assertEqual(candidate["line"], f"role={role} runtime=codex family=sol technique=spawn_agent model=gpt-6.1-sol")
                            if avoided:
                                self.assertEqual(candidate["launch"]["fallback"], {"kind": "avoided-family", "resolvedEffort": override or default, "launchEffort": None})
                            else:
                                self.assertNotIn("fallback", candidate["launch"])

    def test_avoid_alternatives_and_fresh_launch_equality(self):
        # Wrong: only the primary technique discloses fallback or saved metadata is ignored.
        nodes = [technique(), technique("Workflow", "workflow")]
        roles = ("writer", "first-check", "second-check", "judge")
        ctx = context(roles)
        ctx["techniques"].append({"efforts": ["high"], "model": "gpt-6.1-sol", "runtime": "codex", "technique": "Workflow"})
        for request in ctx["roles"].values():
            request["avoid"] = ["sol"]
        result, _ = self.run_plan(manifest([route(techniques=nodes)]), ctx, roles)
        candidate = result["roles"]["writer"]["candidates"][0]
        self.assertEqual(candidate["alternatives"][0]["fallback"], {"kind": "avoided-family", "resolvedEffort": "high", "launchEffort": "high"})
        with tempfile.TemporaryDirectory(prefix="routing-fallback-plan-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            artifact["snapshot"] = result
            for unit in artifact["units"]:
                unit["launches"] = [dict(record, candidate=deepcopy(result["roles"][record["role"]]["candidates"][0]["launch"]), line=result["roles"][record["role"]]["candidates"][0]["line"]) for record in unit["launches"]]
            self.assertEqual(helper.check_plan(artifact, result, root)["status"], "valid")
            del artifact["units"][0]["launches"][0]["candidate"]["fallback"]
            with self.assertRaisesRegex(ValueError, "absent from current"):
                helper.check_plan(artifact, result, root)

    def test_avoided_routes_keep_intrinsic_gates(self):
        # Wrong: fallback bypasses floors, headless, failed/scoped/buffer gates.
        for role in helper.ROLE_TIERS:
            for gate in ("floor", "headless", "unreachable", "exhausted", "scoped", "buffer"):
                config = manifest([route()], "outside" if gate == "buffer" else None)
                ctx = context((role,))
                ctx["roles"][role]["avoid"] = ["sol"]
                outputs = {}
                if gate == "floor":
                    config["routes"][0]["family"]["tier"] = "invalid"
                elif gate == "headless":
                    config["routes"][0]["techniques"][0]["node"]["kind"] = "external"
                    ctx["nonInteractive"] = True
                elif gate == "unreachable":
                    outputs["reader-outside"] = subprocess.CompletedProcess([], 7, "", "private")
                elif gate == "exhausted":
                    outputs["reader-outside"] = stream({"monthly": window(0)})
                elif gate == "scoped":
                    outputs["reader-outside"] = stream({"monthly": window(), "weekly:sol": window(0)})
                else:
                    outputs["reader-outside"] = stream({"monthly": window(20)})
                with self.subTest(role=role, gate=gate):
                    result, _ = self.run_plan(config, ctx, (role,), outputs)
                    self.assertEqual(result["roles"][role]["candidates"], [])
                    self.assertIn("error", result["roles"][role])

    def test_fallback_cli_json_stderr_and_null_omission(self):
        # Wrong: fallback is silent or None/null is bound as an effort token.
        with tempfile.TemporaryDirectory(prefix="routing-fallback-") as directory:
            root = Path(directory)
            config = manifest([route(default=None)])
            config["readers"] = [{"name": "outside", "command": "printf '%s' " + shlex.quote(stream())}]
            ctx = context(effort=None)
            ctx["techniques"][0]["efforts"] = []
            ctx["roles"]["writer"]["avoid"] = ["sol"]
            for name, value in (("manifest", config), ("context", ctx)):
                (root / f"{name}.json").write_text(json.dumps(value))
            proc = subprocess.run([sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--reader-shell", SHELL, "--launch-context", str(root / "context.json"), "--now", "2026-11-15T00:00:00Z", "--role", "writer"], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            launch = json.loads(proc.stdout)["roles"]["writer"]["candidates"][0]["launch"]
            self.assertEqual(launch["fallback"], {"kind": "avoided-family", "resolvedEffort": None, "launchEffort": None})
            self.assertIn("writer: no non-avoided candidate; using fallback sol", proc.stderr)
            self.assertIn("at effort omitted intentionally", proc.stderr)
            self.assertIn("Report this to the user.", proc.stderr)
            self.assertNotIn("effort=", proc.stderr)

    def test_partial_window_facts(self):
        # Wrong: a bad reset erases a readable share or the healthy weekly pace.
        for remaining, buffer, pace, status in [(10, 0.1, 1.0, "measured"), ("unreadable", None, 1.0, "measured"), (0, 0, 0, "measured")]:
            with self.subTest(remaining=remaining):
                bad = window(10, 18000, "private-reset-payload")
                bad["remainingPercent"] = remaining
                if isinstance(remaining, int):
                    bad["usedPercent"] = 100 - remaining
                result, _ = self.run_plan(outputs={"reader-outside": stream({"7d": window(50, 604800, "2026-11-18T12:00:00Z"), "5h": bad})})
                pool = result["pools"]["outside"]
                self.assertEqual((pool["status"], pool["buffer"], pool["pace"]), (status, buffer, pace))
                self.assertEqual(len([w for w in result["warnings"] if "outside" in w and "5h" in w]), 1)
                self.assertNotIn("private-reset-payload", json.dumps(result))
        # Wrong: unreadable data erases a conclusive zero, or all-bad pace is invented.
        for windows, buffer, pace, status in [
            ({"5h": window(0, 0, None), "7d": {}}, 0, 0, "measured"),
            ({"5h": window(10, 0, None)}, 0.1, None, "unmeasured"),
            ({"5h": {}}, None, None, "unmeasured"),
        ]:
            with self.subTest(windows=windows):
                pool = helper.measure(stream(windows), NOW)
                self.assertEqual((pool["status"], pool["buffer"], pool["pace"]), (status, buffer, pace))

    def test_partial_session_certification(self):
        # Wrong: certify only readable shares, or discard a low share with bad pace.
        config = manifest([route(pool="session")], "session")
        for remaining, expected in [(10, False), (None, False), (0, False), (20, False), (20.01, True)]:
            with self.subTest(remaining=remaining):
                bad = window(10, 0, None)
                if remaining is None:
                    del bad["remainingPercent"]
                else:
                    bad["remainingPercent"] = remaining
                result, _ = self.run_plan(config, outputs={"reader-session": stream({"7d": window(50, 604800, "2026-11-18T12:00:00Z"), "5h": bad})})
                self.assertEqual(bool(result["roles"]["writer"]["candidates"]), expected)
                if remaining is None:
                    self.assertEqual(result["roles"]["writer"]["exclusions"][-1]["reason"], "session buffer cannot be certified")
        # Wrong: booleans or non-finite/out-of-range shares certify a buffer.
        for share in (True, float("nan"), float("inf"), -1, 101):
            with self.subTest(share=share):
                pool = helper.measure(stream({"7d": window(), "bad": {"remainingPercent": share}}), NOW)
                self.assertIsNone(pool["buffer"])

    def counted_reader(self, mode, expected, count):
        with tempfile.TemporaryDirectory(prefix="routing-retry-") as directory:
            root = Path(directory)
            counter = root / "calls"
            script = root / "reader.py"
            script.write_text(
                "from pathlib import Path\nimport sys\nimport time\n"
                f"counter = Path({str(counter)!r})\n"
                "count = int(counter.read_text()) + 1 if counter.exists() else 1\n"
                "counter.write_text(str(count))\n"
                f"mode = {mode!r}\n"
                "if mode == 'fail-twice' or mode == 'fail-once' and count == 1:\n    sys.exit(7)\n"
                "if mode == 'timeout-once' and count == 1:\n    time.sleep(30)\n"
                f"print('invalid-json' if mode == 'invalid-json' else '[]' if mode == 'invalid-envelope' else {stream()!r})\n"
            )
            command = shlex.join([sys.executable, str(script)])
            readers = [{"command": command, "name": name} for name in ("outside", "alias")]
            with patch.object(helper, "READER_TIMEOUT", 5), patch("time.sleep") as sleep:
                result = helper.collect(readers, NOW, SHELL)
            self.assertEqual(int(counter.read_text()), count)
            self.assertEqual(result, {"alias": expected, "outside": expected})
            # Count only the retry pause: subprocess's own timeout polling also
            # calls time.sleep, as often as the runner's speed dictates.
            retry_pauses = sleep.call_args_list.count(call(helper.READER_RETRY_DELAY))
            self.assertEqual(helper.READER_RETRY_DELAY, 2)
            self.assertEqual(retry_pauses, 1 if count == 2 else 0)

    def test_reader_retries_nonzero_once_then_measures(self):
        # Wrong: a non-zero Reader exit is final even when the retry succeeds.
        self.counted_reader("fail-once", {"buffer": 0.5, "pace": 0.9375, "status": "measured"}, 2)

    def test_reader_retries_nonzero_only_once(self):
        # Wrong: a persistent non-zero Reader exit retries indefinitely.
        self.counted_reader("fail-twice", {"reason": "Reader exited 7", "status": "unreachable"}, 2)

    def test_reader_retries_timeout_once_then_measures(self):
        # Wrong: a Reader timeout is final even when the retry succeeds.
        self.counted_reader("timeout-once", {"buffer": 0.5, "pace": 0.9375, "status": "measured"}, 2)

    def test_reader_does_not_retry_invalid_json(self):
        # Wrong: invalid Reader JSON is retried as a transport failure.
        self.counted_reader("invalid-json", {"reason": "invalid Reader output", "status": "unreachable"}, 1)

    def test_reader_does_not_retry_invalid_envelope(self):
        # Wrong: an invalid Reader envelope is retried as a transport failure.
        self.counted_reader("invalid-envelope", {"reason": "invalid Reader output", "status": "unreachable"}, 1)

    def test_dropped_window_warning_reports_failure_to_user(self):
        # Wrong: a dropped window warning omits the user-report instruction.
        result, _ = self.run_plan(outputs={"reader-outside": stream({"5h": window(50, 0, None)})})
        self.assertEqual([w for w in result["warnings"] if w.startswith("WARNING:") and w != helper.PICKER_WARNING], ["WARNING: outside: window 5h pace dropped: invalid windowSeconds. Report this failure to the user."])

    def test_window_warning_cannot_forge_stderr_lines(self):
        # Wrong: Reader-controlled window names inject extra stderr lines.
        result, _ = self.run_plan(outputs={"reader-outside": stream({"5h\nFORGED\x1b": window(50, 0, None)})})
        warnings = [w for w in result["warnings"] if w.startswith("WARNING:") and w != helper.PICKER_WARNING]
        self.assertEqual(warnings, ["WARNING: outside: window 5h\\nFORGED\\x1b pace dropped: invalid windowSeconds. Report this failure to the user."])
        self.assertEqual(len(warnings[0].splitlines()), 1)

    def test_reader_failures_never_supply_fit_only_routes(self):
        # Wrong: failed Readers become fit-only choices, including HTTP 429.
        failures = [
            (subprocess.CompletedProcess("secret-command", 7, "", "HTTP 429 secret-stderr"), "Reader exited 7"),
            (subprocess.TimeoutExpired("secret-command", 10, stderr="secret-stderr"), "Reader timed out"),
            (OSError("secret-command secret-stderr"), "Reader could not execute"),
            ("secret-json", "invalid Reader output"),
            ("[]", "invalid Reader output"),
            (stream() + "\n" + stream(), "invalid Reader output"),
        ]
        for value, reason in failures:
            with self.subTest(reason=reason, value=value):
                config = manifest([route(), route("other", pool="session")])
                config["readers"][1]["command"] = "reader-outside"
                outputs = {"reader-outside": value}
                result, calls = self.run_plan(config, context(names=("sol", "other")), outputs=outputs)
                self.assertEqual(calls.count("reader-outside"), 2 if reason in {"Reader exited 7", "Reader timed out"} else 1)
                self.assertEqual(result["pools"]["outside"], {"reason": reason, "status": "unreachable"})
                self.assertEqual(result["roles"]["writer"]["candidates"], [])
                self.assertEqual([w for w in result["warnings"] if "Reader for" in w], [f"WARNING: Reader for outside, session failed: {reason}. Report this failure to the user."])
                self.assertNotIn("secret-", json.dumps(result))
                # A healthy alternative survives, without resurrecting the failed pool.
                config["readers"][1]["command"] = "reader-session"
                result, _ = self.run_plan(config, context(names=("sol", "other")), outputs=outputs)
                self.assertEqual([c["launch"]["family"] for c in result["roles"]["writer"]["candidates"]], ["other"])

    def test_unmeasured_envelopes_and_exhausted_preference(self):
        # Wrong: exhaustion suppresses an independently observed unbound route.
        config = manifest([route(), route("unbound", pool=None)])
        result, _ = self.run_plan(config, context(names=("sol", "unbound")), outputs={"reader-outside": stream({"5h": window(0)})})
        self.assertEqual([c["launch"]["family"] for c in result["roles"]["writer"]["candidates"]], ["unbound"])
        self.assertEqual(result["roles"]["writer"]["candidates"][0]["budget"], "fit-only; budget and session buffer unknown")
        # Wrong: empty valid windows or missing registrations are transport failures.
        empty = json.loads(stream())
        empty["windows"] = {}
        for value in (json.dumps(empty), stream({"5h": window(10, 0, None)})):
            with self.subTest(value=value):
                result, _ = self.run_plan(outputs={"reader-outside": value})
                self.assertEqual(result["pools"]["outside"]["status"], "unmeasured")
                self.assertEqual(len(result["roles"]["writer"]["candidates"]), 1)
        config = manifest()
        config["readers"][0]["command"] = None
        result, _ = self.run_plan(config)
        self.assertEqual(result["pools"]["outside"]["status"], "unmeasured")
        self.assertEqual(len(result["roles"]["writer"]["candidates"]), 1)

    def test_scoped_limits_without_usable_unscoped_pace(self):
        # Wrong: reject a valid envelope or resurrect an exhausted scoped family.
        for remaining, expected in [(50, ["sol"]), (0, [])]:
            with self.subTest(remaining=remaining):
                result, _ = self.run_plan(outputs={"reader-outside": stream({"7d:sol": window(remaining)})})
                self.assertEqual(result["pools"]["outside"]["status"], "unmeasured")
                self.assertEqual([c["launch"]["family"] for c in result["roles"]["writer"]["candidates"]], expected)
                if remaining == 50:
                    self.assertEqual(result["roles"]["writer"]["candidates"][0]["pace"], 0.9375)

    def test_cli_clean_stderr_contains_only_launch_lines(self):
        # Wrong: advisory JSON warnings pollute a clean run's launch lines.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = manifest()
            for reader in config["readers"]:
                reader["command"] = shlex.join(["printf", "%s", stream()])
            (root / "manifest.json").write_text(json.dumps(config))
            (root / "context.json").write_text(json.dumps(context()))
            proc = subprocess.run([sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--launch-context", str(root / "context.json"), "--reader-shell", SHELL, "--role", "writer", "--now", NOW.isoformat()], capture_output=True, text=True)
            result = json.loads(proc.stdout)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("provider-vendor identity is provisional; trial/maker independence remain caller assessments", result["warnings"])
            self.assertEqual(proc.stderr.splitlines(), [helper.PICKER_WARNING] + [item["line"] for item in result["roles"]["writer"]["candidates"]])

    def test_cli_degradation_uses_json_warnings(self):
        # Wrong: advisory notes precede failures, failures are silent, or all-failed returns success.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = manifest()
            for reader in config["readers"]:
                reader["command"] = "printf '%s' 'private-reader-stderr' >&2; exit 7"
            (root / "manifest.json").write_text(json.dumps(config))
            (root / "context.json").write_text(json.dumps(context()))
            proc = subprocess.run([sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--launch-context", str(root / "context.json"), "--reader-shell", SHELL, "--role", "writer", "--now", NOW.isoformat()], capture_output=True, text=True)
            result = json.loads(proc.stdout)
            self.assertEqual(proc.returncode, 1)
            self.assertEqual(result["roles"]["writer"]["candidates"], [])
            for warning in result["warnings"]:
                self.assertEqual(proc.stderr.count(warning), int(warning.startswith("WARNING:")))
            self.assertTrue(proc.stderr.startswith("WARNING: Reader for hidden, outside, session failed: Reader exited 7."))
            self.assertIn("WARNING: Reader for hidden, outside, session failed: Reader exited 7. Report this failure to the user.\n", proc.stderr)
            self.assertNotIn("private-reader-stderr", proc.stdout + proc.stderr)

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
        for own, other, expected in [(60, 45, "own"), (60, 60, "other"), (45, 60, "other"), (20, 10, "other"), (20.01, 10, "own")]:
            with self.subTest(own=own, other=other):
                result, _ = self.run_plan(config, context(names=("own", "other")), outputs={"reader-outside": stream({"5h": window(other, 18000, "2026-11-15T02:30:00Z")}), "reader-session": stream({"5h": window(own, 18000, "2026-11-15T02:30:00Z")})})
                self.assertEqual(result["roles"]["writer"]["candidates"][0]["launch"]["family"], expected)
        # Own pace leads despite the tighter buffer: max-share buffering fails.
        for remaining, expected in [(20, "other"), (20.01, "own")]:
            result, _ = self.run_plan(config, context(names=("own", "other")), outputs={"reader-session": stream({"monthly": window(60), "5h": window(remaining, 18000, "2026-11-15T00:30:00Z")})})
            self.assertEqual(result["roles"]["writer"]["candidates"][0]["launch"]["family"], expected)

    def test_session_pool_last_on_measured_tie(self):
        config = manifest([route("alpha", pool="session"), route("zulu")], "session")
        result, _ = self.run_plan(config, context(names=("alpha", "zulu")))
        self.assertEqual([(item["launch"]["family"], item["pace"]) for item in result["roles"]["writer"]["candidates"]], [("zulu", 0.9375), ("alpha", 0.9375)])

    def test_unmeasured_session_buffer_excludes_fit_only_candidate(self):
        # Preservation: an unmeasured session never permits fit-only use of its buffer.
        config = manifest([route("alpha", pool="session"), route("zulu")], "session")
        for outside in (stream({"5h": window(reset=None)}), stream()):
            with self.subTest(outside=outside):
                result, _ = self.run_plan(config, context(names=("alpha", "zulu")), outputs={"reader-outside": outside, "reader-session": stream({"5h": window(reset=None)})})
                self.assertEqual([item["launch"]["family"] for item in result["roles"]["writer"]["candidates"]], ["zulu"])
                self.assertEqual(result["roles"]["writer"]["exclusions"], [{"family": "alpha", "reason": "session buffer cannot be certified", "runtime": "codex"}])

    def test_idle_unscoped_window_preserves_used_weekly_pace(self):
        # Wrong: an idle null reset makes the pool unmeasured or limits its pace.
        windows = {
            "5h": {"usedPercent": 0, "remainingPercent": 100, "resetsAt": None, "status": None, "windowSeconds": 18000},
            "7d": window(52, 604800, "2026-11-18T12:00:00Z"),
        }
        result, _ = self.run_plan(outputs={"reader-outside": stream(windows)})
        self.assertEqual(result["pools"]["outside"], {"buffer": 0.52, "pace": 1.04, "status": "measured"})

    def test_all_idle_unscoped_windows_have_full_buffer(self):
        # Wrong: no active pace means missing unscoped windows or an empty minimum.
        result, _ = self.run_plan(outputs={"reader-outside": stream({"5h": {"usedPercent": 0, "remainingPercent": 100, "resetsAt": None, "status": None, "windowSeconds": 18000}})})
        self.assertEqual(result["pools"]["outside"], {"buffer": 1.0, "pace": 1.0, "status": "measured"})

    def test_idle_reset_adds_no_limit_and_used_reset_stays_strict(self):
        # Wrong: a fixed clock-skew tolerance rejects a later idle reset.
        now = helper.utc("2026-11-09T23:59:51Z")
        idle = {"usedPercent": 0, "remainingPercent": 100, "resetsAt": "2026-11-10T05:00:02Z", "status": "ok", "windowSeconds": 18000}
        with self.subTest(window="opencode idle reset beyond window duration"):
            measured = helper.measure(stream({"5h": idle}), now)
            self.assertEqual(measured, {"buffer": 1.0, "pace": 1.0, "status": "measured"})
        # Wrong: extending the used-window duration bound.
        for remaining, reset in [(50, "2026-11-15T05:00:01Z"), (50, "2026-11-15T10:00:00Z")]:
            with self.subTest(remaining=remaining, reset=reset):
                result, _ = self.run_plan(outputs={"reader-outside": stream({"5h": window(remaining, 18000, reset)})})
                self.assertEqual(result["pools"]["outside"]["status"], "unmeasured")
                self.assertEqual(result["pools"]["outside"]["windowErrors"]["5h"], "expired reset or reset beyond window duration")

    def test_live_claude_scopes_preserve_pool_measurement(self):
        # Wrong: any colon makes the pool unmeasured, or scopes set pool pace/buffer.
        for remaining in (52, 10, 0):
            with self.subTest(remaining=remaining):
                result, _ = self.run_plan(manifest([route("fable"), route("sol")]), context(names=("fable", "sol")), outputs={"reader-outside": stream({"7d": window(17, 604800, "2026-11-18T12:00:00Z"), "7d:fable": window(remaining, 604800, "2026-11-18T12:00:00Z")})})
                pool = result["pools"]["outside"]
                self.assertEqual(pool["status"], "measured")
                self.assertEqual(pool["pace"], 0.34)
                self.assertEqual(pool["buffer"], 0.17)
                candidates = {item["launch"]["family"]: item["pace"] for item in result["roles"]["writer"]["candidates"]}
                self.assertEqual(candidates, {52: {"fable": 0.34, "sol": 0.34}, 10: {"fable": 0.2, "sol": 0.34}, 0: {"sol": 0.34}}[remaining])
                if remaining == 0:
                    self.assertEqual(result["roles"]["writer"]["exclusions"][-1]["reason"], "model-scoped window exhausted")

    def test_live_claude_unstarted_scope_and_inactive_limit(self):
        # Wrong: an unused Opus window fails the pool, or inactive limits are ignored.
        windows = {
            "7d": {"remainingPercent": 52, "resetsAt": "2026-11-18T12:00:00Z", "status": None, "usedPercent": 48, "windowSeconds": 604800},
            "7d:fable": {"remainingPercent": 17, "resetsAt": "2026-11-18T12:00:00Z", "status": "inactive", "usedPercent": 83, "windowSeconds": 604800},
            "7d:opus": {"remainingPercent": 100, "resetsAt": None, "status": None, "usedPercent": 0, "windowSeconds": 604800},
        }
        result, _ = self.run_plan(manifest([route("fable"), route("opus"), route("sol")]), context(names=("fable", "opus", "sol")), outputs={"reader-outside": stream(windows)})
        self.assertEqual(result["pools"]["outside"], {"buffer": 0.52, "pace": 1.04, "scopedPaces": {"7d:fable": 0.34, "7d:opus": None}, "status": "measured"})
        self.assertEqual({item["launch"]["family"]: item["pace"] for item in result["roles"]["writer"]["candidates"]}, {"fable": 0.34, "opus": 1.04, "sol": 1.04})

    def test_malformed_scopes_refuse_only_the_named_family(self):
        # Wrong: malformed scoped data fails the pool or silently drops its limit.
        cases = [
            ([], "window must be an object"),
            ({"remainingPercent": 50}, "'windowSeconds'"),
            (window(50, 604800, None), "unstarted null reset unresolved"),
            (window(50, 604800, "2026-11-14T00:00:00Z"), "expired reset or reset beyond window duration"),
            (window(101, 604800, None), "invalid remainingPercent"),
        ]
        for value, reason in cases:
            with self.subTest(reason=reason):
                result, _ = self.run_plan(manifest([route("fable"), route("sol")]), context(names=("fable", "sol")), outputs={"reader-outside": stream({"7d": window(52, 604800, "2026-11-18T12:00:00Z"), "7d:fable": value})})
                self.assertEqual(result["pools"]["outside"]["status"], "measured")
                self.assertEqual(result["pools"]["outside"]["pace"], 1.04)
                self.assertEqual(result["pools"]["outside"]["buffer"], 0.52)
                self.assertEqual([(item["launch"]["family"], item["pace"]) for item in result["roles"]["writer"]["candidates"]], [("sol", 1.04)])
                self.assertEqual(result["roles"]["writer"]["exclusions"][-1]["reason"], "model-scoped window invalid")
                self.assertIn(f"WARNING: outside: scoped window 7d:fable invalid; refusing its family: {reason}. Report this failure to the user.", result["warnings"])

    def test_invalid_scope_does_not_block_another_session_family(self):
        # Wrong: an invalid family's pool pace blocks a valid session candidate.
        result, _ = self.run_plan(manifest([route("fable"), route("sol", pool="session")], "session"), context(names=("fable", "sol")), outputs={"reader-outside": stream({"7d": window(52, 604800, "2026-11-18T12:00:00Z"), "7d:fable": window(50, 604800, None)})})
        self.assertEqual([(item["launch"]["family"], item["pace"]) for item in result["roles"]["writer"]["candidates"]], [("sol", 0.9375)])

    def test_scopes_are_limited_to_the_bound_pool_and_worst_window(self):
        # Wrong: a scope follows the family across pools, or last scoped window wins.
        config = manifest([route("fable"), route("fable", pool="session")])
        result, _ = self.run_plan(config, context(names=("fable",)), outputs={"reader-outside": stream({"7d": window(52, 604800, "2026-11-18T12:00:00Z"), "5h:fable": window(10, 18000, "2026-11-15T02:30:00Z"), "7d:fable": window(17, 604800, "2026-11-18T12:00:00Z")})})
        self.assertEqual([(item["pool"], item["pace"]) for item in result["roles"]["writer"]["candidates"]], [("session", 0.9375), ("outside", 0.2)])

    def test_scoped_pace_ranking_and_session_comparison(self):
        # Wrong: applying family pace only at sorting, after the session comparison.
        config = manifest([route("fable", pool="session"), route("sol")], "session")
        outputs = {"reader-outside": stream({"7d": window(30, 604800, "2026-11-18T12:00:00Z")}), "reader-session": stream({"7d": window(52, 604800, "2026-11-18T12:00:00Z"), "7d:fable": window(17, 604800, "2026-11-18T12:00:00Z")})}
        result, _ = self.run_plan(config, context(names=("fable", "sol")), outputs=outputs)
        self.assertEqual([item["launch"]["family"] for item in result["roles"]["writer"]["candidates"]], ["sol"])
        self.assertEqual(result["roles"]["writer"]["exclusions"][-1]["reason"], "another fitting pool is ahead of session pace")
        # Scope share below 20% must not consume the session pool's buffer.
        outputs["reader-outside"] = stream({"7d": window(10, 604800, "2026-11-18T12:00:00Z")})
        result, _ = self.run_plan(config, context(names=("fable", "sol")), outputs=outputs)
        self.assertEqual([(item["launch"]["family"], item["pace"]) for item in result["roles"]["writer"]["candidates"]], [("fable", 0.34), ("sol", 0.2)])
        # The same family pace also ranks ordinary non-session candidates.
        config["sessionPool"] = None
        result, _ = self.run_plan(config, context(names=("fable", "sol")), outputs=outputs)
        self.assertEqual(result["roles"]["writer"]["candidates"][0]["pace"], 0.34)

    def test_unknown_scope_warns_without_failing_pool(self):
        # Wrong: silently ignoring a scope, or failing its otherwise valid pool.
        result, _ = self.run_plan(outputs={"reader-outside": stream({"7d": window(17, 604800, "2026-11-18T12:00:00Z"), "7d:unknown-model": window(0, 604800, "2026-11-18T12:00:00Z")})})
        self.assertEqual(result["pools"]["outside"]["status"], "measured")
        self.assertEqual(result["roles"]["writer"]["candidates"][0]["pace"], 0.34)
        self.assertIn("WARNING: outside: scoped window 7d:unknown-model matches no configured family. Report this failure to the user.", result["warnings"])

    def test_unmeasured_streams_and_exhaustion(self):
        # Wrong: first-document-only parse, fabricated weekly resets, or accepting malformed windows.
        cases = [
            (stream() + "garbage", "unreachable", "invalid Reader output"),
            (stream() + "\n" + stream(), "unreachable", "invalid Reader output"),
            (stream({"5h": window(reset=None)}), "unmeasured", "null reset"),
            (stream({"7d:fable": window()}), "unmeasured", "no usable unscoped windows"),
            (stream({"5h": window(reset="2026-11-14T00:00:00Z")}), "unmeasured", "expired reset"),
            (stream({"5h": {"remainingPercent": 50}}), "unmeasured", "windowSeconds"),
            (subprocess.TimeoutExpired("fake", 10), "unreachable", "Reader timed out"),
            (subprocess.CompletedProcess("fake", 7, ""), "unreachable", "Reader exited 7"),
            (stream({"bad": []}), "unmeasured", "window must be an object"),
            ("[]", "unreachable", "invalid Reader output"),
            (stream({"bad": window(float("nan"))}), "unmeasured", "invalid remainingPercent"),
            (stream({"bad": window(reset="2027-01-01T00:00:00Z")}), "unmeasured", "beyond window duration"),
        ]
        for value, status, reason in cases:
            with self.subTest(reason=reason):
                result, _ = self.run_plan(outputs={"reader-outside": value})
                pool = result["pools"]["outside"]
                self.assertEqual(pool["status"], status)
                self.assertIn(reason, pool["reason"] + " ".join(pool.get("windowErrors", {}).values()))
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
                pool = result["pools"]["outside"]
                if field == "status":
                    self.assertEqual(pool["status"], "unmeasured")
                    self.assertIn(reason, pool["windowErrors"]["monthly"])
                else:
                    self.assertEqual(pool, {"reason": "invalid Reader output", "status": "unreachable"})
                    with self.assertRaisesRegex(ValueError, reason):
                        helper.measure(json.dumps(document), NOW)

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
                pool = result["pools"]["outside"]
                if section == "window":
                    self.assertEqual(pool["status"], "unmeasured")
                    self.assertIn(reason, pool["windowErrors"]["monthly"])
                else:
                    self.assertEqual(pool, {"reason": "invalid Reader output", "status": "unreachable"})
                    with self.assertRaisesRegex(ValueError, reason):
                        helper.measure(json.dumps(document), NOW)
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
        self.assertEqual([error["path"] for error in self.request_errors(launch_context=context(), roles=("unknown",))], ["argv.role[0]"])
        result, _ = self.run_plan(launch_context=context(names=()))
        self.assertEqual(len(result["roles"]["writer"]["candidates"]), 1)

    def test_generated_agent_workflow_external_and_unresolved(self):
        agent = {"family": {"defaultEffort": "high", "name": "sol"}, "id": "gpt-6.1-sol"}
        techniques = [technique("Agent with generated agent file", agent=agent), technique("Workflow", "workflow"), technique("claude -p", "external")]
        evidence = [{"efforts": ["high"], "model": "gpt-6.1-sol", "runtime": "claude", "technique": name} for name in ("Agent with generated agent file", "Workflow", "claude -p")]
        config = manifest([route(target="claude", techniques=techniques, default="high")])
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
        self.assertEqual([error["path"] for error in self.request_errors(manifest(session="undeclared"))], ["manifest.sessionPool"])
        self.assertEqual([error["path"] for error in self.request_errors(manifest([route(pool="undeclared")]))], ["manifest.routes[0].pool"])
        ctx = context()
        ctx["techniques"][0]["efforts"] = "high"
        self.assertEqual([error["path"] for error in self.request_errors(launch_context=ctx)], ["launchContext.techniques[0].efforts"])
        with patch.object(helper, "READER_TIMEOUT", 0.02), patch("time.sleep"):
            measured = helper.collect([{"command": "while :; do :; done", "name": "stuck"}], NOW, SHELL)
        self.assertEqual(measured["stuck"]["status"], "unreachable")
        self.assertIn("timed out", measured["stuck"]["reason"])

    def prepared_plan(self, root, count=2):
        # Hand-authored launches: the plan cannot supply its own allowlist.
        rubric = b"1. Scope: change the assigned files.\n2. Checks: reject an invented launch.\n"
        (root / "rubric.md").write_bytes(rubric)
        roles = ("writer", "first-check", "second-check", "judge")
        launches = []
        for role in roles:
            brief = f"{role}.md"
            (root / brief).write_bytes(b"Hard rules and task.\n" + rubric + b"Report evidence.\n")
            launches.append({"brief": brief, "candidate": {"agent": None, "effort": "high", "family": "sol", "guidance": {"command": "MUST NEVER EXECUTE THIS LAUNCH", "modelArg": "slug", "notes": "caller binds task/output paths"}, "model": "gpt-6.1-sol", "runtime": "codex", "technique": "spawn_agent"}, "line": f"role={role} runtime=codex family=sol technique=spawn_agent model=gpt-6.1-sol effort=high", "role": role, "runtime": "codex"})
        units = [{"audience": "routing maintainer", "checks": [f"checks/{index}.py"], "dependencies": [], "docs": [f"docs/{index}.md"], "files": [f"src/{index}.py", f"checks/{index}.py", f"docs/{index}.md"], "goal": "replace not validated launch choices", "id": str(index), "launches": deepcopy(launches), "size": {"code": {"added": 20, "removed": 5}, "docs": {"added": 5, "removed": 0}, "tests": {"added": 30, "removed": 0}}, "verification": {"command": f"python3 checks/{index}.py", "wrongImplementation": "accepts invented launch choices"}} for index in range(count)]
        return {"rubric": "rubric.md", "runtime": "codex", "snapshot": {"automaticRuntimes": ["codex"], "manualOnly": [], "pools": {"outside": {"buffer": 0.5, "pace": 0.9375, "status": "measured"}}, "roles": {record["role"]: {"candidates": [{"launch": record["candidate"], "line": record["line"], "pool": "outside"}], "exclusions": []} for record in launches}, "runtime": "codex", "sessionPool": None, "snapshot": "2026-11-14T00:00:00Z", "warnings": ["session pool unknown; buffer rule cannot be certified"]}, "task": "validate assigned routing work", "units": units, "waves": [[str(index) for index in range(count)]]}

    def test_planner_bootstrap_floor_native_and_workflow(self):
        # Wrong: planner unregistered, high-pace mid chosen, or no pinned bootstrap.
        config = manifest([route("fast", "mid", "session"), route("design", "frontier")])
        for node in (technique(), technique("Workflow", "workflow")):
            config["routes"][1]["techniques"] = [node]
            ctx = context(("planner",), ("design", "fast"), techniques=[{"efforts": ["high"], "model": "gpt-6.1-sol", "runtime": "codex", "technique": node["name"]}], non_interactive=True)
            result, _ = self.run_plan(config, ctx, ("planner",), outputs={"reader-session": stream({"monthly": window(99)})})
            self.assertEqual(result["roles"]["planner"]["candidates"][0]["launch"]["family"], "design")
            self.assertIn({"family": "fast", "reason": "below role tier floor", "runtime": "codex"}, result["roles"]["planner"]["exclusions"])
        config["routes"] = [route("fast", "mid")]
        result, _ = self.run_plan(config, context(("planner",), ("fast",)), ("planner",))
        self.assertEqual(result["roles"]["planner"]["error"], "never step down a tier; report a loop failure.")

    def test_plan_role_qualified_launch_mutations(self):
        # Wrong: transcript substring match, trusting saved candidates, stale context.
        roles = ("writer", "first-check", "second-check", "judge")
        current, _ = self.run_plan(roles=roles)
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            self.assertEqual(helper.check_plan(artifact, current, root), {"status": "valid", "task": "validate assigned routing work", "units": 2, "waves": 1})
            for field, value in (("effort", "low"), ("family", "manual"), ("model", "invented"), ("technique", "absent"), ("model", "gpt-*-sol")):
                with self.subTest(field=field, value=value):
                    changed = deepcopy(artifact)
                    changed["units"][0]["launches"][0]["candidate"][field] = value
                    with self.assertRaisesRegex(ValueError, "absent from current helper output"):
                        helper.check_plan(changed, current, root)
            for field, value, reason in (("line", "role=judge runtime=codex family=sol technique=spawn_agent model=gpt-6.1-sol effort=high", "absent from current"), ("role", "finder", "one worker"), ("runtime", "claude", "own helper validation")):
                changed = deepcopy(artifact)
                changed["units"][0]["launches"][0][field] = value
                with self.assertRaisesRegex(ValueError, reason):
                    helper.check_plan(changed, current, root)
            changed = deepcopy(current)
            changed["roles"]["first-check"]["candidates"] = []
            with self.assertRaisesRegex(ValueError, "first-check candidate/line absent"):
                helper.check_plan(artifact, changed, root)
            changed = deepcopy(artifact)
            changed["runtime"] = "claude"
            with self.assertRaisesRegex(ValueError, "actual launching runtime"):
                helper.check_plan(changed, current, root)
            changed = deepcopy(artifact)
            changed["snapshot"]["runtime"] = "claude"
            with self.assertRaisesRegex(ValueError, "saved helper snapshot"):
                helper.check_plan(changed, current, root)
            # Even a saved allowlist containing a forged model cannot approve it.
            changed = deepcopy(artifact)
            for launch in (changed["units"][0]["launches"][0], changed["snapshot"]["roles"]["writer"]["candidates"][0]):
                candidate = launch.get("candidate", launch.get("launch"))
                candidate["model"] = "invented"
            with self.assertRaisesRegex(ValueError, "absent from current helper output"):
                helper.check_plan(changed, current, root)
            # A new context or budget decision, not the old plan's snapshot, wins.
            for ctx, outputs in ((context(roles, effort="low"), None), (context(roles), {"reader-outside": stream({"monthly": window(0)})})):
                changed, _ = self.run_plan(launch_context=ctx, roles=roles, outputs=outputs)
                with self.assertRaisesRegex(ValueError, "absent from current helper output"):
                    helper.check_plan(artifact, changed, root)
            config = manifest([route(pool=None)])
            config["readers"] = []
            fit_only, _ = self.run_plan(config, roles=roles)
            self.assertEqual(helper.check_plan(artifact, fit_only, root)["status"], "valid")
            self.assertEqual(fit_only["roles"]["writer"]["candidates"][0]["budget"], "fit-only; budget and session buffer unknown")

    def test_plan_rejects_recursive_planner(self):
        # Wrong: a valid planner candidate can recursively plan an approved unit.
        current, _ = self.run_plan(roles=("writer", "first-check", "second-check", "judge", "planner"))
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            launch = deepcopy(artifact["units"][0]["launches"][0])
            launch.update(role="planner", candidate=current["roles"]["planner"]["candidates"][0]["launch"], line=current["roles"]["planner"]["candidates"][0]["line"])
            artifact["units"][0]["launches"].append(launch)
            with self.assertRaisesRegex(ValueError, "only worker and reviewer roles"):
                helper.check_plan(artifact, current, root)

    def test_plan_artifact_paths_stay_relative(self):
        # Wrong: joining an absolute or upward rubric/brief path reads outside.
        current, _ = self.run_plan(roles=("writer", "first-check", "second-check", "judge"))
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            nested = root / "plans"
            nested.mkdir()
            for path in root.glob("*.md"):
                (nested / path.name).write_bytes(path.read_bytes())
            for field, filename in (("rubric", "rubric.md"), ("brief", "writer.md")):
                for path in (str(root / filename), f"../{filename}"):
                    changed = deepcopy(artifact)
                    target = changed if field == "rubric" else changed["units"][0]["launches"][0]
                    target[field] = path
                    with self.subTest(field=field, path=path), self.assertRaisesRegex(ValueError, "plan-relative.*absolute or upward"):
                        helper.check_plan(changed, current, nested)

    def test_plan_artifact_symlinks_stay_inside_directory(self):
        # Wrong: relative symlinks let rubric/brief reads escape the plan directory.
        current, _ = self.run_plan(roles=("writer", "first-check", "second-check", "judge"))
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            nested = root / "plan"
            nested.mkdir()
            artifact = self.prepared_plan(nested)
            for field, filename in (("rubric", "rubric.md"), ("brief", "writer.md")):
                (root / filename).write_bytes((nested / filename).read_bytes())
                (nested / f"link-{filename}").symlink_to(f"../{filename}")
                changed = deepcopy(artifact)
                target = changed if field == "rubric" else changed["units"][0]["launches"][0]
                target[field] = f"link-{filename}"
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, "inside the plan directory"):
                    helper.check_plan(changed, current, nested)

    def test_plan_requires_complete_helper_snapshot(self):
        # Wrong: accepting provenance without the helper's runtime/route warnings.
        current, _ = self.run_plan(roles=("writer", "first-check", "second-check", "judge"))
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            for field in ("automaticRuntimes", "manualOnly", "sessionPool", "warnings"):
                changed = deepcopy(artifact)
                del changed["snapshot"][field]
                with self.subTest(missing=field), self.assertRaisesRegex(ValueError, "complete helper snapshot"):
                    helper.check_plan(changed, current, root)

    def test_plan_snapshot_requires_launched_candidates_and_bound_pools(self):
        # Wrong: empty or partial role/pool maps count as captured helper output.
        current, _ = self.run_plan(roles=("writer", "first-check", "second-check", "judge"))
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            mutations = [
                ("empty pools", lambda snapshot: snapshot.update(pools={})),
                ("empty roles", lambda snapshot: snapshot.update(roles={})),
                ("missing reviewer", lambda snapshot: snapshot["roles"].pop("first-check")),
                ("empty candidates", lambda snapshot: snapshot["roles"]["writer"].update(candidates=[])),
                ("changed candidate", lambda snapshot: snapshot["roles"]["writer"]["candidates"][0]["launch"].update(model="invented")),
                ("missing pool binding", lambda snapshot: snapshot["roles"]["writer"]["candidates"][0].pop("pool")),
                ("absent bound pool", lambda snapshot: snapshot["roles"]["writer"]["candidates"][0].update(pool="missing")),
            ]
            for label, mutate in mutations:
                changed = deepcopy(artifact)
                mutate(changed["snapshot"])
                with self.subTest(mutation=label), self.assertRaisesRegex(ValueError, "saved helper snapshot"):
                    helper.check_plan(changed, current, root)

    def test_plan_dependencies_waves_and_ownership(self):
        # Wrong: cycle acceptance, ordering ignored, runtime cap, forced serialization.
        current, _ = self.run_plan(roles=("writer", "first-check", "second-check", "judge"))
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            cases = []
            changed = deepcopy(artifact)
            changed["units"][0]["dependencies"] = ["missing"]
            cases.append((changed, "unknown dependency"))
            changed = deepcopy(artifact)
            changed["units"][0]["dependencies"] = ["1"]
            changed["units"][1]["dependencies"] = ["0"]
            cases.append((changed, "cycle"))
            changed = deepcopy(artifact)
            changed["units"][1]["dependencies"] = ["0"]
            cases.append((changed, "earlier reviewed/committed wave"))
            changed = deepcopy(artifact)
            changed["units"][1]["files"].append("src/../src/0.py")
            cases.append((changed, "overlapping same-wave writer files"))
            changed = deepcopy(artifact)
            changed["units"][0]["id"] = "1"
            cases.append((changed, "unique"))
            changed = deepcopy(artifact)
            changed["units"][0]["files"].append("../outside.py")
            cases.append((changed, "repository-relative"))
            changed = deepcopy(artifact)
            changed["units"][0]["docs"].append("unowned.md")
            cases.append((changed, "need writer ownership"))
            changed = deepcopy(artifact)
            changed["units"][0]["size"]["code"]["added"] = -1
            cases.append((changed, "nonnegative"))
            changed = deepcopy(artifact)
            changed["units"][0]["verification"]["wrongImplementation"] = ""
            cases.append((changed, "wrongImplementation required"))
            changed = deepcopy(artifact)
            changed["waves"] = [["0"]]
            cases.append((changed, "exactly one wave"))
            changed = deepcopy(artifact)
            changed["waves"] = [["0", "0"], ["1"]]
            cases.append((changed, "exactly one wave"))
            changed = deepcopy(artifact)
            changed["units"][0]["launches"] = changed["units"][0]["launches"][:1]
            cases.append((changed, "review barrier"))
            for changed, reason in cases:
                with self.subTest(reason=reason), self.assertRaisesRegex(ValueError, reason):
                    helper.check_plan(changed, current, root)
            artifact["units"][1]["dependencies"] = ["0"]
            artifact["waves"] = [["0"], ["1"]]
            self.assertEqual(helper.check_plan(artifact, current, root, 4)["waves"], 2)
            # Wrong: sequential worker/review launches consume separate wave slots.
            ten_units = self.prepared_plan(root, 10)
            self.assertEqual(helper.check_plan(ten_units, current, root), {"status": "valid", "task": "validate assigned routing work", "units": 10, "waves": 1})
            with self.assertRaisesRegex(ValueError, "1..9 concurrent units"):
                helper.check_plan(ten_units, current, root, 9)
            with self.assertRaisesRegex(ValueError, "1..10 concurrent units"):
                helper.check_plan(self.prepared_plan(root, 11), current, root)
            with self.assertRaisesRegex(ValueError, "1..1 concurrent units"):
                helper.check_plan(self.prepared_plan(root), current, root, 1)

    def test_prepared_brief_rubric_bytes(self):
        # Wrong: rubric paths/summary/one mutated row accepted as full rubric.
        current, _ = self.run_plan(roles=("writer", "first-check", "second-check", "judge"))
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            for role in ("writer", "first-check", "second-check", "judge"):
                brief = root / f"{role}.md"
                original = brief.read_bytes()
                for replacement in (b"See rubric.md", b"1. Scope: change the assigned files.\n", original.replace(b"invented", b"supported")):
                    brief.write_bytes(replacement)
                    with self.subTest(role=role), self.assertRaisesRegex(ValueError, "full rubric verbatim"):
                        helper.check_plan(artifact, current, root)
                brief.write_bytes(original)
            self.assertEqual(helper.check_plan(artifact, current, root)["status"], "valid")

    def test_check_plan_cli_uses_current_readers_and_briefs(self):
        # Wrong: check-plan bypasses the production Reader/CLI path or launches.
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            config = manifest()
            log = root / "reads"
            config["readers"] = [{"command": f"printf 'outside\\n' >> '{log}'; printf '%s' '{stream()}'", "name": "outside"}]
            roles = ("writer", "first-check", "second-check", "judge")
            for name, value in (("plan", artifact), ("manifest", config), ("context", context(roles))):
                (root / f"{name}.json").write_text(json.dumps(value))
            command = [sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--reader-shell", SHELL, "--launch-context", str(root / "context.json"), "--check-plan", str(root / "plan.json"), "--now", "2026-11-15T00:00:00Z"]
            for role in roles:
                command.extend(["--role", role])
            # Wrong: refusing invalid caps only after reading inputs and Readers.
            for cap in (0, 11):
                with self.subTest(cap=cap):
                    proc = subprocess.run(command + ["--max-concurrency", str(cap)], capture_output=True, text=True)
                    self.assertEqual(proc.returncode, 2)
                    self.assertIn("delegate-routing-plan: argv: argument --max-concurrency: invalid choice", proc.stderr)
                    self.assertEqual(json.loads(proc.stdout)["errors"][0]["path"], "argv")
                    self.assertFalse(log.exists())
            command.extend(["--max-concurrency", "2"])
            proc = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(json.loads(proc.stdout)["validation"]["status"], "valid")
            self.assertEqual(log.read_text(), "outside\n")
            (root / "writer.md").write_text("summary only")
            proc = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2)
            self.assertIn("full rubric verbatim", proc.stderr)
            self.assertEqual(proc.stdout, "")
            self.assertEqual(log.read_text(), "outside\noutside\n")

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
            ctx = context()
            ctx["roles"]["writer"]["exclude"] = ["sol"]
            (root / "context.json").write_text(json.dumps(ctx))
            proc = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 1)
            self.assertIn("never step down a tier; report a loop failure.", proc.stderr)


if __name__ == "__main__":
    unittest.main()
