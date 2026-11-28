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
    environment.pop("CLAUDE_CONFIG_DIR", None)
    project = '/project with "quotes"'

    def notice(path):
        return {"systemMessage": path + " is not a trusted Claude Code project; its project settings did not apply. The launcher appended --add-dir ~/.claude/projects so Workflow resume keeps working."}

    def check(case, payload, expected, env=environment):
        result = subprocess.run(
            ["${hook}"], input=payload, capture_output=True, env=env, check=False
        )
        assert result.returncode == 0, (case, result)
        assert result.stderr == b"", (case, result.stderr)
        if expected is None:
            assert result.stdout == b"", (case, result.stdout)
        else:
            try:
                actual = json.loads(result.stdout)
            except ValueError as error:
                raise AssertionError((case, result.stdout)) from error
            assert actual == expected, (case, actual)

    payload = json.dumps({"cwd": project}).encode()
    trusted = json.dumps({"projects": {project: {"hasTrustDialogAccepted": True}}})
    # Onboarding is not trust; a check against the wrong key suppresses this notice.
    for case, contents, expected in [
        ("corrupt trust file crashes or suppresses the warning", "{", notice(project)),
        ("explicit rejection is treated as trust", json.dumps({"projects": {project: {"hasTrustDialogAccepted": False}}}), notice(project)),
        ("onboarding is treated as trust", json.dumps({"projects": {project: {"hasCompletedProjectOnboarding": True}}}), notice(project)),
        ("trust from a different project suppresses the warning", json.dumps({"projects": {"/another": {"hasTrustDialogAccepted": True}}}), notice(project)),
        ("trusted project emits a false warning", trusted, None),
        ("valid state without project entries suppresses the warning", "{}", notice(project)),
    ]:
        state.write_text(contents)
        check(case, payload, expected)
    state.unlink()
    check("missing trust file crashes or suppresses the warning", payload, notice(project))
    check("missing cwd does not fall back to the process cwd", b"{}", notice(os.getcwd()))
    for case, invalid in [
        ("an array is treated as an event with no cwd", b"[]"),
        ("empty input is treated as an event with no cwd", b""),
        ("multiple JSON values are processed as one event", b"{} {}"),
        ("numeric cwd is converted to a project path", b'{"cwd":1}'),
        ("truncated JSON leaks a parser diagnostic", b"{"),
    ]:
        check(case, invalid, None)
    check("missing HOME stays quiet", payload, None, {key: value for key, value in environment.items() if key != "HOME"})
    relocated = home / "relocated"
    relocated.mkdir()
    (relocated / ".claude.json").write_text(trusted)
    check("relocated trust state suppresses the notice", payload, None, dict(environment, CLAUDE_CONFIG_DIR=str(relocated)))
    print("PASS: hook trust, silence, malformed payload, HOME and config-directory cases")
    PYTHON
    ${pkgs.coreutils}/bin/touch "$out"
  '';
}
