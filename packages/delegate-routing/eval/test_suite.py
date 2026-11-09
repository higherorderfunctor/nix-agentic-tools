#!/usr/bin/env python3
"""Offline regressions for source attribution and the captured CLI schemas."""

from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

import suite

# The Nix build sandbox has no /usr/bin/env: name the bash on PATH.
STRICT_BASH = f"#!{shutil.which('bash')}\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n"


class HelperFixtures(unittest.TestCase):
    def test_helper_command_from_directory_skill(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            skill = root / ".agents/skills/delegate-routing/SKILL.md"
            skill.parent.mkdir(parents=True)
            skill.write_text("`/nix/store/fixture-routing-helper/bin/delegate-routing-plan --role <role> --launch-context <json-path>`\n")
            self.assertEqual(suite.helper_command({"runtime": "codex"}, root),
                             "/nix/store/fixture-routing-helper/bin/delegate-routing-plan")

    def test_prompt_modes(self):
        legacy = {"task": "implement a function", "usage": {"synthetic": True}}
        self.assertIn("do not run a usage helper", suite.helper_prompt(legacy))
        prompt = suite.helper_prompt({**legacy, "helperBacked": True})
        self.assertNotIn("do not run", prompt)
        self.assertNotIn("synthetic", prompt)
        self.assertIn("registered Readers", prompt)

    def test_real_helper_and_reader_receipts(self):
        # No harness: execute the same helper source through a packaged-shaped
        # command, with real child Reader processes and literal expectations.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "logs"
            logs.mkdir()
            reader = root / "reader"
            reader.write_text(f"#!{sys.executable}\n" +
                "from datetime import datetime, timedelta, timezone\nimport json, os, sys\n" +
                "name, remaining = sys.argv[1], int(sys.argv[2])\n" +
                "with open(os.environ['ROUTING_EVAL_RECEIPTS'], 'a') as output:\n" +
                "    output.write(json.dumps({'reader': name}) + '\\n')\n" +
                "print(json.dumps({'account': {'auth_index': None, 'name': 'fixture', 'plan': None}, 'balances': [], 'bonuses': [], 'pool': 'wrong-key', 'windows': {'5h': {'remainingPercent': remaining, 'usedPercent': 100 - remaining, 'status': 'ok', " +
                "'resetsAt': (datetime.now(timezone.utc) + timedelta(seconds=9000)).isoformat(), 'windowSeconds': 18000}}}))\n")
            reader.chmod(0o755)
            routes = [{"family": {"cost": 3, "maker": "fixture-" + name, "name": name, "tier": tier}, "pool": pool, "target": "codex",
                       "techniques": [{"agent": None, "model": {"isPattern": False, "value": "gpt-6.1-sol"},
                                       "name": "spawn_agent", "node": {"command": None, "kind": "subagent", "modelArg": "slug", "notes": "native fixture"}}]}
                      for name, tier, pool in [("outside", "strong", "outside"), ("session", "strong", "session"), ("under-tier", "mid", "outside")]]
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"runtime": "codex", "runtimes": ["codex"], "sessionPool": "session",
                "manualRoutes": [], "routes": routes, "readers": [
                    {"name": name, "command": shlex.join([str(reader), name, str(remaining)])}
                    for name, remaining in [("cross-runtime", 90), ("outside", 80), ("session", 30)]]}))
            wrapper = root / "delegate-routing-plan"
            wrapper.write_text(STRICT_BASH + "exec " + shlex.join([sys.executable,
                os.environ.get("ROUTING_PLAN_SOURCE", str(suite.HERE.parent / "scripts/delegate-routing-plan.py")), "--manifest", str(manifest),
                "--reader-shell", shutil.which("bash")]) + ' "$@"\n')
            wrapper.chmod(0o755)
            with patch.object(suite, "helper_command", return_value=str(wrapper)):
                suite.exercise_helper({"id": "codex-helper-independent-wave", "runtime": "codex"}, root, logs)
            record = json.loads((logs / "setup-helper.json").read_text())
            receipts = suite.helper_receipts(logs / "setup-reader-receipts.jsonl")
            self.assertEqual(record["exitCode"], 0)
            self.assertEqual(len(receipts), 6)
            validation = json.loads((logs / "setup-plan-validation.json").read_text())
            self.assertEqual(validation["output"]["validation"]["waves"], 1)
            self.assertFalse((logs / "session-reader-receipts.jsonl").exists())
            # These mutations reproduce inventory filtering, session-first ranking
            # and a tier filter silently omitted from the helper implementation.
            with self.assertRaisesRegex(ValueError, "every registered"):
                suite.check_helper_evidence(record["output"], [row for row in receipts if row["reader"] != "cross-runtime"])
            broken = deepcopy(record["output"])
            broken["roles"]["writer"]["candidates"][0]["pool"] = "session"
            with self.assertRaisesRegex(ValueError, "outside pool"):
                suite.check_helper_evidence(broken, receipts)
            # Wrong: a different-maker session reviewer disappears (for example,
            # treating the session pool as ineligible for every review).
            broken = deepcopy(record["output"])
            broken["roles"]["first-check"]["candidates"] = []
            with self.assertRaisesRegex(ValueError, "different-maker session reviewer"):
                suite.check_helper_evidence(broken, receipts)
            # Wrong: same-maker filtering stops recording the writer's outside
            # family exclusion, even though a different-maker candidate remains.
            broken = deepcopy(record["output"])
            broken["roles"]["first-check"]["exclusions"] = [row for row in broken["roles"]["first-check"]["exclusions"] if row["family"] != "outside"]
            with self.assertRaisesRegex(ValueError, "same-maker outside reviewer"):
                suite.check_helper_evidence(broken, receipts)
            broken = deepcopy(record["output"])
            broken["roles"]["first-check"]["exclusions"] = [row for row in broken["roles"]["first-check"]["exclusions"] if row["family"] != "under-tier"]
            with self.assertRaisesRegex(ValueError, "mid-tier reviewer"):
                suite.check_helper_evidence(broken, receipts)


