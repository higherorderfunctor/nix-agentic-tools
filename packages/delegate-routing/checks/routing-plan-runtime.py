"""Offline, literal routing expectations: no catalogs, live readers or launches."""
from copy import deepcopy
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
            self.run_plan(roles=("unknown",))
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
            # Wrong: refusing invalid caps only after reading inputs and Readers.
            for cap in (0, 11):
                with self.subTest(cap=cap):
                    proc = subprocess.run(command + ["--max-concurrency", str(cap)], capture_output=True, text=True)
                    self.assertEqual(proc.returncode, 2)
                    self.assertIn("argument --max-concurrency: invalid choice", proc.stderr)
                    self.assertEqual(proc.stdout, "")
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
            (root / "context.json").write_text(json.dumps(context(names=())))
            proc = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 1)
            self.assertIn("never step down a tier; report a loop failure.", proc.stderr)


if __name__ == "__main__":
    unittest.main()
