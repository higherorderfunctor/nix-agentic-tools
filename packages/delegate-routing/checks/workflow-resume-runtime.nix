# Reject trusted-project noise, wrong trust keys, strict-mode crashes and bad JSON.
{
  harness,
  pkgs,
  ...
}: let
  evaluated = harness.evalDevenv {
    ai.claude.enable = true;
    ai.programs.delegate-routing.enable = true;
  };
  hook = (builtins.head (builtins.head evaluated.config.ai.claude.hooks.SessionStart).hooks).command;
in {
  checks.delegate-routing-workflow-resume-runtime = pkgs.runCommand "delegate-routing-workflow-resume-runtime" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3}/bin/python - <<'PYTHON'
    import json
    import os
    from pathlib import Path
    import subprocess

    home = Path(os.environ["TMPDIR"]) / "home with spaces"
    state = home / ".claude/.claude.json"
    state.parent.mkdir(parents=True)
    environment = dict(os.environ, HOME=str(home))
    project = '/project with "quotes"'
    message = {"systemMessage": project + " is not a trusted Claude Code project; its project settings did not apply. The launcher appended --add-dir ~/.claude/projects so Workflow resume keeps working."}

    def check(payload, expected, env=environment):
        result = subprocess.run(
            ["${hook}"], input=payload, capture_output=True, env=env, check=False
        )
        assert result.returncode == 0, result
        assert result.stderr == b"", result.stderr
        if expected is None:
            assert result.stdout == b"", result.stdout
        else:
            assert json.loads(result.stdout) == expected, result.stdout

    payload = json.dumps({"cwd": project}).encode()
    state.write_text(json.dumps({"projects": {project: {"hasTrustDialogAccepted": True}}}))
    check(payload, None)
    # Onboarding is not trust; a check against the wrong key suppresses this notice.
    for entry in [{"hasTrustDialogAccepted": False}, {"hasCompletedProjectOnboarding": True}]:
        state.write_text(json.dumps({"projects": {project: entry}}))
        check(payload, message)
    for contents in ["{}", "{"]:
        state.write_text(contents)
        check(payload, message)
    state.unlink()
    check(payload, message)
    fallback = {"systemMessage": os.getcwd() + " is not a trusted Claude Code project; its project settings did not apply. The launcher appended --add-dir ~/.claude/projects so Workflow resume keeps working."}
    check(b"{}", fallback)
    for invalid in [b"", b"{", b"[]", b'{"cwd":1}', b"{} {}"]:
        check(invalid, None)
    check(payload, None, {key: value for key, value in environment.items() if key != "HOME"})
    relocated = home / "relocated"
    relocated.mkdir()
    (relocated / ".claude.json").write_text(json.dumps({"projects": {project: {"hasTrustDialogAccepted": True}}}))
    check(payload, None, dict(environment, CLAUDE_CONFIG_DIR=str(relocated)))
    print("PASS: hook trust, silence, malformed payload, HOME and config-directory cases")
    PYTHON
    ${pkgs.coreutils}/bin/touch "$out"
  '';
}