class SourceAttribution(unittest.TestCase):
    def test_claude_collision_and_personal_skill(self):
        init = {"type": "system", "subtype": "init", "skills": ["code-review", "delegate-routing"]}
        debug = ("Loaded 1 unique skills (1 unconditional, 0 conditional, managed: 0, user: 0, project: 1, additional: 0, legacy commands: 0)\n"
                 "getSkills returning: 1 skill dir commands, 0 plugin skills, 1 bundled skills, 0 builtin plugin skills")
        delivered = {"delegate-routing"}
        bundled = suite.claude_bundled(init, delivered, debug)
        self.assertEqual(bundled, {"code-review"})
        self.assertEqual(suite.claude_leaks(init, delivered, bundled, {"code-review"}, set()), [])
        # The vendor catalog is independent of the synthetic leaking event.
        leaked = {**init, "skills": [*init["skills"], "personal-review"]}
        self.assertEqual(suite.claude_leaks(leaked, delivered, bundled, {"personal-review"}, set()),
                         ["personal skill 'personal-review' in the startup record"])
        with self.assertRaisesRegex(ValueError, "non-fixture"):
            suite.claude_bundled(leaked, delivered, debug.replace("user: 0", "user: 1"))
        with self.assertRaisesRegex(ValueError, "unavailable"):
            suite.claude_bundled(init, delivered, "")

    def test_claude_foreign_plugins_mcp_and_agents(self):
        init = {"plugins": [{"name": "vendor", "path": "builtin", "source": "vendor@builtin"}],
                "mcp_servers": [{"name": "fixture", "source": "project"}], "agents": ["Explore", "fixture"]}
        self.assertEqual(suite.claude_leaks(init, set(), set(), set(), {"Explore", "fixture"}), [])
        init["plugins"][0]["path"] = "/personal/plugin"
        init["mcp_servers"][0]["source"] = "user"
        init["agents"].append("personal")
        self.assertEqual(len(suite.claude_leaks(init, set(), set(), set(), {"Explore", "fixture"})), 3)

    def test_codex_collision_and_personal_skill(self):
        catalog = ("<skills_instructions>\n- `r0` = `/scratch/home/.codex/skills/.system`\n"
                   "- `r1` = `/operator/.claude/skills`\n"
                   "- skill-creator: System skill. (file: r0/skill-creator/SKILL.md)\n"
                   "- personal-review: User skill. (file: r1/personal-review/SKILL.md)\n</skills_instructions>")
        init = [{"type": "message", "content": [{"type": "input_text", "text": catalog}]}]
        with patch.object(suite, "REAL_HOME", Path("/operator")):
            sources = list(suite.codex_sources(json.dumps(init)))
            self.assertEqual([name for name, path in sources if suite.personal_source(path)], ["personal-review"])
            self.assertTrue(suite.personal_source("/operator/.codex/config.toml"))
            self.assertFalse(suite.personal_source("/scratch/home/.codex/config.toml"))
            mcp = {"mcp_servers": [{"name": "fixture", "config_path": "/scratch/repo/.codex/config.toml"},
                                   {"name": "personal", "source": {"path": "/operator/.codex/config.toml"}}]}
            self.assertEqual([name for name, path in suite.codex_sources(json.dumps(mcp)) if suite.personal_source(path)], ["skill/MCP entry"])

    def test_personal_symlink_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            personal = root / ".claude/skills/review/SKILL.md"
            personal.parent.mkdir(parents=True)
            personal.touch()
            link = root / "fixture.md"
            link.symlink_to(personal)
            with patch.object(suite, "REAL_HOME", root):
                self.assertTrue(suite.personal_source(str(link)))


