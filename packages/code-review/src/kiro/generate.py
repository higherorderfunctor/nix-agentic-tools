#!/usr/bin/env python3
"""Materialize a Kiro v3 native review arm from explicit model/effort choices."""
import argparse
import hashlib
import json
import re
import shlex
import sys
from pathlib import Path

ROLES = ("coordinator", "dedupe", "defense", "evidence", "finalize", "judge", "lens", "refine", "surface")
STAGES = ("lens", "refine", "surface", "dedupe", "adjudicate", "finalize")
EFFORTS = {"low", "medium", "high", "xhigh", "max"}
ROOT = Path(__file__).resolve().parent
SHARED = ROOT.parent / "shared" / "review.py"


def read_profile(path):
    profile = json.loads(path.read_text())
    if set(profile["roles"]) != set(ROLES):
        raise ValueError(f"profile.roles must contain exactly {', '.join(ROLES)}")
    for role, setting in profile["roles"].items():
        model = setting.get("model_id", "")
        if not model or model == "auto" or re.search(r"[<>\s]", model):
            raise ValueError(f"{role}: provide an explicit served model_id")
        if setting.get("effort") not in EFFORTS and not (role == "coordinator" and setting.get("effort") == "default"):
            raise ValueError(f"{role}: provide an explicit effort")
    if not isinstance(profile.get("limits", {}).get("concurrency"), int) or not 1 <= profile["limits"]["concurrency"] <= 6:
        raise ValueError("limits.concurrency must be 1..6")
    if not isinstance(profile.get("limits", {}).get("max_waves"), int) or not 1 <= profile["limits"]["max_waves"] <= 1000:
        raise ValueError("limits.max_waves must be 1..1000")
    if profile.get("defense_policy", "when-requested") != "when-requested":
        raise ValueError("only when-requested defense is implemented")
    return profile


def cli(run_dir, arm, operation, *arguments, helper=SHARED, python=sys.executable):
    return shlex.join([python, str(helper), operation, "--run-dir", str(run_dir), "--arm", arm, *arguments])


def run_key(run_dir):
    return hashlib.sha256(str(run_dir.resolve()).encode()).hexdigest()[:10]


