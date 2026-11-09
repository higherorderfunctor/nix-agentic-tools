"""Offline, literal routing expectations: no catalogs, live readers or launches."""
from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
import importlib.util
import io
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import call, patch

SOURCE = Path(sys.argv.pop(1)).resolve()
FIXTURE = Path(sys.argv.pop(1)).resolve()
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


def route(name="sol", tier="strong", pool="outside", target="codex", techniques=None, default=None):
    return {"family": {"avoidFor": "sole judge", "defaultEffort": default, "effort": "prose is not an effort enum", "name": name, "tier": tier, "useFor": "writer-judge loop", "vendor": "provider"}, "pool": pool, "target": target, "techniques": techniques or [technique()]}


def manifest(routes=None, session=None):
    return {"familyNames": [r["family"]["name"] for r in (routes or [route()])] + ["manual", "dormant"], "effortLevels": ["minimal", "low", "medium", "high", "xhigh", "max"], "manualRoutes": [route("manual", pool=None)], "readers": [{"command": "reader-outside", "name": "outside"}, {"command": "reader-session", "name": "session"}, {"command": "reader-hidden-runtime", "name": "hidden"}], "routes": routes or [route()], "runtime": "codex", "runtimes": ["codex"], "sessionPool": session}


def context(roles=("writer",), names=("sol",), techniques=None, non_interactive=False, effort="high"):
    return {"nonInteractive": non_interactive, "roles": {role: {"effort": effort, "families": {name: QUALIFIED for name in names}} for role in roles}, "techniques": techniques or [{"efforts": ["high"], "model": "gpt-6.1-sol", "runtime": "codex", "technique": "spawn_agent"}]}


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
            config = config or manifest()
            pools = helper.collect(config["readers"], now, SHELL, reader)
            result = helper.plan(config, launch_context or context(roles), roles, now, pools)
        return result, calls

    def run_cli(self, extra=(), config=None, ctx=None, reader_value=None, raw_files=None):
        files = {"manifest.json": json.dumps(config if config is not None else manifest()), "context.json": json.dumps(ctx if ctx is not None else context()), "plan.json": "{", "bad-plan.json": "{}"}
        files.update(raw_files or {})
        argv = ["helper", "--manifest", "manifest.json", "--reader-shell", SHELL, "--launch-context", "context.json", "--role", "writer", "--now", "2026-11-15T00:00:00Z"]
        out, err = io.StringIO(), io.StringIO()
        def reader(args, **kwargs):
            if args[0] in ("", "/no/such/shell"):
                raise OSError("private shell failure")
            return reader_value or subprocess.CompletedProcess([], 0, stream())
        with patch.object(sys, "argv", argv + list(extra)), patch.object(Path, "read_text", lambda path: files[path.name]), patch.object(helper, "run_reader", side_effect=reader) as reads, patch("time.sleep"), redirect_stdout(out), redirect_stderr(err):
            code = helper.main()
        return code, json.loads(out.getvalue()), err.getvalue(), reads.call_args_list

    def test_cli_collects_before_request_failures(self):
        # Wrong: request parsing/context/plan validation discards the Reader snapshot.
        config = manifest()
        config["readers"].append({"command": "reader-outside", "name": "alias"})
        cases = [
            (["--max-concurrency", "0"], None, "argument --max-concurrency: invalid choice:"),
            (["--max-concurrency"], None, "expected one argument"),
            (["--unknown"], None, "unrecognized arguments: --unknown"),
            (["--role", "unknown"], None, "invalid choice: 'unknown'"),
            ([], [], "'list' object has no attribute 'get'"),
            ([], {"roles": {}}, "launch context requires techniques and roles"),
            (["--check-plan", "plan.json"], None, "Expecting property name"),
            (["--check-plan", "bad-plan.json"], None, "plan requires task identity"),
        ]
        expected_pool = {"buffer": 0.5, "pace": 0.9375, "status": "measured"}
        for extra, ctx, error in cases:
            with self.subTest(extra=extra, ctx=ctx):
                code, result, stderr, reads = self.run_cli(extra, config, ctx)
                self.assertEqual(code, 2)
                self.assertEqual({key: result[key] for key in ("inventory", "snapshot", "status")}, {"inventory": "available", "snapshot": "2026-11-15T00:00:00+00:00", "status": "error"})
                self.assertEqual(result["pools"], {"alias": expected_pool, "hidden": expected_pool, "outside": expected_pool, "session": expected_pool})
                self.assertEqual(len(result["errors"]), 1)
                self.assertIn(error, result["errors"][0])
                self.assertEqual([read.args[0][4].split("\n", 1)[1] for read in reads], ["reader-outside", "reader-session", "reader-hidden-runtime"])
                self.assertNotIn("pool=", stderr)

    def test_cli_malformed_json_keeps_recoverable_envelope(self):
        # Wrong: malformed manifest/context JSON exits through argparse without JSON.
        for files, inventory, count in [
            ({"manifest.json": "{"}, "inventory-unavailable", 0),
            ({"context.json": "{"}, "available", 3),
        ]:
            with self.subTest(files=files):
                code, result, stderr, reads = self.run_cli(raw_files=files)
                self.assertEqual(code, 2)
                self.assertEqual(result["inventory"], inventory)
                self.assertEqual(result["status"], "error")
                self.assertEqual(result["roles"], {})
                self.assertEqual(result["snapshot"], "2026-11-15T00:00:00+00:00")
                self.assertEqual(len(reads), count)
                self.assertIn("Expecting property name", result["errors"][0])
                if count == 0:
                    self.assertEqual(result["pools"], {})

    def test_cli_unavailable_inventory_has_literal_failure_shape(self):
        # Wrong: bad/missing inventory claims an observed pool set or omits JSON.
        for extra, config, error in [
            (["--manifest"], None, "inventory-unavailable: manifest path could not be recovered"),
            ([], {"readers": "bad"}, "inventory-unavailable: readers require names and command strings/null"),
            ([], {"readers": [{"name": "same", "command": None}, {"name": "same", "command": None}]}, "inventory-unavailable: Reader registration names must be unique"),
        ]:
            with self.subTest(extra=extra, config=config):
                code, result, stderr, reads = self.run_cli(extra, config)
                self.assertEqual(code, 2)
                self.assertEqual(result, {"errors": [error], "inventory": "inventory-unavailable", "pools": {}, "roles": {}, "snapshot": "2026-11-15T00:00:00+00:00", "status": "error", "warnings": []})
                self.assertEqual(reads, [])
                self.assertEqual(stderr, f"delegate-routing-plan: {error}\n")

    def test_cli_shell_failure_is_per_reader_and_role_errors_are_named(self):
        # Wrong: shell refusal turns unreachable Readers into unmeasured fit-only routes.
        for extra, expected_code, expected_reads in [
            (["--reader-shell", "/no/such/shell"], 1, 3),
            (["--reader-shell"], 2, 3),
        ]:
            with self.subTest(extra=extra):
                code, result, stderr, reads = self.run_cli(extra)
                self.assertEqual(code, expected_code)
                self.assertEqual(len(reads), expected_reads)
                failed = {"reason": "Reader could not execute", "status": "unreachable"}
                self.assertEqual(result["pools"], {"hidden": failed, "outside": failed, "session": failed})
                self.assertEqual(result["inventory"], "available")
                self.assertEqual(result["status"], "error")
                self.assertEqual([w for w in result["warnings"] if w.startswith("WARNING:")], ["WARNING: Reader for hidden failed: Reader could not execute. Report this failure to the user.", "WARNING: Reader for outside failed: Reader could not execute. Report this failure to the user.", "WARNING: Reader for session failed: Reader could not execute. Report this failure to the user."])
                if expected_code == 1:
                    self.assertEqual(result["errors"], ["writer: never step down a tier; report a loop failure."])
                    self.assertEqual(result["roles"]["writer"]["candidates"], [])
                self.assertNotIn("pool=", stderr)
                self.assertNotIn("private shell failure", stderr)

    def test_cli_failure_warnings_survive_request_error(self):
        # Wrong: collect succeeds but malformed context loses failed-Reader warnings.
        code, result, stderr, reads = self.run_cli(ctx=[], reader_value=subprocess.CompletedProcess([], 7, "", "private Reader stderr"))
        self.assertEqual(code, 2)
        self.assertEqual(len(reads), 6)
        self.assertEqual(result["warnings"], ["WARNING: Reader for hidden failed: Reader exited 7. Report this failure to the user.", "WARNING: Reader for outside failed: Reader exited 7. Report this failure to the user.", "WARNING: Reader for session failed: Reader exited 7. Report this failure to the user."])
        self.assertEqual(stderr, "WARNING: Reader for hidden failed: Reader exited 7. Report this failure to the user.\nWARNING: Reader for outside failed: Reader exited 7. Report this failure to the user.\nWARNING: Reader for session failed: Reader exited 7. Report this failure to the user.\ndelegate-routing-plan: 'list' object has no attribute 'get'\n")

    def test_cli_invalid_time_collects_with_recovery_clock(self):
        # Wrong: a bad --now value skips collection or appears as a valid snapshot.
        code, result, stderr, reads = self.run_cli(["--now", "bad"])
        self.assertEqual(code, 2)
        self.assertEqual(len(reads), 3)
        self.assertEqual(result["inventory"], "available")
        self.assertEqual(result["status"], "error")
        self.assertIn("Invalid isoformat string", result["errors"][0])
        self.assertIsNotNone(helper.utc(result["snapshot"]))

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
                        with self.assertRaisesRegex(ValueError, field):
                            self.run_plan(config, ctx, (role,))
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
        for default, override, supported in [(None, None, ["high"]), ("medium", None, ["high"]), ("high", "low", ["high", "max"]), ("ultra", None, ["ultra"]), ("high", "ultra", ["ultra"])]:
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
        for default, override in [("high", None), (None, "max"), ("high", "ultra")]:
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
        # Wrong: fallback bypasses floors, fit, headless, failed/scoped/buffer gates.
        for role in helper.ROLE_TIERS:
            for gate in ("floor", "fit", "headless", "unreachable", "exhausted", "scoped", "buffer"):
                config = manifest([route()], "outside" if gate == "buffer" else None)
                ctx = context((role,))
                ctx["roles"][role]["avoid"] = ["sol"]
                outputs = {}
                if gate == "floor":
                    config["routes"][0]["family"]["tier"] = "invalid"
                elif gate == "fit":
                    ctx["roles"][role]["families"] = {}
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
        self.assertEqual([w for w in result["warnings"] if w.startswith("WARNING:")], ["WARNING: outside: window 5h pace dropped: invalid windowSeconds. Report this failure to the user."])

    def test_window_warning_cannot_forge_stderr_lines(self):
        # Wrong: Reader-controlled window names inject extra stderr lines.
        result, _ = self.run_plan(outputs={"reader-outside": stream({"5h\nFORGED\x1b": window(50, 0, None)})})
        warnings = [w for w in result["warnings"] if w.startswith("WARNING:")]
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
            self.assertIn("provider-vendor identity is provisional; fit/trial/maker independence are caller assessments", result["warnings"])
            self.assertEqual(proc.stderr.splitlines(), [item["line"] for item in result["roles"]["writer"]["candidates"]])

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
        with self.assertRaisesRegex(ValueError, "unknown role"):
            self.run_plan(roles=("unknown",))
        result, _ = self.run_plan(launch_context=context(names=()))
        self.assertEqual(result["roles"]["writer"]["candidates"], [])

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
            launches.append({"brief": brief, "candidate": {"agent": None, "effort": "high", "family": "sol", "guidance": {"command": "MUST NEVER EXECUTE THIS LAUNCH", "modelArg": "slug", "notes": "caller binds task/output paths"}, "model": "gpt-6.1-sol", "qualification": QUALIFIED, "runtime": "codex", "technique": "spawn_agent"}, "line": f"role={role} runtime=codex family=sol technique=spawn_agent model=gpt-6.1-sol effort=high", "role": role, "runtime": "codex"})
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
            # Wrong: invalid caps skip Readers or discard the failure envelope.
            for cap in (0, 11):
                with self.subTest(cap=cap):
                    proc = subprocess.run(command + ["--max-concurrency", str(cap)], capture_output=True, text=True)
                    self.assertEqual(proc.returncode, 2)
                    self.assertIn("argument --max-concurrency: invalid choice", proc.stderr)
                    self.assertEqual(json.loads(proc.stdout)["status"], "error")
                    self.assertEqual(json.loads(proc.stdout)["pools"], {"outside": {"buffer": 0.5, "pace": 0.9375, "status": "measured"}})
                    log.unlink()
            command.extend(["--max-concurrency", "2"])
            proc = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(json.loads(proc.stdout)["validation"]["status"], "valid")
            self.assertEqual(log.read_text(), "outside\n")
            (root / "writer.md").write_text("summary only")
            proc = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2)
            self.assertIn("full rubric verbatim", proc.stderr)
            self.assertEqual(json.loads(proc.stdout)["errors"], ["0: writer brief must contain the full rubric verbatim"])
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
            (root / "context.json").write_text(json.dumps(context(names=())))
            proc = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 1)
            self.assertIn("never step down a tier; report a loop failure.", proc.stderr)


if __name__ == "__main__":
    unittest.main()