class CliRecords(unittest.TestCase):
    def test_codex_native_calls_from_root_only(self):
        case = {"runtime": "codex", "techniques": {"codex": {"spawn_agent": "subagent"}}}
        events = [{"type": "thread.started", "thread_id": "root"}, {"type": "item.started", "item": {
            "type": "collab_tool_call", "id": "stream", "tool": "spawn_agent"}}]
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            (logs / "sessions").mkdir()
            for identity in ("child", "root"):
                records = [{"type": "session_meta", "payload": {"id": identity}},
                           {"type": "response_item", "payload": {"type": "function_call", "call_id": identity, "name": "spawn_agent"}}]
                (logs / "sessions" / (identity + ".jsonl")).write_text("\n".join(map(json.dumps, records)))
            self.assertEqual(suite.session_calls(case, events, logs), [{"id": "root", "name": "spawn_agent", "input": {}}])

    def test_workflow_precedes_source_access(self):
        # Match Claude's production assistant tool-use blocks, including child IDs.
        case = {"runtime": "claude", "techniques": {"claude": {"Agent": "subagent", "Workflow": "workflow"}},
                "files": [{"path": ".claude/agents/opus.md"}, {"path": ".claude/skills/delegate-routing/SKILL.md"}],
                "usageCommands": ["/nix/store/fixture/bin/claude-usage", "/nix/store/fixture/bin/zai-usage claude"]}
        call_id = 0
        def event(name, value, child=False):
            nonlocal call_id
            call_id += 1
            return {"type": "assistant", "parent_tool_use_id": "parent" if child else None,
                    "message": {"content": [{"type": "tool_use", "id": str(call_id), "name": name, "input": value}]}}
        guidance = event("Read", {"file_path": "/fixture/.claude/skills/delegate-routing/SKILL.md"})
        workflow = event("Workflow", {"code": "agent('Read task_source.py and design the setting')"})
        for prefix, expected in [
            ([guidance], True),
            ([event("Read", {"file_path": "/fixture/.claude/agents/opus.md"})], True),
            ([event("Skill", {"skill": "delegate-routing"})], True),
            ([event("Skill", {"skill": "delegate-routing"}),
              *[event("Bash", {"command": command}) for command in case["usageCommands"]]], True),
            ([event("Bash", {"command": case["usageCommands"][0] + "; cat task_source.py"})], False),
            ([event("Bash", {"command": "cat task_source.py # " + case["usageCommands"][0]})], False),
            ([event("Bash", {"command": "/unlisted/usage-reader"})], False),
            ([event("Skill", {"skill": "unrelated"})], False),
            ([event("TodoWrite", {"todos": []})], True),
            ([event("TodoRead", {})], True),
            ([event("TaskCreate", {"subject": "Design setting", "description": "Plan the handoff"})], True),
            ([event("TaskGet", {"taskId": "1"})], True),
            ([event("TaskList", {})], True),
            ([event("TaskUpdate", {"taskId": "1", "status": "in_progress"})], True),
            ([event("TodoWrite", {"todos": []}), event("Read", {"file_path": "task_source.py"})], False),
            ([event("Read", {"file_path": "/fixture/task_source.py"})], False),
            ([event("Bash", {"command": "cat task_source.py"})], False),
            ([event("Grep", {"pattern": ".", "path": "."})], False),
            ([event("Agent", {"prompt": "design the setting"})], False),
        ]:
            with self.subTest(prefix=prefix):
                events = prefix + [workflow, event("Read", {"file_path": "task_source.py"})]
                raw = suite.session_calls(case, events, Path("/unused"))
                self.assertEqual(suite.ASSERTIONS["workflow-before-source"][1](suite.classify(case, raw), raw, case), expected)
        child = event("Read", {"file_path": "task_source.py"}, child=True)
        raw = suite.session_calls(case, [guidance, child, workflow], Path("/unused"))
        self.assertTrue(suite.workflow_before_source(suite.classify(case, raw), raw, case))
        self.assertFalse(suite.workflow_before_source([], [], case))

    def test_settled_session_cleanup_is_not_a_wall_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            script = 'import time; print(\'{"type":"agent_settled"}\', flush=True); time.sleep(10)'
            with patch.object(suite, "KILL_GRACE_SECONDS", 0.1), patch.object(suite, "WALL_SECONDS", 2):
                code, stop, cleanup = suite.launch([sys.executable, "-c", script], os.environ, logs, logs, None,
                                                 suite.HARNESSES["kimchi"]["finished"])
            self.assertLess(code, 0)
            self.assertEqual(stop, [])
            self.assertEqual(len(cleanup), 1)

    def test_kiro_workspace_catalog_tools_and_completion(self):
        skill = {"name": "delegate-routing", "_meta": {"kiro": {"type": "skill", "resource": {
            "source": {"origin": "workspace", "root": "/fixture"}}}}}
        events = [
            {"type": "sessionUpdate", "data": {"update": {"sessionUpdate": "available_commands_update", "availableCommands": [skill]}}},
            {"type": "sessionUpdate", "data": {"update": {"sessionUpdate": "tool_call", "toolCallId": "one", "title": "Delegate",
                "rawInput": {}, "_meta": {"kiro": {"toolId": "use_subagent"}}}}},
            {"type": "runFinished", "data": {"status": "success", "stopReason": "end_turn"}},
        ]
        harness = suite.HARNESSES["kiro"]
        self.assertEqual(suite.skill_delivery({"runtime": "kiro"}, {"repo": Path("/fixture")}, events, None), "loaded")
        self.assertEqual(suite.skill_delivery({"runtime": "kiro"}, {"repo": Path("/other")}, events, None), "missing")
        self.assertTrue(harness["answered"](events))
        self.assertTrue(harness["turns"](events[1]))
        self.assertEqual(len(harness["calls"](events[1])), 1)
        self.assertIn("use_subagent", harness["calls"](events[1])[0]["name"])


