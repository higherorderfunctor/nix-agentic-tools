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
  empty = launcher (directories.flags []);
  wrapped = launcher (directories.flags ["~/.claude/projects" "/other dir"]);
in {
  checks.claude-untrusted-project-dirs = assert empty == fake;
    pkgs.runCommand "claude-untrusted-project-dirs" {} ''
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

      def check(expected, env=environment):
          result = subprocess.run(
              ["${wrapped}/bin/claude", "original argument"], capture_output=True,
              env=env, check=False
          )
          assert result.returncode == 0, result
          assert result.stderr == b"", result.stderr
          assert result.stdout == b"".join(word.encode() + b"\0" for word in expected), result.stdout

      check(extra + ["original argument"])
      state.write_text(json.dumps({"projects": {os.getcwd(): {"hasTrustDialogAccepted": True}}}))
      check(["original argument"])
      for entry in [{"hasTrustDialogAccepted": False}, {"hasCompletedProjectOnboarding": True}]:
          state.write_text(json.dumps({"projects": {os.getcwd(): entry}}))
          check(extra + ["original argument"])
      state.write_text("{")
      check(extra + ["original argument"])
      check(["original argument"], {key: value for key, value in environment.items() if key != "HOME"})
      relocated = home / "relocated"
      relocated.mkdir()
      (relocated / ".claude.json").write_text(json.dumps({"projects": {os.getcwd(): {"hasTrustDialogAccepted": True}}}))
      check(["original argument"], dict(environment, CLAUDE_CONFIG_DIR=str(relocated)))
      print("PASS: wrapper argv, trust, quoting, unset HOME, config-directory and empty-list cases")
      PYTHON
      ${pkgs.coreutils}/bin/touch "$out"
    '';
}
