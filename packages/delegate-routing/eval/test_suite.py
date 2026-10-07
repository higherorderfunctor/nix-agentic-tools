#!/usr/bin/env python3
"""Offline regressions for source attribution and the captured CLI schemas."""

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import suite


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


class Launches(unittest.TestCase):
    def test_claude_appends_the_delivered_system_prompt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ctx = {"case": {"systemPrompt": "# Delegate routing\n"}, "dir": root, "exe": "claude", "baseline_argv": [],
                   "hook": root / "hook", "home": root / "home", "logs": root / "logs", "prompt": "task", "claude_token": None}
            with patch.object(suite, "REAL_HOME", root):
                plan = suite.claude_setup(ctx)
            path = plan["argv"][plan["argv"].index("--append-system-prompt-file") + 1]
            self.assertEqual(Path(path).read_text(), "# Delegate routing\n")
            self.assertIn(Path(path), plan["written"])


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


if __name__ == "__main__":
    unittest.main()