class WorkflowFixture(unittest.TestCase):
    def test_kiro_global_prerequisite_follows_effective_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            real = root / "operator"
            source = real / ".kiro/settings/cli.json"
            suite.write_json(source, {"chat.enableWorkflows": False, "chat.enableTangentMode": True})
            original = source.read_bytes()
            for enabled in (False, True):
                ctx = {"home": root / str(enabled), "repo": root / "repo", "logs": root / "logs",
                       "hook": root / "hook", "exe": "kiro-cli", "prompt": "test", "baseline_argv": [],
                       "case": {"techniques": {"kiro": {"run_workflow": "workflow"} if enabled else {}}}}
                with patch.object(suite, "REAL_HOME", real):
                    suite.kiro_setup(ctx)
                written = suite.read_json(ctx["home"] / ".kiro/settings/cli.json", {})
                self.assertEqual(written["chat.enableWorkflows"], enabled)
                self.assertTrue(written["chat.enableTangentMode"])
                self.assertEqual(source.read_bytes(), original)


class Selection(unittest.TestCase):
    CASES = [{"id": name, "runtime": runtime, "expect": "one-delegate", "task": "t", "usage": {},
              "techniques": {runtime: {"Agent": "subagent"}},
              "files": [{"path": suite.HARNESSES[runtime]["skill"], "text": "x"}]}
             for name, runtime in (("codex-single", "codex"), ("kimchi-dependent", "kimchi"), ("kimchi-single", "kimchi"))]

    def test_exact_prefix_and_union(self):
        ids = [case["id"] for case in self.CASES]
        self.assertEqual(suite.select(ids, []), ids)
        self.assertEqual(suite.select(ids, ["kimchi-single"]), ["kimchi-single"])
        self.assertEqual(suite.select(ids, ["kimchi*"]), ["kimchi-dependent", "kimchi-single"])
        self.assertEqual(suite.select(ids, ["codex-single,kimchi-s*"]), ["codex-single", "kimchi-single"])
        self.assertEqual(suite.select(ids, ["codex-single", "kimchi-single"]), ["codex-single", "kimchi-single"])
        # A prefix needs the star; a bare prefix is an unknown id.
        with self.assertRaisesRegex(ValueError, "matched nothing: kimchi"):
            suite.select(ids, ["kimchi"])

    def run_main(self, *argv):
        with tempfile.TemporaryDirectory() as directory:
            fixtures = Path(directory) / "cases.json"
            fixtures.write_text(json.dumps(self.CASES))
            out = io.StringIO()
            with patch.object(sys, "argv", ["suite.py", "--fixtures", str(fixtures), *argv]), redirect_stdout(out):
                code = suite.main()
            # --list starts nothing and writes no run directory.
            self.assertEqual(list(Path(directory).iterdir()), [fixtures])
        return code, out.getvalue()

    def test_list_and_only(self):
        code, out = self.run_main("--list")
        self.assertEqual(code, 0)
        self.assertEqual([line.split("\t")[0] for line in out.splitlines()], [case["id"] for case in self.CASES])
        code, out = self.run_main("--list", "--only=kimchi*")
        self.assertEqual(out.splitlines(), ["kimchi-dependent\tkimchi\tone-delegate", "kimchi-single\tkimchi\tone-delegate"])
        with self.assertRaisesRegex(ValueError, "matched nothing"):
            self.run_main("--list", "--only=nope*")


