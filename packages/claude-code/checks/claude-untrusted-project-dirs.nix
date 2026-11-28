# Reject static flags, broken HOME quoting, ignored trust, and early wrapper exit.
{
  lib,
  pkgs,
  ...
}: let
  directories = import ../lib/untrustedProjectDirs.nix {inherit lib pkgs;};
  fake = import ../../../lib/strict-shell-application.nix pkgs {
    name = "claude";
    text = ''
      printf '%s\0' "$@"
    '';
  };
  launcher = flags:
    (import ../../../lib/ai/launcher.nix pkgs) {
      inherit flags;
      exe = "claude";
      name = "claude-untrusted-project-dirs-fixture";
      package = fake;
    };
  wrapped = launcher (directories.flags ["~/.claude/projects" "/other dir"]);
in {
  checks.claude-untrusted-project-dirs = pkgs.runCommand "claude-untrusted-project-dirs" {} ''
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
    extra = ["--add-dir", str(home / ".claude/projects"), "--add-dir", "/other dir"]

    original = ["original argument"]
    with_extra = extra + original

    def check(regression, expected, env=environment):
        result = subprocess.run(
            ["${wrapped}/bin/claude", *original], capture_output=True,
            env=env, check=False
        )
        expected_bytes = b"".join(word.encode() + b"\0" for word in expected)
        actual = (result.returncode, result.stderr, result.stdout)
        assert actual == (0, b"", expected_bytes), (regression, actual)
        print(f"ok - did not observe: {regression}")

    def trust(path, entry):
        path.write_text(json.dumps({"projects": {os.getcwd(): entry}}))

    check("missing state omits fallback directories or splits a quoted argument", with_extra)
    trust(state, {"hasTrustDialogAccepted": True})
    check("accepted project still gets the fallback flags", original)
    for regression, entry in [
        ("false acceptance treated as accepted", {"hasTrustDialogAccepted": False}),
        ("onboarding mistaken for trust", {"hasCompletedProjectOnboarding": True}),
    ]:
        trust(state, entry)
        check(regression, with_extra)
    state.write_text("{")
    check("malformed state blocks fallback or leaks parser errors", with_extra)
    check("unset HOME prevents forwarding the original argument", original,
          {key: value for key, value in environment.items() if key != "HOME"})
    relocated = home / "relocated"
    relocated.mkdir()
    trust(relocated / ".claude.json", {"hasTrustDialogAccepted": True})
    check("launcher ignores trust in CLAUDE_CONFIG_DIR", original,
          dict(environment, CLAUDE_CONFIG_DIR=str(relocated)))
    PYTHON
    ${pkgs.coreutils}/bin/touch "$out"
  '';
}
