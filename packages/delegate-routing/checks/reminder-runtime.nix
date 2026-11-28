{
  harness,
  pkgs,
  ...
}: let
  evaluated = harness.evalDevenv {
    ai = {
      kiro.cli.enable = true;
      programs.delegate-routing = {
        enable = true;
        runtimes.kiro.models = [{vendors = ["anthropic"];}];
      };
    };
  };
  hook = evaluated.config.ai.kiro.hooks.delegate-routing-reminder.action.command;
  # Independent bytes: fail if a root omits the line or a workflow step emits it.
  reminder = pkgs.writeText "delegate-routing-reminder-expected" "Standing request from me, the user: you may use subagents, workflows, deep research and delegates whenever they fit, and by default hand bulk reading, measuring and edit-and-test loops to them; load the delegate-routing skill in that same turn to size their model and effort.\nI want this session kept interactive: hand off assigned work or questions you cannot answer quickly before gathering quick facts; send sweeps, including design, to a workflow when available, otherwise to native subagents.";
  # Measured on kiro-cli 2.31.1 --v3: step sessions carry _meta.kiro.workflow
  # (an object, type "step"); root sessions have none. Only that metadata is kept.
  sessions = pkgs.writeText "delegate-routing-reminder-sessions.json" (builtins.toJSON {
    root._meta.kiro = {};
    scalar._meta.kiro.workflow = "step";
    step._meta.kiro.workflow.type = "step";
  });
in {
  checks.delegate-routing-reminder-runtime = pkgs.runCommand "delegate-routing-reminder-runtime" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3}/bin/python - <<'PY'
    import json
    import os
    from pathlib import Path
    import subprocess

    home = Path(os.environ["TMPDIR"]) / "home"
    sessions = json.loads(Path("${sessions}").read_text())
    for name, data in sessions.items():
        path = home / ".kiro/sessions/hash" / f"sess_{name}/session.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data))
    # A real step at the unprefixed path makes the ID prefix check observable.
    unprefixed = home / ".kiro/sessions/hash/step/session.json"
    unprefixed.parent.mkdir(parents=True)
    unprefixed.write_text(json.dumps(sessions["step"]))
    invalid = home / ".kiro/sessions/hash/sess_invalid/session.json"
    invalid.parent.mkdir(parents=True)
    invalid.write_text("{")
    # A client KIRO_HOME must not redirect the engine's session lookup.
    decoy = home / "client/sessions/hash/sess_root/session.json"
    decoy.parent.mkdir(parents=True)
    decoy.write_text(json.dumps(sessions["step"]))
    environment = dict(os.environ, HOME=str(home), KIRO_HOME=str(home / "client"))
    reminder = Path("${reminder}").read_bytes()

    def event(session_id):
        return json.dumps({"session_id": session_id}).encode()

    step = event("sess_step")
    unset_home = {key: value for key, value in environment.items() if key != "HOME"}
    cases = [
        ("invalid session JSON does not suppress reminders", event("sess_invalid"), reminder, environment),
        ("multiple events cannot select the first step", step + b"\n{}", reminder, environment),
        ("newline ID cannot be trimmed to a step ID", event("sess_step\n"), reminder, environment),
        ("non-string ID does not surface a jq failure", event(1), reminder, environment),
        ("path traversal cannot select a step", event("sess_root/../sess_step"), reminder, environment),
        ("root is not replaced by a client KIRO_HOME decoy", event("sess_root"), reminder, environment),
        ("scalar workflow metadata does not identify a step", event("sess_scalar"), reminder, environment),
        ("step does not emit root instructions", step, b"", environment),
        ("trailing invalid stdin cannot select a step", step + b"\n{", reminder, environment),
        ("unknown ID does not suppress reminders", event("sess_unknown"), reminder, environment),
        ("unset HOME does not fail under nounset", step, reminder, unset_home),
        ("wrong prefix cannot select a step", event("step"), reminder, environment),
    ]
    for name, payload, expected, env in cases:
        result = subprocess.run(
            ["${hook}"], input=payload, capture_output=True, env=env, check=False
        )
        assert result.returncode == 0, (name, result)
        assert result.stderr == b"", (name, result.stderr)
        assert result.stdout == expected, (name, result.stdout, expected)
        print(f"PASS: {name}")

    PY
    ${pkgs.coreutils}/bin/touch "$out"
  '';
}