class KimchiLaunch(unittest.TestCase):
    def test_task_follows_double_dash(self):
        # pi reads `--auto <text>` as a flag value: without `--` the task is
        # swallowed, Kimchi prints only its session header and exits 0.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ctx = {"case": {"id": "kimchi-single"}, "exe": "kimchi", "home": root / "home", "prompt": "the task",
                   "baseline_argv": ["--model", "kimi-k3", "--thinking", "medium"]}
            with patch.object(suite, "REAL_HOME", root / "real"):
                argv = suite.kimchi_setup(ctx)["argv"]
            self.assertEqual(argv[-2:], ["--", "the task"])
            self.assertLess(argv.index("--auto"), argv.index("--"))
            self.assertEqual(oct((root / "home/.config/kimchi/config.json").stat().st_mode & 0o777), "0o600")

    def test_binary_refusing_the_fixture_is_named(self):
        with tempfile.TemporaryDirectory() as directory:
            exe = Path(directory) / "kimchi"
            exe.write_text(STRICT_BASH + "printf 'run kimchi from that devenv root.\\n' >&2\nexit 1\n")
            exe.chmod(0o755)
            record, refused = suite.probe_version(str(exe), "kimchi", os.environ, directory)
            self.assertIn("exited 1 in the fixture: run kimchi from that devenv root.; pass --bin kimchi=<path>", refused)
            exe.write_text(STRICT_BASH + "echo 1.5.1\n")
            self.assertEqual(suite.probe_version(str(exe), "kimchi", os.environ, directory), ({"executable": str(exe), "version": "1.5.1"}, None))

    def test_header_only_stream_is_named(self):
        events = [{"type": "session", "version": 3}]
        self.assertFalse(suite.HARNESSES["kimchi"]["answered"](events))
        self.assertEqual(suite.stream_shape(events), "session x1")
        self.assertEqual(suite.stream_shape([]), "empty")


if __name__ == "__main__":
    unittest.main()
