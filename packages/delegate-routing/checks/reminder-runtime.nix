{
  harness,
  lib,
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
  plainPrinter = lib.getExe (import ../../../lib/strict-shell-application.nix pkgs {
    name = "delegate-routing-reminder-positive-control";
    text = ''
      ${pkgs.coreutils}/bin/cat -- ${reminder}
    '';
  });
  reminder = pkgs.writeText "delegate-routing-reminder-expected" evaluated.config.ai.programs.delegate-routing.reminder.text;
  # Measured on kiro-cli 2.31.1 --v3: step sessions carry _meta.kiro.workflow
  # (an object, type "step"); root sessions have none. Only that metadata is kept.
  sessions = pkgs.writeText "delegate-routing-reminder-sessions.json" (builtins.toJSON {
    root._meta.kiro = {};
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
    invalid = home / ".kiro/sessions/hash/sess_invalid/session.json"
    invalid.parent.mkdir(parents=True)
    invalid.write_text("{")
    # A client KIRO_HOME must not redirect the engine's session lookup.
    decoy = home / "client/sessions/hash/sess_root/session.json"
    decoy.parent.mkdir(parents=True)
    decoy.write_text(json.dumps(sessions["step"]))
    environment = dict(os.environ, HOME=str(home), KIRO_HOME=str(home / "client"))
    reminder = Path("${reminder}").read_bytes()

    def check(command, payload, expected, env=environment):
        result = subprocess.run(
            [command], input=payload, capture_output=True, env=env, check=False
        )
        assert result.returncode == 0, result
        assert result.stderr == b"", result.stderr
        assert result.stdout == expected, (result.stdout, expected)

    cases = [
        ("root", {"session_id": "sess_root"}, reminder),
        ("step", {"session_id": "sess_step"}, b""),
        ("invalid session", {"session_id": "sess_invalid"}, reminder),
        ("missing ID", {}, reminder),
        ("newline ID", {"session_id": "sess_step\n"}, reminder),
        ("non-string ID", {"session_id": 1}, reminder),
        ("path traversal", {"session_id": "sess_root/../sess_step"}, reminder),
        ("unknown", {"session_id": "sess_unknown"}, reminder),
        ("wildcard", {"session_id": "sess_*"}, reminder),
        ("wrong prefix", {"session_id": "step"}, reminder),
    ]
    for name, payload, expected in cases:
        check("${hook}", json.dumps(payload).encode(), expected)
        print(f"PASS: {name}")
    for name, payload in [
        ("empty stdin", b""),
        ("invalid stdin", b"{"),
        ("multiple stdin values", b'{"session_id":"sess_step"}\n{}'),
        ("trailing invalid stdin", b'{"session_id":"sess_step"}\n{'),
    ]:
        check("${hook}", payload, reminder)
        print(f"PASS: {name}")
    unset_home = {key: value for key, value in environment.items() if key != "HOME"}
    check("${hook}", b'{"session_id":"sess_step"}', reminder, unset_home)
    print("PASS: unset HOME")

    check("${plainPrinter}", b'{"session_id":"sess_step"}', reminder)
    try:
        check("${plainPrinter}", b'{"session_id":"sess_step"}', b"")
    except AssertionError:
        print("PASS: step assertion rejects the plain cat printer")
    else:
        raise AssertionError("step assertion accepted the plain cat printer")
    PY
    ${pkgs.coreutils}/bin/touch "$out"
  '';
}