def agent_name(role, profile):
    identity = hashlib.sha256(json.dumps(profile, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()[:10]
    return f"code-review-{identity}-{role}"


def build_recipe(workspace, run_dir, arm, profile, *, helper=SHARED, adapter=ROOT, python=sys.executable):
    """One graph definition shared by runnable materialization and saved example."""
    relative_run = run_dir.relative_to(workspace)

    def command(operation, *arguments):
        return cli(run_dir, arm, operation, *arguments, helper=helper, python=python)

    def watch(stage=None, operation="tasks"):
        node_id = f"prepare-{stage}" if stage else operation
        config = {"arm": arm, "command": shlex.join([python, str(adapter / "watch.py")]), "commandTimeoutSec": 60, "helper": str(helper), "operation": operation, "pollIntervalSec": 10, "run_dir": str(run_dir)}
        if stage:
            config["stage"] = stage
        return {"type": "watch", "id": node_id, "handler": "command", "config": config}

    def step(role, node_id, prompt):
        setting = profile["roles"][role]
        return {"type": "step", "id": node_id, "agent": agent_name(role, profile), "prompt": prompt, "captureOutput": True, "modelId": setting["model_id"], **({"effortLevel": setting["effort"]} if setting["effort"] != "default" else {})}

    def worker(stage, lane):
        role = "coordinator" if stage == "adjudicate" else stage
        worker_id = f"{stage}-{lane}"
        claim_arguments = ["--stage", stage, "--worker", worker_id]
        if role == "coordinator":
            claim_arguments.append("--control-only")
        claim = command("claim", *claim_arguments)
        prompt = f"RUN_DIR: {run_dir}. ARM: {arm}. Claim exactly ONE task: {claim}. If task is null return SLOT_EMPTY immediately; never infer a global completion. Worker ID: {worker_id}. "
        if role == "coordinator":
            prompt += "Coordinate this one claim using fresh evidence, optional defense and judge roles according to your instructions. Return TASK_COMPLETE only after actual judge submit receipt complete=true."
        else:
            prompt += f"For the claimed TASK_ID run {command('payload', '--task', 'TASK_ID')}. Execute only that payload. Write result to {run_dir}/receipts/TASK_ID.{stage}.PROPOSAL_ID.json and run {command('submit', '--task', 'TASK_ID', '--result', str(run_dir / 'receipts' / f'TASK_ID.{stage}.PROPOSAL_ID.json'), '--proposal-id', 'PROPOSAL_ID')}. Return actual submit control JSON."
        return {"type": "repeat", "id": f"drain-{worker_id}", "maxIterations": 1000, "onMaxIterations": "pause", "stopCondition": {"containsText": "SLOT_EMPTY"}, "steps": [step(role, worker_id, prompt)]}

    wave_steps = []
    for stage in STAGES:
        wave_steps.append(watch(stage))
        if stage in {"adjudicate", "lens", "surface"}:
            wave_steps.append({"type": "parallel", "id": f"pool-{stage}", "joinPolicy": "allSettled", "branches": [worker(stage, lane) for lane in range(profile["limits"]["concurrency"])]})
        else:
            wave_steps.append(worker(stage, "holistic")["steps"][0])
    wave_steps.append(watch(operation="next-wave"))
    setting = profile["roles"]["coordinator"]
    recipe = {
        "name": f"prepared-review-{arm}-{run_key(run_dir)}",
        "description": "Prepared input to local report; native Kiro v3 orchestration with fresh claim roles.",
        "inputs": {},
        "injectOriginalUserRequest": False,
        "modelId": setting["model_id"],
        "steps": [
            {"type": "repeat", "id": "review-waves", "maxIterations": profile["limits"]["max_waves"], "onMaxIterations": "continue", "stopCondition": {"fileCheck": {"path": str(relative_run / "kiro-next-wave.json"), "jsonPath": "continue", "value": False}}, "steps": wave_steps},
            watch(operation="report"),
        ],
    }
    if setting["effort"] != "default":
        recipe["effortLevel"] = setting["effort"]
    return recipe


def materialize(workspace, run_dir, arm, profile):
    workspace = workspace.resolve()
    run_dir = run_dir.resolve()
    try:
        run_dir.relative_to(workspace)
    except ValueError as error:
        raise ValueError("run-dir must be inside workspace for native fileCheck") from error
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,47}", arm):
        raise ValueError("arm must be a safe lowercase slug")
    state_path = run_dir / "state.json"
    state = json.loads(state_path.read_text())
    if (state.get("arm") != arm or state.get("runtime") != "kiro-cli"
            or state.get("profile") != profile
            or state.get("max_waves") != profile["limits"]["max_waves"]):
        raise ValueError("prepared arm/runtime/profile/max_waves disagree with native configuration")
    workflows = workspace / ".kiro" / "workflows"
    workflows.mkdir(parents=True, exist_ok=True)
    receipt_dir = run_dir / "receipts"
    receipt_dir.mkdir(parents=True, exist_ok=True)
    recipe = build_recipe(workspace, run_dir, arm, profile)
    recipe_path = workflows / f"code-review-{arm}-{run_key(run_dir)}.workflow.json"
    recipe_path.write_text(json.dumps(recipe, indent=2, sort_keys=True) + "\n")
    manifest = {"arm": arm, "profile": profile, "profile_digest": state["provenance"]["profile_digest"], "runtime": "kiro-cli", "workflow": str(recipe_path), "configuration_status": "wired; provider-effective settings untested", "coordinator_effort": profile["roles"]["coordinator"]["effort"]}
    (run_dir / "kiro-adapter.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return recipe_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--run-dir", type=Path)
    parser.add_argument("--arm")
    parser.add_argument("--profile", type=Path)
    args = parser.parse_args()
    if not all((args.workspace, args.run_dir, args.arm, args.profile)):
        parser.error("materialization requires --workspace, --run-dir, --arm and --profile")
    try:
        profile = read_profile(args.profile)
        workflow = materialize(args.workspace, args.run_dir, args.arm, profile)
    except (KeyError, OSError, TypeError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps({"workflow": str(workflow), "run_dir": str(args.run_dir.resolve()), "runtime": "kiro-cli"}, sort_keys=True))


if __name__ == "__main__":
    main()
