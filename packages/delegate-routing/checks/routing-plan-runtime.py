"""Offline, literal routing expectations: no catalogs, live readers or launches."""
from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
import importlib.util
import io
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


def window(remaining=50, seconds=2592000, reset="2026-12-01T00:00:00Z"):
    return {"remainingPercent": remaining, "resetsAt": reset, "status": "ok", "usedPercent": 100 - remaining, "windowSeconds": seconds}


def stream(windows=None):
    return json.dumps({"account": {"auth_index": None, "name": "fake", "plan": None}, "balances": [], "bonuses": [], "pool": "deliberately-not-the-registration", "windows": windows or {"monthly": window()}})


def technique(name="spawn_agent", kind="subagent", model="gpt-6.1-sol", pattern=False, agent=None):
    return {"agent": agent, "model": {"isPattern": pattern, "value": model}, "name": name, "node": {"command": "MUST NEVER EXECUTE THIS LAUNCH", "kind": kind, "modelArg": "slug", "notes": "caller binds task/output paths"}}


def route(name="sol", tier="strong", pool="outside", target="codex", techniques=None, maker="openai", cost=3, trial=False):
    return {"family": {"avoidFor": "sole judge", "cost": cost, "defaultEffort": "high", "effort": "prose is not an effort enum", "maker": maker, "name": name, "tier": tier, "trial": trial, "useFor": "writer-judge loop", "vendor": "provider"}, "pool": pool, "target": target, "techniques": techniques or [technique()]}


def manifest(routes=None, session=None):
    return {"manualRoutes": [route("manual", pool=None, maker="anthropic")], "readers": [{"command": "reader-outside", "name": "outside"}, {"command": "reader-session", "name": "session"}, {"command": "reader-hidden-runtime", "name": "hidden"}], "routes": routes or [route()], "runtime": "codex", "runtimes": ["codex"], "sessionPool": session}


def context(roles=("writer",), techniques=None, non_interactive=False, effort="high"):
    return {"nonInteractive": non_interactive, "roles": {role: {"brief": "brief.md", "effort": effort, "requirements": {"constraints": [], "inputKinds": ["text"]}, **({"writer": "manual"} if role in ("finder", "first-check", "second-check", "judge") else {})} for role in roles}, "techniques": techniques or [{"efforts": ["high"], "model": "gpt-6.1-sol", "runtime": "codex", "technique": "spawn_agent"}]}


def save_plan_receipt(root, config, artifact, unit, record, keep=None):
    facts = {"roles": {record["role"]: {key: record[key] for key in ("brief", "effort", "requirements")}}, "rubric": artifact["rubric"], "subject": {"task": artifact["task"], "unit": unit["id"]}, "techniques": context()["techniques"]}
    request, digest = helper.classification_request(config, facts, record["role"], root)
    body = {"classifier": {"family": "sol", "effort": "high", "model": "gpt-6.1-sol", "runtime": "codex", "technique": "spawn_agent", "pool": "outside"}, "decisions": [{"family": family["name"], "decision": "keep" if keep is None or family["name"] == keep else "task-mismatch", "reason": "Supplied fixture criteria assessed."} for family in request["families"]], "requestHash": digest, "schemaVersion": 1}
    (root / record["receipt"]).write_text(json.dumps(body | {"receiptHash": helper.receipt_hash(body)}))


class Classification(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="classification-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config = manifest([route(), route("luna", tier="small", techniques=[technique(model="luna-model")])])
        self.config.update({"classifierInstructions": "Classify only.\n", "classifiers": [{"family": "luna", "effort": "medium"}], "familyCatalog": [route("unselected")["family"], route("luna")["family"], route()["family"]], "manualRoutes": []})
        self.facts = {"nonInteractive": True, "roles": {"writer": {"brief": "brief.md", "effort": "high", "requirements": {"constraints": [{"id": "bounded", "text": "Use supplied criteria."}], "inputKinds": ["text"]}}}, "rubric": "rubric.md", "subject": {"task": "task", "unit": "one"}, "techniques": [{"efforts": ["medium"], "model": "luna-model", "runtime": "codex", "technique": "spawn_agent"}, {"efforts": ["high"], "model": "gpt-6.1-sol", "runtime": "codex", "technique": "spawn_agent"}]}
        (self.root / "brief.md").write_bytes("Actual brief\nCafé\n".encode())
        (self.root / "rubric.md").write_bytes(b"Actual rubric\n")

    def invoke(self, extra=(), outputs=None):
        for name, value in (("manifest", self.config), ("context", self.facts)):
            (self.root / f"{name}.json").write_text(json.dumps(value))
        argv = ["helper", "--manifest", str(self.root / "manifest.json"), "--reader-shell", SHELL, "--launch-context", str(self.root / "context.json"), "--now", "2026-11-15T00:00:00Z"] + list(extra)
        out, err = io.StringIO(), io.StringIO()
        def reader(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0, (outputs or {}).get(argv[4].split("\n", 1)[1], stream()))
        with patch.object(sys, "argv", argv), patch.object(helper, "run_reader", side_effect=reader) as run, patch.object(helper.subprocess, "Popen", side_effect=AssertionError("non-Reader subprocess")), redirect_stdout(out), redirect_stderr(err):
            code = helper.main()
        self.assertEqual(run.call_count, 3)
        return code, json.loads(out.getvalue()), err.getvalue()

    def prepare(self):
        code, output, _ = self.invoke(["--role", "classifier", "--classify-role", "writer"])
        self.assertEqual(code, 0, output)
        return output["classification"]

    def exchange(self):
        preparation = self.prepare()
        return {"preparation": preparation, "result": {"schemaVersion": 1, "requestHash": preparation["requestHash"], "decisions": [{"family": name, "decision": "keep" if name == "sol" else "task-mismatch", "reason": "Supplied criteria assessed."} for name in ("luna", "sol", "unselected")]}}

    def accept(self, exchange=None, outputs=None):
        (self.root / "exchange.json").write_text(json.dumps(exchange or self.exchange()))
        return self.invoke(["--role", "writer", "--classification", str(self.root / "exchange.json")], outputs)

    def test_prepare_accept_and_reuse(self):
        # Wrong: self-fit, incomplete catalog, model economics, or a second inference.
        exchange = self.exchange()
        prepared = exchange["preparation"]
        self.assertEqual(set(prepared["request"]), {"brief", "families", "requirements", "role", "rubric", "schemaVersion", "subject"})
        self.assertEqual(prepared["request"]["brief"], "Actual brief\nCafé\n")
        self.assertEqual(prepared["request"]["rubric"], "Actual rubric\n")
        self.assertEqual(prepared["request"]["families"], [{"avoidFor": "sole judge", "effectiveEffort": "high", "name": name, "useFor": "writer-judge loop"} for name in ("luna", "sol", "unselected")])
        self.assertEqual(prepared["launch"]["family"], "luna")
        self.assertEqual(prepared["launch"]["effort"], "medium")
        self.assertNotIn("qualification", prepared["launch"])
        code, accepted, _ = self.accept(exchange)
        self.assertEqual(code, 0, accepted)
        self.assertEqual([item["launch"]["family"] for item in accepted["roles"]["writer"]["candidates"]], ["sol"])
        self.assertNotIn("qualification", accepted["roles"]["writer"]["candidates"][0]["launch"])
        (self.root / "receipt.json").write_text(json.dumps(accepted["receipt"]))
        code, reused, _ = self.invoke(["--role", "writer", "--receipt", str(self.root / "receipt.json")])
        self.assertEqual(code, 0, reused)
        self.assertNotIn("classification", reused)
        self.assertEqual(reused["receipt"], accepted["receipt"])

    def test_missing_evidence_and_relayed_pins(self):
        # Wrong: no receipt launches work, or a user pin is hidden or bypassed.
        self.facts["roles"]["writer"]["pins"] = {"family": "sol", "model": "gpt-6.1-sol", "runtime": "codex", "technique": "spawn_agent"}
        code, output, stderr = self.invoke(["--role", "writer"])
        self.assertEqual((code, output["status"], output["roles"]), (3, "classification-required", {}))
        self.assertIn("--role classifier --classify-role writer", output["preparation"])
        self.assertEqual(output["decisions"]["writer"]["pins"], self.facts["roles"]["writer"]["pins"])
        self.assertIn("pin: writer family=sol", stderr)
        self.config["routes"][0]["techniques"][0]["model"] = {"isPattern": True, "value": "gpt-*"}
        self.facts["techniques"].append({"efforts": ["high"], "model": "gpt-6.1-sol-alt", "runtime": "codex", "technique": "spawn_agent"})
        code, accepted, _ = self.accept()
        self.assertEqual(code, 0, accepted)
        self.facts["roles"]["writer"]["pins"]["model"] = "unavailable"
        (self.root / "receipt.json").write_text(json.dumps(accepted["receipt"]))
        code, output, _ = self.invoke(["--role", "writer", "--receipt", str(self.root / "receipt.json")])
        self.assertEqual(code, 1, output)
        self.assertEqual(output["roles"]["writer"]["candidates"], [])

    def test_closed_result_schema_and_exact_coverage(self):
        # Wrong: partial, duplicated or model-selected effort survives validation.
        exchange = self.exchange()
        mutations = [
            lambda r: r.update(extra=True), lambda r: r.update(schemaVersion=True),
            lambda r: r.update(requestHash="sha256:" + "0" * 64),
            lambda r: r["decisions"].pop(), lambda r: r["decisions"].append(r["decisions"][0]),
            lambda r: r["decisions"][0].update(family="unknown"),
            lambda r: r["decisions"][0].update(decision="prefer"),
            lambda r: r["decisions"][0].update(effort="ultra"),
            lambda r: r["decisions"][0].update(reason=" "),
            lambda r: r["decisions"][0].update(reason="x" * 241),
            lambda r: r["decisions"][0].update(reason="\ud800"),
        ]
        for mutate in mutations:
            changed = deepcopy(exchange)
            mutate(changed["result"])
            with self.subTest(result=changed["result"]):
                code, output, _ = self.accept(changed)
                self.assertEqual(code, 2, output)
                self.assertNotIn("receipt", output)
        for label in ("keep", "task-mismatch", "input-unsupported", "constraint-conflict", "uncertain"):
            changed = deepcopy(exchange)
            changed["result"]["decisions"][0]["decision"] = label
            self.assertEqual(self.accept(changed)[0], 0)

    def test_request_scope_and_live_gates(self):
        # Wrong: transient metadata reclassifies, or semantic edits reuse a receipt.
        exchange = self.exchange()
        code, accepted, _ = self.accept(exchange)
        self.assertEqual(code, 0, accepted)
        receipt = accepted["receipt"]
        (self.root / "receipt.json").write_text(json.dumps(receipt))
        args = ["--role", "writer", "--receipt", str(self.root / "receipt.json")]
        self.config["routes"][0]["family"].update(cost=5, maker="changed", trial=True)
        self.config["familyCatalog"][2].update(cost=5, maker="changed", trial=True, example={"codex": "changed"})
        self.assertEqual(self.invoke(args)[0], 0)
        self.facts["techniques"] = self.facts["techniques"][:1]
        self.assertEqual(self.invoke(args)[0], 1)
        self.facts["techniques"].append({"efforts": ["high"], "model": "gpt-6.1-sol", "runtime": "codex", "technique": "spawn_agent"})
        self.assertEqual(self.invoke(args, {"reader-outside": stream({"monthly": window(0)})})[0], 1)
        original_facts, original_config = deepcopy(self.facts), deepcopy(self.config)
        changes = [lambda: self.facts["roles"]["writer"].update(effort="ultra"), lambda: self.facts["subject"].update(unit="two"), lambda: self.facts["roles"]["writer"]["requirements"]["inputKinds"].append("image"), lambda: self.config["familyCatalog"][0].update(useFor="changed"), lambda: self.config.update(classifierInstructions="Changed instructions")]
        for change in changes:
            self.facts, self.config = deepcopy(original_facts), deepcopy(original_config)
            change()
            self.assertEqual(self.invoke(args)[0], 2)
        self.facts, self.config = original_facts, original_config
        for filename in ("brief.md", "rubric.md"):
            path = self.root / filename
            original = path.read_bytes()
            path.write_bytes(original + b"\n")
            self.assertEqual(self.invoke(args)[0], 2)
            path.write_bytes(original)

    def test_approval_and_saved_preparation(self):
        # Wrong: acceptance requires today's winner, or trusts modified preparation.
        exchange = self.exchange()
        code, output, _ = self.accept(exchange, {"reader-outside": stream({"monthly": window(0)})})
        self.assertEqual(code, 1, output)
        self.assertIn("receipt", output)
        self.config["routes"][1]["pool"] = "hidden"
        self.config["routes"][1]["techniques"][0]["model"]["value"] = "changed-example"
        self.assertEqual(self.accept(exchange)[0], 0)
        for key, value in (("requestHash", "sha256:" + "0" * 64), ("brief", "different"), ("line", "different")):
            changed = deepcopy(exchange)
            changed["preparation"][key] = value
            self.assertEqual(self.accept(changed)[0], 2)
        for key, value in (("family", "sol"), ("effort", "ultra"), ("model", "*"), ("runtime", "unknown"), ("technique", "unknown")):
            changed = deepcopy(exchange)
            changed["preparation"]["launch"][key] = value
            self.assertEqual(self.accept(changed)[0], 2)
        code, output, _ = self.accept(exchange)
        (self.root / "receipt.json").write_text(json.dumps(output["receipt"]))
        self.config["classifiers"] = [{"family": "sol", "effort": "high"}]
        self.assertEqual(self.accept(exchange)[0], 2)
        self.assertEqual(self.invoke(["--role", "writer", "--receipt", str(self.root / "receipt.json")])[0], 2)

    def test_bounds_paths_and_context_refusals(self):
        # Wrong: oversized or escaped artifacts spend on a classifier; essays persist.
        self.prepare()
        original = deepcopy(self.facts)
        changes = [lambda r: r.update(families={}), lambda r: r.update(fit="essay"), lambda r: r.update(trial="essay"), lambda r: r.update(pins={"extra": "x"}), lambda r: r.update(brief="../escape.md"), lambda r: r["requirements"]["constraints"].append({"id": "bounded", "text": "duplicate"}), lambda r: r["requirements"].update(inputKinds=["text", "text"])]
        for change in changes:
            self.facts = deepcopy(original)
            change(self.facts["roles"]["writer"])
            self.assertEqual(self.invoke(["--role", "classifier", "--classify-role", "writer"])[0], 2)
        self.facts = original
        for count in (65536, 65537):
            (self.root / "brief.md").write_bytes(b"x" * count)
            code, output, _ = self.invoke(["--role", "classifier", "--classify-role", "writer"])
            self.assertEqual(code, 2)
            self.assertNotIn("classification", output)
        (self.root / "brief.md").write_bytes(b"brief")
        self.config["familyCatalog"] = [route(f"family-{index}")["family"] for index in range(129)]
        self.assertEqual(self.invoke(["--role", "classifier", "--classify-role", "writer"])[0], 2)

    def test_strict_json_and_receipt_integrity(self):
        # Wrong: duplicate keys/non-finite values or a forged receipt body is accepted.
        for payload in ('{"key":1,"key":2}', '{"key":NaN}', '{"key":Infinity}'):
            with self.assertRaises(ValueError):
                helper.strict_json(payload)
        _, accepted, _ = self.accept()
        receipt = accepted["receipt"]
        for key, value in (("extra", True), ("receiptHash", "sha256:" + "0" * 64), ("decisions", [])):
            changed = receipt | {key: value}
            (self.root / "receipt.json").write_text(json.dumps(changed))
            self.assertEqual(self.invoke(["--role", "writer", "--receipt", str(self.root / "receipt.json")])[0], 2)
        for content in (b"x" * 1048577, b'{"result":NaN}', b'{"result":1,"result":2}'):
            (self.root / "exchange.json").write_bytes(content)
            self.assertEqual(self.invoke(["--role", "writer", "--classification", str(self.root / "exchange.json")])[0], 2)

    def test_hash_literal_vectors(self):
        # Wrong: missing domains, UTF-8 byte length, compact JSON or exact newlines.
        self.assertEqual(helper.request_hash("é\n", {"z": "é\n", "a": 1}), "sha256:a9d926dbed4c2894f042593019521fdbed1799d499e216b87022a50221dd8f6a")
        self.assertEqual(helper.receipt_hash({"z": "é\n", "a": 1}), "sha256:453f2851e0f11501a2985ea3859f814170be8237ae9f1bfaa9fc963b50f80e07")

    def test_classifier_approval_effort_and_budget(self):
        # Wrong: caller essays qualify classifiers, or approval order beats ranking.
        self.config["classifiers"] = [{"family": "luna", "effort": "ultra"}, {"family": "luna", "effort": "medium"}]
        self.assertEqual(self.prepare()["launch"]["effort"], "medium")
        code, output, _ = self.invoke(["--role", "classifier", "--classify-role", "writer"], {"reader-outside": stream({"monthly": window(0)})})
        self.assertEqual(code, 1, output)
        self.assertNotIn("classification", output)
        self.config["sessionPool"] = "outside"
        self.assertEqual(self.invoke(["--role", "classifier", "--classify-role", "writer"], {"reader-outside": stream({"monthly": window(20)})})[0], 1)
        self.config["sessionPool"] = None
        self.facts["nonInteractive"] = False
        self.config["classifiers"] = [{"family": "luna", "effort": "high"}, {"family": "luna", "effort": "medium"}]
        self.config["routes"].append(route("luna", tier="small", pool="hidden", target="claude", techniques=[technique(name="external", kind="external", model="luna-external")]))
        self.facts["techniques"].append({"efforts": ["high"], "model": "luna-external", "runtime": "claude", "technique": "external"})
        prepared = self.prepare()
        self.assertEqual((prepared["launch"]["effort"], prepared["launch"]["runtime"]), ("high", "claude"))
        for extra in (["--role", "writer", "--role", "mechanical"], ["--role", "classifier"], ["--role", "writer", "--classify-role", "writer"], ["--role", "writer", "--receipt", "x", "--classification", "y"]):
            self.assertEqual(self.invoke(extra)[0], 2)

    def test_generated_default_effort_binding(self):
        # Wrong: a generated default authorizes native launch or a different effort.
        self.facts["roles"]["writer"]["effort"] = None
        self.config["familyCatalog"][2]["defaultEffort"] = "medium"
        self.facts["techniques"][1]["efforts"] = ["medium", "high"]
        exchange = self.exchange()
        self.assertEqual(exchange["preparation"]["request"]["families"][1]["effectiveEffort"], "medium")
        self.assertEqual(self.accept(exchange)[0], 1)
        self.config["routes"][0]["techniques"][0]["agent"] = {"family": {"defaultEffort": "high"}}
        self.assertEqual(self.accept(exchange)[0], 1)
        self.config["routes"][0]["techniques"][0]["agent"]["family"]["defaultEffort"] = "medium"
        code, accepted, _ = self.accept(exchange)
        self.assertEqual(code, 0, accepted)
        self.assertEqual(accepted["roles"]["writer"]["candidates"][0]["launch"]["effort"], "medium")
        self.config["familyCatalog"][2]["defaultEffort"] = "high"
        self.assertEqual(self.accept(exchange)[0], 2)

    def test_exact_request_and_result_limits(self):
        # Wrong: truncation, character counts or an off-by-one bound buys inference.
        prepared = self.prepare()
        payload = json.dumps(prepared["request"], ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        self.config["classifierInstructions"] = "x" * (65536 - len(payload))
        self.prepare()
        self.config["classifierInstructions"] += "x"
        self.assertEqual(self.invoke(["--role", "classifier", "--classify-role", "writer"])[0], 2)
        self.config["classifierInstructions"] = "Classify only.\n"
        exchange = self.exchange()
        raw = json.dumps(exchange).encode()
        (self.root / "exchange.json").write_bytes(raw + b" " * (1048576 - len(raw)))
        self.assertEqual(self.invoke(["--role", "writer", "--classification", str(self.root / "exchange.json")])[0], 0)
        self.config["familyCatalog"] = [route(f"family-{index:03}")["family"] for index in range(127)] + [route("luna")["family"]]
        self.assertEqual(len(self.prepare()["request"]["families"]), 128)

    def test_context_and_manifest_malformed_shapes(self):
        # Wrong: wrong typed requirements, catalog identities or approvals reach spend.
        self.prepare()
        original = deepcopy(self.facts)
        role_mutations = [lambda r: r.update(useFor="essay"), lambda r: r.update(avoidFor="essay"), lambda r: r.update(effort=True), lambda r: r.update(brief=str(SOURCE)), lambda r: r.update(pins={"family": " "}), lambda r: r.update(requirements={"constraints": {}, "inputKinds": []}), lambda r: r["requirements"].update(inputKinds=["other"]), lambda r: r["requirements"]["constraints"][0].update(extra=True)]
        for change in role_mutations:
            self.facts = deepcopy(original)
            change(self.facts["roles"]["writer"])
            self.assertEqual(self.invoke(["--role", "classifier", "--classify-role", "writer"])[0], 2)
        self.facts = original
        (self.root / "escape.md").symlink_to(SOURCE)
        self.facts["roles"]["writer"]["brief"] = "escape.md"
        self.assertEqual(self.invoke(["--role", "classifier", "--classify-role", "writer"])[0], 2)
        self.facts["roles"]["writer"]["brief"] = "brief.md"
        original_config = deepcopy(self.config)
        mutations = [lambda: self.config["familyCatalog"].append(self.config["familyCatalog"][0]), lambda: self.config.update(classifiers=[]), lambda: self.config["classifiers"].append(self.config["classifiers"][0]), lambda: self.config.update(classifiers=[{"family": "unknown", "effort": "medium"}])]
        for change in mutations:
            self.config = deepcopy(original_config)
            change()
            self.assertEqual(self.invoke(["--role", "classifier", "--classify-role", "writer"])[0], 2)
        self.config = original_config
        self.config["familyCatalog"][0].update(avoidFor="", useFor="")
        self.assertEqual(self.prepare()["request"]["families"][2]["useFor"], "")

    def test_classifier_pins_and_approval_order_reuse(self):
        # Wrong: pins bypass approvals, or list order invalidates a completed pair.
        self.prepare()
        self.facts["roles"]["classifier"] = {"pins": {"family": "sol"}}
        code, output, _ = self.invoke(["--role", "classifier", "--classify-role", "writer"])
        self.assertEqual(code, 1, output)
        self.config["classifiers"].append({"family": "sol", "effort": "high"})
        prepared = self.prepare()
        self.assertEqual(prepared["launch"]["family"], "sol")
        self.facts["roles"]["classifier"] = {"effort": "ultra"}
        self.assertEqual(self.invoke(["--role", "classifier", "--classify-role", "writer"])[0], 1)
        del self.facts["roles"]["classifier"]
        _, accepted, _ = self.accept()
        (self.root / "receipt.json").write_text(json.dumps(accepted["receipt"]))
        self.config["classifiers"].reverse()
        self.config["routes"][0]["pool"] = "hidden"
        self.config["routes"][1]["pool"] = "hidden"
        self.assertEqual(self.invoke(["--role", "writer", "--receipt", str(self.root / "receipt.json")])[0], 0)


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
            config = config or manifest()
            pools = helper.collect(config["readers"], NOW, SHELL, reader)
            facts = launch_context or context(roles)
            result = None
            for role in roles:
                evidence = {"decisions": {item["family"]["name"]: "keep" for item in config["routes"]}, "efforts": {item["family"]["name"]: facts["roles"][role]["effort"] if facts["roles"][role]["effort"] is not None else item["family"].get("defaultEffort") for item in config["routes"]}}
                decision = helper.plan(config, facts, [role], NOW, pools, semantic=evidence)
                if result is None:
                    result = decision
                else:
                    result["roles"].update(decision["roles"])

        return result, calls

    def test_cost_ranking_after_pace_and_session(self):
        # Wrong: price overrides pace/session, or names override equal-pace cost.
        cases = [
            ("equal-pace-cheaper", [("astra", 4, "outside"), ("luna", 1, "outside")], None, {}, ["luna", "astra"]),
            ("faster-expensive", [("astra", 4, "outside"), ("luna", 1, "hidden")], None, {"reader-outside": stream({"monthly": window(80)})}, ["astra", "luna"]),
            ("session-cheaper", [("luna", 1, "session"), ("astra", 4, "outside")], "session", {}, ["astra", "luna"]),
            ("name-tie", [("sol", 2, "outside"), ("sonnet", 2, "outside")], None, {}, ["sol", "sonnet"]),
            ("scoped-pace", [("astra", 4, "outside"), ("luna", 1, "outside")], None, {"reader-outside": stream({"monthly": window(80), "monthly:luna": window(30)})}, ["astra", "luna"]),
        ]
        for label, rows, session, outputs, expected in cases:
            with self.subTest(case=label):
                routes = [route(name, pool=pool, cost=cost) for name, cost, pool in rows]
                result, _ = self.run_plan(manifest(routes, session), context(), outputs=outputs)
                self.assertEqual([item["launch"]["family"] for item in result["roles"]["writer"]["candidates"]], expected)

    def test_cost_order_without_measurements(self):
        # Wrong: unknown pace loses cost/session ordering or hides uncertainty.
        routes = [route("session-cheap", pool="session", cost=0), route("astra", cost=4), route("luna", cost=1)]
        result, _ = self.run_plan(manifest(routes, "session"), context(), outputs={command: "invalid" for command in ("reader-outside", "reader-session", "reader-hidden-runtime")})
        candidates = result["roles"]["writer"]["candidates"]
        self.assertEqual([item["launch"]["family"] for item in candidates], ["luna", "astra", "session-cheap"])
        self.assertTrue(all(item["budget"] == "fit-only; budget and session buffer unknown" for item in candidates))
        self.assertIn("session budget unmeasured; buffer rule cannot be certified", result["warnings"])

    def test_raw_cost_metadata_required_before_selection(self):
        # Wrong: missing, boolean, non-integer or out-of-range costs reach sorting.
        for collection in ("manualRoutes", "routes"):
            for cost in (None, True, False, -1, 6, 1.5, "1"):
                with self.subTest(collection=collection, cost=cost):
                    config = manifest()
                    if cost is None:
                        del config[collection][0]["family"]["cost"]
                    else:
                        config[collection][0]["family"]["cost"] = cost
                    with self.assertRaisesRegex(ValueError, "family .* cost must be an integer from 0 to 5"):
                        self.run_plan(config, context())

    def test_trial_policy_for_review_roles(self):
        # Wrong: an essay admits trial judges, or the gate bans trial finders.
        roles = ("finder", "first-check", "second-check", "judge")
        for trial, expected in ((False, [True, True, True, True]), (True, [True, True, False, False])):
            with self.subTest(trial=trial):
                facts = context(roles)
                result, _ = self.run_plan(manifest([route(trial=trial)]), facts, roles)
                self.assertEqual([bool(result["roles"][role]["candidates"]) for role in roles], expected)
                if trial:
                    for role in ("second-check", "judge"):
                        self.assertIn("trial family excluded from second-check and judge", [item["reason"] for item in result["roles"][role]["exclusions"]])

    def test_raw_trial_metadata_required_before_selection(self):
        # Wrong: missing or non-boolean policy reaches even an unqualified route.
        for collection in ("manualRoutes", "routes"):
            for trial in (None, 0, 1, "false", [], {}):
                with self.subTest(collection=collection, trial=trial):
                    config = manifest()
                    if trial is None:
                        del config[collection][0]["family"]["trial"]
                    else:
                        config[collection][0]["family"]["trial"] = trial
                    with self.assertRaisesRegex(ValueError, "family .* trial must be a boolean"):
                        self.run_plan(config, context())

    def test_cli_collects_before_recoverable_failures(self):
        # Wrong: invalid input exits without JSON or skips registered Readers.
        config = manifest()
        config["readers"].append({"command": "reader-outside", "name": "alias"})
        base = ["helper", "--manifest", "manifest.json", "--reader-shell", SHELL, "--launch-context", "context.json", "--role", "writer", "--now", "2026-11-15T00:00:00Z"]
        cases = [
            ("argument", ["--max-concurrency", "0"], json.dumps(context()), config, 3),
            ("context-json", [], "{", config, 3),
            ("context-shape", [], "[]", config, 3),
            ("invalid-shell", ["--reader-shell", "/no/such/shell"], json.dumps(context()), config, 0),
            ("inventory", [], json.dumps(context()), {"readers": "bad"}, 0),
            ("manifest-json", [], json.dumps(context()), None, 0),
            ("missing-manifest", ["--manifest"], json.dumps(context()), config, 0),
            ("missing-shell", ["--reader-shell"], json.dumps(context()), config, 0),
            ("missing-value", ["--max-concurrency"], json.dumps(context()), config, 3),
            ("plan-json", ["--check-plan", "plan.json"], json.dumps(context()), config, 3),
            ("plan-rejection", ["--check-plan", "bad-plan.json"], json.dumps(context()), config, 3),
            ("role", ["--role", "unknown"], json.dumps(context()), config, 3),
            ("time", ["--now", "bad"], json.dumps(context()), config, 3),
            ("unknown-argument", ["--unknown"], json.dumps(context()), config, 3),
        ]
        for name, extra, ctx, inventory, count in cases:
            with self.subTest(case=name):
                files = {"manifest.json": json.dumps(inventory) if inventory is not None else "{", "context.json": ctx, "plan.json": "{", "bad-plan.json": "{}"}
                out, err = io.StringIO(), io.StringIO()
                def read(path, *args, **kwargs):
                    return files[path.name]
                with patch.object(sys, "argv", base + extra), patch.object(Path, "read_text", read), patch.object(helper, "run_reader", return_value=subprocess.CompletedProcess([], 0, stream())) as reader, redirect_stdout(out), redirect_stderr(err):
                    try:
                        code = helper.main()
                    except SystemExit as error:
                        code = error.code
                self.assertEqual(code, 2)
                self.assertTrue(out.getvalue(), "failure must emit JSON")
                result = json.loads(out.getvalue())
                self.assertEqual(result["status"], "error")
                self.assertTrue(result["errors"])
                self.assertEqual(reader.call_count, count)
                if name in ("inventory", "manifest-json", "missing-manifest"):
                    self.assertEqual(result["pools"], {})
                    self.assertEqual(result["inventory"], "inventory-unavailable")
                else:
                    self.assertEqual(sorted(result["pools"]), ["alias", "hidden", "outside", "session"])
                    self.assertEqual(result["inventory"], "available")
                    if name != "time":
                        self.assertEqual(result["snapshot"], "2026-11-15T00:00:00+00:00")
                    for pool in result["pools"].values():
                        self.assertEqual(pool["status"], "unmeasured" if count == 0 else "measured")
                        if count == 0:
                            self.assertEqual(pool["reason"], "Reader shell must name an executable file")
                    self.assertEqual([line for line in err.getvalue().splitlines() if line.startswith("pool=")], [f"pool={pool} status={'unmeasured' if count == 0 else 'measured'}" for pool in ("alias", "hidden", "outside", "session")])
                    if count == 0:
                        for names in ("alias, outside", "hidden", "session"):
                            self.assertIn(f"WARNING: Reader for {names} failed: Reader shell must name an executable file. Report this failure to the user.", err.getvalue())
                    if count:
                        self.assertEqual([call.args[0][4].split("\n", 1)[1] for call in reader.call_args_list], ["reader-outside", "reader-session", "reader-hidden-runtime"])

    def test_cli_pool_diagnostics(self):
        # Wrong: non-session Reader failures stay silent while another pool works.
        cases = [
            ("success", stream(), "measured", None),
            ("exit", subprocess.CompletedProcess([], 7, "", "SECRET stderr"), "unmeasured", "Reader exited 7"),
            ("timeout", subprocess.TimeoutExpired("SECRET command", 10, stderr="SECRET stderr"), "unmeasured", "Reader timed out"),
            ("invalid-context", subprocess.CompletedProcess([], 7, "", "SECRET stderr"), "unmeasured", "Reader exited 7"),
            ("invalid-plan", subprocess.CompletedProcess([], 7, "", "SECRET stderr"), "unmeasured", "Reader exited 7"),
            ("malformed", "SECRET invalid JSON", "unmeasured", "invalid Reader output"),
            ("bad-reset", stream({"monthly": window(reset="SECRET reset")}), "unmeasured", "invalid Reader output"),
            ("execution", OSError("SECRET execution detail"), "unmeasured", "Reader could not execute"),
            ("scoped", stream({"monthly": window(), "7d:sol": window(reset=None)}), "measured", None),
            ("exhausted", stream({"monthly": window(0)}), "measured", None),
            ("missing", None, "unmeasured", "no registered Reader"),
        ]
        for name, output, status, reason in cases:
            with self.subTest(case=name):
                config = manifest()
                config["readers"].append({"command": "reader-hidden-runtime", "name": "alias"})
                if name == "missing":
                    config["readers"][2]["command"] = None
                    config["readers"][-1]["command"] = None
                files = {"manifest.json": json.dumps(config), "context.json": "{" if name == "invalid-context" else json.dumps(context()), "plan.json": "{}"}
                def reader(argv, **kwargs):
                    if argv[4].endswith("reader-hidden-runtime"):
                        if isinstance(output, Exception):
                            raise output
                        return output if isinstance(output, subprocess.CompletedProcess) else subprocess.CompletedProcess([], 0, output)
                    return subprocess.CompletedProcess([], 0, stream())
                out, err = io.StringIO(), io.StringIO()
                argv = ["helper", "--manifest", "manifest.json", "--reader-shell", SHELL, "--launch-context", "context.json", "--role", "writer", "--now", "2026-11-15T00:00:00Z"]
                if name == "invalid-plan":
                    argv += ["--check-plan", "plan.json"]
                # Pool reporting also succeeds when the task awaits classification.
                with patch.object(sys, "argv", argv), patch.object(Path, "read_text", lambda path: files[path.name]), patch.object(helper, "classification_request", return_value=({}, "unused")), patch.object(helper, "run_reader", side_effect=reader) as run, redirect_stdout(out), redirect_stderr(err):
                    code = helper.main()
                result = json.loads(out.getvalue())
                self.assertEqual(code, 2 if name in ("invalid-context", "invalid-plan") else 3)
                self.assertEqual(result["status"], "error" if code == 2 else "classification-required")
                self.assertEqual(run.call_count, 2 if name == "missing" else 3)
                self.assertEqual(result["pools"]["hidden"]["status"], status)
                self.assertEqual(result["pools"]["outside"]["pace"], 0.9375)
                warnings = [line for line in err.getvalue().splitlines() if line.startswith("WARNING:")]
                if reason:
                    expected = ([f"WARNING: Reader for {pool} failed: {reason}. Report this failure to the user." for pool in ("alias", "hidden")] if name == "missing" else [f"WARNING: Reader for alias, hidden failed: {reason}. Report this failure to the user."])
                    self.assertEqual(warnings, expected)
                    for warning in expected:
                        self.assertIn(warning, result["warnings"])
                elif name == "scoped":
                    self.assertEqual(warnings, ["WARNING: pool=alias scoped window 7d:sol invalid; refusing its family.", "WARNING: pool=hidden scoped window 7d:sol invalid; refusing its family."])
                    self.assertEqual(result["pools"]["hidden"]["scopedErrors"], {"7d:sol": "unstarted null reset unresolved"})
                else:
                    self.assertEqual(warnings, [])
                if name == "exhausted":
                    self.assertEqual(result["pools"]["hidden"]["pace"], 0)
                    self.assertEqual(result["pools"]["hidden"]["buffer"], 0)
                self.assertEqual([line for line in err.getvalue().splitlines() if line.startswith("pool=")], [f"pool=alias status={status}", f"pool=hidden status={status}", "pool=outside status=measured", "pool=session status=measured"])
                self.assertNotIn("SECRET", err.getvalue())

    def test_maker_policy_aliases_and_runtime_pool_independence(self):
        # Wrong: provider/runtime/pool identity substitutes for explicit maker.
        # Go refuses GLM in production; this configured strong family isolates identity.
        roles = ("finder", "first-check", "second-check", "judge")
        cases = [
            ("go-glm", "glm-5.3", "zhipu", "zhipu", False, "same maker as writer: zhipu"),
            ("go-kimi-k3", "kimi-k3", "moonshot", "moonshot", False, "same maker as writer: moonshot"),
            ("go-kimi-k3.1-pro", "kimi-k3.1-pro", "moonshot", "moonshot", False, "same maker as writer: moonshot"),
            ("go-gemini-4-argon", "gemini-4-argon", "google", "zhipu", True, None),
            ("go-kimi-k3", "kimi-k3", "moonshot", "openai", True, None),
            # Wrong: surrounding whitespace or letter case certifies a different maker.
            ("sol", "gpt-6.1-sol", " OpenAI ", "openai", False, "same maker as writer: openai"),
            ("sol", "gpt-6.1-sol", "openai", " OPENAI ", False, "same maker as writer: openai"),
        ]
        for name, model, maker, writer_maker, allowed, reason in cases:
            with self.subTest(family=name, writer=writer_maker):
                candidate = route(name, pool="session", target="claude", techniques=[technique(model=model)], maker=maker)
                candidate["family"]["vendor"] = "opencode-go"
                config = manifest([candidate])
                config["manualRoutes"] = [route("author", pool="outside", maker=writer_maker)]
                ctx = context(roles, techniques=[{"efforts": ["high"], "model": model, "runtime": "claude", "technique": "spawn_agent"}])
                for request in ctx["roles"].values():
                    request["writer"] = "author"
                result, _ = self.run_plan(config, ctx, roles)
                for role in roles:
                    self.assertEqual(bool(result["roles"][role]["candidates"]), allowed)
                    if not allowed:
                        self.assertEqual(result["roles"][role]["exclusions"][0]["reason"], reason)
                        self.assertEqual(result["roles"][role]["error"], "never step down a tier; report a loop failure.")

    def test_maker_policy_unknowns_and_writer_use(self):
        # Wrong: null/absent/blank maker or a caller maker claim proves independence.
        for candidate_maker, writer_maker, writer, reason in [
            (None, "anthropic", "manual", "candidate maker unknown; review independence unresolved"),
            ("", "anthropic", "manual", "candidate maker unknown; review independence unresolved"),
            ("openai", None, "manual", "writer maker unknown; review independence unresolved"),
            ("openai", "anthropic", "missing", "writer maker unknown; review independence unresolved"),
        ]:
            with self.subTest(candidate=candidate_maker, writer=writer_maker, family=writer):
                name = "go-iceman-contributor-free" if candidate_maker is None else "sol"
                config = manifest([route(name, maker=candidate_maker)])
                config["manualRoutes"][0]["family"]["maker"] = writer_maker
                ctx = context(("writer", "first-check"))
                ctx["roles"]["first-check"].update(writer=writer)
                result, _ = self.run_plan(config, ctx, ("writer", "first-check"))
                self.assertEqual(len(result["roles"]["writer"]["candidates"]), 1)
                self.assertEqual(result["roles"]["first-check"]["candidates"], [])
                self.assertEqual(result["roles"]["first-check"]["exclusions"][0]["reason"], reason)
        for writer in (None, "", " "):
            ctx = context(("first-check",))
            ctx["roles"]["first-check"]["writer"] = writer
            with self.subTest(writer=writer), self.assertRaisesRegex(ValueError, "first-check: review role requires writer family name"):
                self.run_plan(launch_context=ctx, roles=("first-check",))
        del ctx["roles"]["first-check"]["writer"]
        with self.assertRaisesRegex(ValueError, "first-check: review role requires writer family name"):
            self.run_plan(launch_context=ctx, roles=("first-check",))
        config = manifest()
        del config["routes"][0]["family"]["maker"]
        result, _ = self.run_plan(config, context(("first-check",)), ("first-check",))
        self.assertEqual(result["roles"]["first-check"]["candidates"], [])
        self.assertEqual(result["roles"]["first-check"]["exclusions"][0]["reason"], "candidate maker unknown; review independence unresolved")

    def test_maker_policy_judge_cut_proposer_and_tier_floor(self):
        # Wrong: judge checks only writer, or maker independence relaxes role floor.
        roles = ("finder", "first-check", "second-check", "judge")
        for maker, expected in [("openai", "same maker as cut proposer: openai"), (None, "cut proposer maker unknown; review independence unresolved"), ("google", None)]:
            config = manifest()
            config["manualRoutes"].append(route("critic", maker=maker))
            ctx = context(roles)
            ctx["roles"]["judge"]["cutProposer"] = "critic"
            result, _ = self.run_plan(config, ctx, roles)
            self.assertEqual(len(result["roles"]["first-check"]["candidates"]), 1)
            if expected:
                self.assertEqual(result["roles"]["judge"]["candidates"], [])
                self.assertEqual(result["roles"]["judge"]["exclusions"][0]["reason"], expected)
            else:
                self.assertEqual(len(result["roles"]["judge"]["candidates"]), 1)
        config = manifest([route(tier="mid")])
        result, _ = self.run_plan(config, context(roles), roles)
        for role in roles:
            self.assertEqual(result["roles"][role]["exclusions"][0]["reason"], "below role tier floor")
            self.assertEqual(result["roles"][role]["error"], "never step down a tier; report a loop failure.")

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
                result, _ = self.run_plan(config, context(), outputs={"reader-outside": stream({"5h": window(other, 18000, "2026-11-15T02:30:00Z")}), "reader-session": stream({"5h": window(own, 18000, "2026-11-15T02:30:00Z")})})
                self.assertEqual(result["roles"]["writer"]["candidates"][0]["launch"]["family"], expected)
        # Own pace leads despite the tighter buffer: max-share buffering fails.
        for remaining, expected in [(20, "other"), (20.01, "own")]:
            result, _ = self.run_plan(config, context(), outputs={"reader-session": stream({"monthly": window(60), "5h": window(remaining, 18000, "2026-11-15T00:30:00Z")})})
            self.assertEqual(result["roles"]["writer"]["candidates"][0]["launch"]["family"], expected)

    def test_live_claude_scopes_preserve_pool_measurement(self):
        # Wrong: any colon makes the pool unmeasured, or scopes set pool pace/buffer.
        for remaining in (52, 10, 0):
            with self.subTest(remaining=remaining):
                result, _ = self.run_plan(manifest([route("fable"), route("sol")]), context(), outputs={"reader-outside": stream({"7d": window(17, 604800, "2026-11-18T12:00:00Z"), "7d:fable": window(remaining, 604800, "2026-11-18T12:00:00Z")})})
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
        result, _ = self.run_plan(manifest([route("fable"), route("opus"), route("sol")]), context(), outputs={"reader-outside": stream(windows)})
        self.assertEqual(result["pools"]["outside"], {"buffer": 0.52, "pace": 1.04, "scopedPaces": {"7d:fable": 0.34, "7d:opus": None}, "status": "measured"})
        self.assertEqual({item["launch"]["family"]: item["pace"] for item in result["roles"]["writer"]["candidates"]}, {"fable": 0.34, "opus": 1.04, "sol": 1.04})

    def test_malformed_scopes_refuse_only_the_named_family(self):
        # Wrong: malformed scoped data fails the pool or silently drops its limit.
        cases = [
            ([], "window must be an object"),
            ({"remainingPercent": 50}, "'windowSeconds'"),
            (window(50, 604800, None), "unstarted null reset unresolved"),
            (window(50, 604800, "2026-11-14T00:00:00Z"), "expired reset or reset beyond window duration"),
            (window(101, 604800, None), "invalid remainingPercent/windowSeconds"),
        ]
        for value, reason in cases:
            with self.subTest(reason=reason):
                result, _ = self.run_plan(manifest([route("fable"), route("sol")]), context(), outputs={"reader-outside": stream({"7d": window(52, 604800, "2026-11-18T12:00:00Z"), "7d:fable": value})})
                self.assertEqual(result["pools"]["outside"]["status"], "measured")
                self.assertEqual(result["pools"]["outside"]["pace"], 1.04)
                self.assertEqual(result["pools"]["outside"]["buffer"], 0.52)
                self.assertEqual([(item["launch"]["family"], item["pace"]) for item in result["roles"]["writer"]["candidates"]], [("sol", 1.04)])
                self.assertEqual(result["roles"]["writer"]["exclusions"][-1]["reason"], "model-scoped window invalid")
                self.assertIn(f"outside: scoped window 7d:fable invalid; refusing its family: {reason}", result["warnings"])

    def test_invalid_scope_does_not_block_another_session_family(self):
        # Wrong: an invalid family's pool pace blocks a valid session candidate.
        result, _ = self.run_plan(manifest([route("fable"), route("sol", pool="session")], "session"), context(), outputs={"reader-outside": stream({"7d": window(52, 604800, "2026-11-18T12:00:00Z"), "7d:fable": window(50, 604800, None)})})
        self.assertEqual([(item["launch"]["family"], item["pace"]) for item in result["roles"]["writer"]["candidates"]], [("sol", 0.9375)])

    def test_scopes_are_limited_to_the_bound_pool_and_worst_window(self):
        # Wrong: a scope follows the family across pools, or last scoped window wins.
        config = manifest([route("fable"), route("fable", pool="session")])
        result, _ = self.run_plan(config, context(), outputs={"reader-outside": stream({"7d": window(52, 604800, "2026-11-18T12:00:00Z"), "5h:fable": window(10, 18000, "2026-11-15T02:30:00Z"), "7d:fable": window(17, 604800, "2026-11-18T12:00:00Z")})})
        self.assertEqual([(item["pool"], item["pace"]) for item in result["roles"]["writer"]["candidates"]], [("session", 0.9375), ("outside", 0.2)])

    def test_scoped_pace_ranking_and_session_comparison(self):
        # Wrong: applying family pace only at sorting, after the session comparison.
        config = manifest([route("fable", pool="session"), route("sol")], "session")
        outputs = {"reader-outside": stream({"7d": window(30, 604800, "2026-11-18T12:00:00Z")}), "reader-session": stream({"7d": window(52, 604800, "2026-11-18T12:00:00Z"), "7d:fable": window(17, 604800, "2026-11-18T12:00:00Z")})}
        result, _ = self.run_plan(config, context(), outputs=outputs)
        self.assertEqual([item["launch"]["family"] for item in result["roles"]["writer"]["candidates"]], ["sol"])
        self.assertEqual(result["roles"]["writer"]["exclusions"][-1]["reason"], "another fitting pool is ahead of session pace")
        # Scope share below 20% must not consume the session pool's buffer.
        outputs["reader-outside"] = stream({"7d": window(10, 604800, "2026-11-18T12:00:00Z")})
        result, _ = self.run_plan(config, context(), outputs=outputs)
        self.assertEqual([(item["launch"]["family"], item["pace"]) for item in result["roles"]["writer"]["candidates"]], [("fable", 0.34), ("sol", 0.2)])
        # The same family pace also ranks ordinary non-session candidates.
        config["sessionPool"] = None
        result, _ = self.run_plan(config, context(), outputs=outputs)
        self.assertEqual(result["roles"]["writer"]["candidates"][0]["pace"], 0.34)

    def test_unknown_scope_warns_without_failing_pool(self):
        # Wrong: silently ignoring a scope, or failing its otherwise valid pool.
        result, _ = self.run_plan(outputs={"reader-outside": stream({"7d": window(17, 604800, "2026-11-18T12:00:00Z"), "7d:unknown-model": window(0, 604800, "2026-11-18T12:00:00Z")})})
        self.assertEqual(result["pools"]["outside"]["status"], "measured")
        self.assertEqual(result["roles"]["writer"]["candidates"][0]["pace"], 0.34)
        self.assertIn("outside: scoped window 7d:unknown-model matches no configured family", result["warnings"])

    def test_unmeasured_streams_and_exhaustion(self):
        # Wrong: first-document-only parse, fabricated weekly resets, or accepting malformed windows.
        cases = [(stream() + "garbage", "Expecting value"), (stream() + "\n" + stream(), "account-to-route"), (stream({"5h": window(reset=None)}), "null reset"), (stream({"7d:fable": window()}), "missing unscoped windows"), (stream({"5h": window(reset="2026-11-14T00:00:00Z")}), "expired reset"), (stream({"5h": {"remainingPercent": 50}}), "windowSeconds"), (subprocess.TimeoutExpired("fake", 10), "timed out"), (subprocess.CompletedProcess("fake", 7, ""), "Reader exited 7"), (stream({"bad": []}), "window must be an object"), ("[]", "missing account"), (stream({"bad": window(float("nan"))}), "invalid remainingPercent"), (stream({"bad": window(reset="2027-01-01T00:00:00Z")}), "beyond window duration")]
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
        result, _ = self.run_plan(config, context())
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
            result, _ = self.run_plan(manifest([candidate]), context(roles), roles)
            for role in roles:
                self.assertEqual(bool(result["roles"][role]["candidates"]), tier in ("strong", "frontier"))
                if tier in ("small", "mid"):
                    self.assertEqual(result["roles"][role]["error"], "never step down a tier; report a loop failure.")
        with self.assertRaisesRegex(ValueError, "unknown role"):
            self.run_plan(roles=("unknown",))

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

    def prepared_manifest(self, config=None):
        config = deepcopy(config or manifest())
        config["routes"].append(route("author", pool=config["routes"][0]["pool"], maker="anthropic"))
        config.update({"classifierInstructions": "Classify only.\n", "classifiers": [{"family": "sol", "effort": "high"}], "familyCatalog": [item["family"] for item in config["routes"] + config["manualRoutes"]]})
        return config

    def prepared_context(self, ctx=None):
        ctx = deepcopy(ctx or context(("writer", "first-check", "second-check", "judge")))
        ctx["roles"]["writer"]["pins"] = {"family": "author"}
        for role, request in ctx["roles"].items():
            if helper.ROLE_POLICY[role]["review"]:
                request["writer"] = "author"
        return ctx

    def run_prepared_plan(self, config=None, launch_context=None, roles=("writer",), outputs=None):
        return self.run_plan(self.prepared_manifest(config), self.prepared_context(launch_context or context(roles)), roles, outputs)

    def test_plan_receipts_are_unit_local(self):
        # Wrong: one role-global candidate list authorizes opposite unit exclusions.
        config = self.prepared_manifest()
        config.update({"classifierInstructions": "Classify only.\n", "classifiers": [{"family": "sol", "effort": "high"}], "familyCatalog": [item["family"] for item in config["routes"] + config["manualRoutes"]]})
        roles = ("writer", "first-check", "second-check", "judge")
        current, _ = self.run_prepared_plan(roles=roles)
        facts = self.prepared_context()
        facts["roles"]["writer"].pop("pins")
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            for unit in artifact["units"]:
                for record in unit["launches"]:
                    brief = f"{unit['id']}-{record['role']}.md"
                    (root / brief).write_text(f"Actual unit {unit['id']} role {record['role']}\n" + (root / "rubric.md").read_text())
                    record.update(brief=brief, effort="high", requirements={"constraints": [], "inputKinds": ["text"]}, receipt=brief + ".json")
                    keep = {"0": {"writer": "author", "review": "sol"}, "1": {"writer": "sol", "review": "author"}}[unit["id"]]["writer" if record["role"] == "writer" else "review"]
                    previous = record["candidate"]["family"]
                    record["candidate"]["family"] = keep
                    record["line"] = record["line"].replace(f"family={previous}", f"family={keep}")
                    if keep != previous:
                        artifact["snapshot"]["roles"][record["role"]]["candidates"].append({"launch": deepcopy(record["candidate"]), "line": record["line"], "pool": "outside"})
                    save_plan_receipt(root, config, artifact, unit, record, keep)
            self.assertEqual(helper.check_plan(artifact, current, root, manifest=config, context=facts)["status"], "valid")
            self.assertEqual(current["unitRoles"]["1/writer"]["candidates"][0]["launch"]["family"], "sol")
            first, second = [unit["launches"][0] for unit in artifact["units"]]
            first["receipt"], second["receipt"] = second["receipt"], first["receipt"]
            with self.assertRaisesRegex(ValueError, "request hash mismatch"):
                helper.check_plan(artifact, current, root, manifest=config, context=facts)

    def test_ranker_refuses_caller_fit(self):
        # Wrong: the saved-plan path can still bypass receipts with caller essays.
        for field in ("families", "fit", "useFor", "avoidFor", "trial"):
            facts = context()
            facts["roles"]["writer"][field] = {"sol": {"fit": "essay"}} if field == "families" else "essay"
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "caller.*classification"):
                self.run_plan(launch_context=facts)

    def test_plan_reviewers_use_each_units_worker(self):
        # Wrong: one context writer certifies all units, including a Sol worker.
        roles = ("writer", "first-check", "second-check", "judge")
        ctx = self.prepared_context()
        ctx["roles"]["writer"].pop("pins")
        current, _ = self.run_plan(self.prepared_manifest(), ctx, roles)
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            cuts = deepcopy(ctx)
            artifact["units"][0]["launches"][-1]["cutProposer"] = "sol"
            with self.assertRaisesRegex(ValueError, "judge candidate/line absent.*same maker as cut proposer: openai"):
                helper.check_plan(artifact, current, root, manifest=self.prepared_manifest(), context=cuts)
            artifact["units"][0]["launches"][-1].pop("cutProposer")
            worker = artifact["units"][1]["launches"][0]
            worker["candidate"]["family"] = "sol"
            worker["line"] = "role=writer runtime=codex family=sol technique=spawn_agent model=gpt-6.1-sol effort=high"
            artifact["snapshot"]["roles"]["writer"]["candidates"].append({"launch": deepcopy(worker["candidate"]), "line": worker["line"], "pool": "outside"})
            with self.assertRaisesRegex(ValueError, "1: first-check candidate/line absent.*same maker as writer: openai"):
                helper.check_plan(artifact, current, root, manifest=self.prepared_manifest(), context=ctx)

    def prepared_plan(self, root, count=2):
        # Hand-authored launches: the plan cannot supply its own allowlist.
        rubric = b"1. Scope: change the assigned files.\n2. Checks: reject an invented launch.\n"
        (root / "rubric.md").write_bytes(rubric)
        roles = ("writer", "first-check", "second-check", "judge")
        launches = []
        for role in roles:
            brief = f"{role}.md"
            (root / brief).write_bytes(b"Hard rules and task.\n" + rubric + b"Report evidence.\n")
            launches.append({"brief": brief, "candidate": {"agent": None, "effort": "high", "family": "author" if role == "writer" else "sol", "guidance": {"command": "MUST NEVER EXECUTE THIS LAUNCH", "modelArg": "slug", "notes": "caller binds task/output paths"}, "model": "gpt-6.1-sol", "runtime": "codex", "technique": "spawn_agent"}, "line": f"role={role} runtime=codex family={'author' if role == 'writer' else 'sol'} technique=spawn_agent model=gpt-6.1-sol effort=high", "role": role, "runtime": "codex"})
        units = [{"audience": "routing maintainer", "checks": [f"checks/{index}.py"], "dependencies": [], "docs": [f"docs/{index}.md"], "files": [f"src/{index}.py", f"checks/{index}.py", f"docs/{index}.md"], "goal": "replace not validated launch choices", "id": str(index), "launches": deepcopy(launches), "size": {"code": {"added": 20, "removed": 5}, "docs": {"added": 5, "removed": 0}, "tests": {"added": 30, "removed": 0}}, "verification": {"command": f"python3 checks/{index}.py", "wrongImplementation": "accepts invented launch choices"}} for index in range(count)]
        artifact = {"rubric": "rubric.md", "runtime": "codex", "snapshot": {"automaticRuntimes": ["codex"], "manualOnly": [], "pools": {"outside": {"buffer": 0.5, "pace": 0.9375, "status": "measured"}}, "roles": {record["role"]: {"candidates": [{"launch": record["candidate"], "line": record["line"], "pool": "outside"}], "exclusions": []} for record in launches}, "runtime": "codex", "sessionPool": None, "snapshot": "2026-11-14T00:00:00Z", "warnings": ["session pool unknown; buffer rule cannot be certified"]}, "task": "validate assigned routing work", "units": units, "waves": [[str(index) for index in range(count)]]}

        config = self.prepared_manifest()
        for unit in units:
            for record in unit["launches"]:
                record.update(effort="high", requirements={"constraints": [], "inputKinds": ["text"]}, receipt=f"{unit['id']}-{record['role']}.json")
                save_plan_receipt(root, config, artifact, unit, record)
        return artifact

    def test_planner_bootstrap_floor_native_and_workflow(self):
        # Wrong: planner unregistered, high-pace mid chosen, or no pinned bootstrap.
        config = manifest([route("fast", "mid", "session"), route("design", "frontier")])
        for node in (technique(), technique("Workflow", "workflow")):
            config["routes"][1]["techniques"] = [node]
            ctx = context(("planner",), techniques=[{"efforts": ["high"], "model": "gpt-6.1-sol", "runtime": "codex", "technique": node["name"]}], non_interactive=True)
            result, _ = self.run_plan(config, ctx, ("planner",), outputs={"reader-session": stream({"monthly": window(99)})})
            self.assertEqual(result["roles"]["planner"]["candidates"][0]["launch"]["family"], "design")
            self.assertIn({"family": "fast", "reason": "below role tier floor", "runtime": "codex"}, result["roles"]["planner"]["exclusions"])
        config["routes"] = [route("fast", "mid")]
        result, _ = self.run_plan(config, context(("planner",)), ("planner",))
        self.assertEqual(result["roles"]["planner"]["error"], "never step down a tier; report a loop failure.")

    def test_plan_role_qualified_launch_mutations(self):
        # Wrong: transcript substring match, trusting saved candidates, stale context.
        roles = ("writer", "first-check", "second-check", "judge")
        current, _ = self.run_prepared_plan(roles=roles)
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            self.assertEqual(helper.check_plan(artifact, current, root, manifest=self.prepared_manifest(), context=self.prepared_context()), {"status": "valid", "task": "validate assigned routing work", "units": 2, "waves": 1})
            for field, value in (("effort", "low"), ("family", "manual"), ("model", "invented"), ("technique", "absent"), ("model", "gpt-*-sol")):
                with self.subTest(field=field, value=value):
                    changed = deepcopy(artifact)
                    changed["units"][0]["launches"][0]["candidate"][field] = value
                    with self.assertRaisesRegex(ValueError, "absent from current helper output"):
                        helper.check_plan(changed, current, root, manifest=self.prepared_manifest(), context=self.prepared_context())
            for field, value, reason in (("line", "role=judge runtime=codex family=sol technique=spawn_agent model=gpt-6.1-sol effort=high", "absent from current"), ("role", "finder", "one worker"), ("runtime", "claude", "own helper validation")):
                changed = deepcopy(artifact)
                changed["units"][0]["launches"][0][field] = value
                with self.assertRaisesRegex(ValueError, reason):
                    helper.check_plan(changed, current, root, manifest=self.prepared_manifest(), context=self.prepared_context())
            changed = deepcopy(current)
            changed["roles"] = {}
            self.assertEqual(helper.check_plan(artifact, changed, root, manifest=self.prepared_manifest(), context=self.prepared_context())["status"], "valid")
            changed = deepcopy(artifact)
            changed["runtime"] = "claude"
            with self.assertRaisesRegex(ValueError, "actual launching runtime"):
                helper.check_plan(changed, current, root, manifest=self.prepared_manifest(), context=self.prepared_context())
            changed = deepcopy(artifact)
            changed["snapshot"]["runtime"] = "claude"
            with self.assertRaisesRegex(ValueError, "saved helper snapshot"):
                helper.check_plan(changed, current, root, manifest=self.prepared_manifest(), context=self.prepared_context())
            # Even a saved allowlist containing a forged model cannot approve it.
            changed = deepcopy(artifact)
            for launch in (changed["units"][0]["launches"][0], changed["snapshot"]["roles"]["writer"]["candidates"][0]):
                candidate = launch.get("candidate", launch.get("launch"))
                candidate["model"] = "invented"
            with self.assertRaisesRegex(ValueError, "absent from current helper output"):
                helper.check_plan(changed, current, root, manifest=self.prepared_manifest(), context=self.prepared_context())
            # A new context or budget decision, not the old plan's snapshot, wins.
            for ctx, outputs in ((context(roles), {"reader-outside": stream({"monthly": window(0)})}),):
                changed, _ = self.run_prepared_plan(launch_context=ctx, roles=roles, outputs=outputs)
                with self.assertRaisesRegex(ValueError, "absent from current helper output"):
                    helper.check_plan(artifact, changed, root, manifest=self.prepared_manifest(), context=self.prepared_context())
            config = manifest([route(pool=None)])
            config["readers"] = []
            fit_only, _ = self.run_prepared_plan(config, roles=roles)
            self.assertEqual(helper.check_plan(artifact, fit_only, root, manifest=self.prepared_manifest(), context=self.prepared_context())["status"], "valid")
            self.assertEqual(fit_only["roles"]["writer"]["candidates"][0]["budget"], "fit-only; budget and session buffer unknown")

    def test_plan_rejects_recursive_planner(self):
        # Wrong: a valid planner candidate can recursively plan an approved unit.
        current, _ = self.run_prepared_plan(roles=("writer", "first-check", "second-check", "judge", "planner"))
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            launch = deepcopy(artifact["units"][0]["launches"][0])
            launch.update(role="planner", candidate=current["roles"]["planner"]["candidates"][0]["launch"], line=current["roles"]["planner"]["candidates"][0]["line"])
            artifact["units"][0]["launches"].append(launch)
            with self.assertRaisesRegex(ValueError, "only worker and reviewer roles"):
                helper.check_plan(artifact, current, root, manifest=self.prepared_manifest(), context=self.prepared_context())

    def test_plan_artifact_paths_stay_relative(self):
        # Wrong: joining an absolute or upward rubric/brief path reads outside.
        current, _ = self.run_prepared_plan(roles=("writer", "first-check", "second-check", "judge"))
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            nested = root / "plans"
            nested.mkdir()
            for path in list(root.glob("*.md")) + list(root.glob("*.json")):
                (nested / path.name).write_bytes(path.read_bytes())
            for field, filename in (("rubric", "rubric.md"), ("brief", "writer.md"), ("receipt", "0-writer.json")):
                for path in (str(root / filename), f"../{filename}"):
                    changed = deepcopy(artifact)
                    target = changed if field == "rubric" else changed["units"][0]["launches"][0]
                    target[field] = path
                    with self.subTest(field=field, path=path), self.assertRaisesRegex(ValueError, "plan-relative.*absolute or upward"):
                        helper.check_plan(changed, current, nested, manifest=self.prepared_manifest(), context=self.prepared_context())

    def test_plan_artifact_symlinks_stay_inside_directory(self):
        # Wrong: relative symlinks let rubric/brief reads escape the plan directory.
        current, _ = self.run_prepared_plan(roles=("writer", "first-check", "second-check", "judge"))
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            nested = root / "plan"
            nested.mkdir()
            artifact = self.prepared_plan(nested)
            for field, filename in (("rubric", "rubric.md"), ("brief", "writer.md"), ("receipt", "0-writer.json")):
                (root / filename).write_bytes((nested / filename).read_bytes())
                (nested / f"link-{filename}").symlink_to(f"../{filename}")
                changed = deepcopy(artifact)
                target = changed if field == "rubric" else changed["units"][0]["launches"][0]
                target[field] = f"link-{filename}"
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, "inside the plan directory"):
                    helper.check_plan(changed, current, nested, manifest=self.prepared_manifest(), context=self.prepared_context())

    def test_plan_requires_complete_helper_snapshot(self):
        # Wrong: accepting provenance without the helper's runtime/route warnings.
        current, _ = self.run_prepared_plan(roles=("writer", "first-check", "second-check", "judge"))
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            for field in ("automaticRuntimes", "manualOnly", "sessionPool", "warnings"):
                changed = deepcopy(artifact)
                del changed["snapshot"][field]
                with self.subTest(missing=field), self.assertRaisesRegex(ValueError, "complete helper snapshot"):
                    helper.check_plan(changed, current, root, manifest=self.prepared_manifest(), context=self.prepared_context())

    def test_plan_snapshot_requires_launched_candidates_and_bound_pools(self):
        # Wrong: empty or partial role/pool maps count as captured helper output.
        current, _ = self.run_prepared_plan(roles=("writer", "first-check", "second-check", "judge"))
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
                    helper.check_plan(changed, current, root, manifest=self.prepared_manifest(), context=self.prepared_context())

    def test_plan_dependencies_waves_and_ownership(self):
        # Wrong: cycle acceptance, ordering ignored, runtime cap, forced serialization.
        current, _ = self.run_prepared_plan(roles=("writer", "first-check", "second-check", "judge"))
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
            cases.append((changed, "request hash mismatch"))
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
                    helper.check_plan(changed, current, root, manifest=self.prepared_manifest(), context=self.prepared_context())
            artifact["units"][1]["dependencies"] = ["0"]
            artifact["waves"] = [["0"], ["1"]]
            self.assertEqual(helper.check_plan(artifact, current, root, 4, manifest=self.prepared_manifest(), context=self.prepared_context())["waves"], 2)
            # Wrong: sequential worker/review launches consume separate wave slots.
            ten_units = self.prepared_plan(root, 10)
            self.assertEqual(helper.check_plan(ten_units, current, root, manifest=self.prepared_manifest(), context=self.prepared_context()), {"status": "valid", "task": "validate assigned routing work", "units": 10, "waves": 1})
            with self.assertRaisesRegex(ValueError, "1..9 concurrent units"):
                helper.check_plan(ten_units, current, root, 9, manifest=self.prepared_manifest(), context=self.prepared_context())
            with self.assertRaisesRegex(ValueError, "1..10 concurrent units"):
                helper.check_plan(self.prepared_plan(root, 11), current, root, manifest=self.prepared_manifest(), context=self.prepared_context())
            with self.assertRaisesRegex(ValueError, "1..1 concurrent units"):
                helper.check_plan(self.prepared_plan(root), current, root, 1, manifest=self.prepared_manifest(), context=self.prepared_context())

    def test_prepared_brief_rubric_bytes(self):
        # Wrong: rubric paths/summary/one mutated row accepted as full rubric.
        current, _ = self.run_prepared_plan(roles=("writer", "first-check", "second-check", "judge"))
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            for role in ("writer", "first-check", "second-check", "judge"):
                brief = root / f"{role}.md"
                original = brief.read_bytes()
                for replacement in (b"See rubric.md", b"1. Scope: change the assigned files.\n", original.replace(b"invented", b"supported")):
                    brief.write_bytes(replacement)
                    with self.subTest(role=role), self.assertRaisesRegex(ValueError, "full rubric verbatim"):
                        helper.check_plan(artifact, current, root, manifest=self.prepared_manifest(), context=self.prepared_context())
                brief.write_bytes(original)
            self.assertEqual(helper.check_plan(artifact, current, root, manifest=self.prepared_manifest(), context=self.prepared_context())["status"], "valid")

    def test_check_plan_cli_uses_current_readers_and_briefs(self):
        # Wrong: check-plan bypasses the production Reader/CLI path or launches.
        with tempfile.TemporaryDirectory(prefix="routing-artifact-") as directory:
            root = Path(directory)
            artifact = self.prepared_plan(root)
            config = self.prepared_manifest()
            log = root / "reads"
            config["readers"] = [{"command": f"printf 'outside\\n' >> '{log}'; printf '%s' '{stream()}'", "name": "outside"}]
            roles = ("writer", "first-check", "second-check", "judge")
            for name, value in (("plan", artifact), ("manifest", config), ("context", self.prepared_context())):
                (root / f"{name}.json").write_text(json.dumps(value))
            command = [sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--reader-shell", SHELL, "--launch-context", str(root / "context.json"), "--check-plan", str(root / "plan.json"), "--now", "2026-11-15T00:00:00Z"]
            for role in roles:
                command.extend(["--role", role])
            # Wrong: invalid caps skip collection and discard the failure envelope.
            for cap in (0, 11):
                with self.subTest(cap=cap):
                    proc = subprocess.run(command + ["--max-concurrency", str(cap)], capture_output=True, text=True)
                    self.assertEqual(proc.returncode, 2)
                    self.assertIn("argument --max-concurrency: invalid choice", proc.stderr)
                    self.assertEqual(json.loads(proc.stdout)["status"], "error")
                    self.assertEqual(sorted(json.loads(proc.stdout)["pools"]), ["outside"])
                    self.assertEqual(log.read_text(), "outside\n")
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
            self.assertEqual(json.loads(proc.stdout)["status"], "error")
            self.assertEqual(sorted(json.loads(proc.stdout)["pools"]), ["outside"])
            self.assertEqual(log.read_text(), "outside\noutside\n")

            (root / "writer.md").write_text("Hard rules and task.\n" + (root / "rubric.md").read_text() + "Report evidence.\n")
            facts = self.prepared_context()
            facts["roles"]["writer"]["pins"] = {"family": "absent"}
            (root / "context.json").write_text(json.dumps(facts))
            proc = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2)
            self.assertEqual(json.loads(proc.stdout)["decisions"]["0/writer"]["pins"], {"family": "absent"})
            self.assertIn("pin: 0/writer family=absent", proc.stderr)
            facts["roles"]["writer"]["families"] = {}
            (root / "context.json").write_text(json.dumps(facts))
            proc = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2)
            self.assertIn("caller fit/families/useFor/avoidFor/trial fields are refused", proc.stderr)
            self.assertIn("--role classifier --classify-role", proc.stderr)

    def test_real_cli_only_fake_reader_and_nonzero_loop(self):
        # Exact CLI path exercises shell collection; launch command is a sentinel.
        with tempfile.TemporaryDirectory(prefix="routing-plan-check-") as directory:
            root = Path(directory)
            config = manifest()
            config.update({"classifierInstructions": "Classify only.\n", "classifiers": [{"family": "sol", "effort": "high"}], "familyCatalog": [route()["family"]], "manualRoutes": []})
            log = root / "reads"
            config["readers"] = [
                {"name": name, "command": f"printf '{name}\\n' >> '{log}'; printf '%s' '{stream()}'"}
                for name in ("outside", "session", "hidden")
            ]
            config["readers"].append({"name": "alias", "command": config["readers"][0]["command"]})
            (root / "manifest.json").write_text(json.dumps(config))
            facts = {"roles": {"writer": {"brief": "brief.md", "effort": "high", "requirements": {"constraints": [], "inputKinds": ["text"]}}}, "rubric": "rubric.md", "subject": {"task": "task", "unit": "one"}, "techniques": context()["techniques"]}
            (root / "brief.md").write_text("Actual brief\n")
            (root / "rubric.md").write_text("Actual rubric\n")
            (root / "context.json").write_text(json.dumps(facts))
            command = [sys.executable, str(SOURCE), "--manifest", str(root / "manifest.json"), "--reader-shell", SHELL, "--launch-context", str(root / "context.json"), "--now", "2026-11-15T00:00:00Z", "--role", "writer"]
            proc = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 3, proc.stderr)
            self.assertEqual(log.read_text(), "outside\nsession\nhidden\n")
            self.assertEqual(json.loads(proc.stdout)["status"], "classification-required")
            self.assertEqual(json.loads(proc.stdout)["errors"], [])
            self.assertEqual(json.loads(proc.stdout)["pools"]["outside"]["pace"], 0.9375)
            preparation_command = command[:-2] + ["--role", "classifier", "--classify-role", "writer"]
            proc = subprocess.run(preparation_command, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            prepared = json.loads(proc.stdout)["classification"]
            exchange = {"preparation": prepared, "result": {"schemaVersion": 1, "requestHash": prepared["requestHash"], "decisions": [{"family": "sol", "decision": "keep", "reason": "Matches supplied criteria."}]}}
            (root / "exchange.json").write_text(json.dumps(exchange))
            proc = subprocess.run(command + ["--classification", str(root / "exchange.json")], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            receipt = json.loads(proc.stdout)["receipt"]
            (root / "receipt.json").write_text(json.dumps(receipt))
            reuse = command + ["--receipt", str(root / "receipt.json")]
            proc = subprocess.run(reuse, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertNotIn("classification", json.loads(proc.stdout))
            self.assertEqual(log.read_text(), "outside\nsession\nhidden\n" * 4)
            facts["techniques"] = []
            (root / "context.json").write_text(json.dumps(facts))
            proc = subprocess.run(reuse, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 1)
            self.assertEqual(json.loads(proc.stdout)["status"], "error")
            self.assertEqual(json.loads(proc.stdout)["errors"], ["writer: never step down a tier; report a loop failure."])
            self.assertIn("never step down a tier; report a loop failure.", proc.stderr)


if __name__ == "__main__":
    unittest.main()
