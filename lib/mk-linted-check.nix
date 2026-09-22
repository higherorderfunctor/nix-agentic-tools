# Routes a check body through `pkgs.writeShellApplication` so shellcheck runs in
# its checkPhase: a body carrying a lint violation then FAILS TO BUILD instead of
# shipping inert. `runCommand` gets neither the lint nor `nounset` (issue #909).
{pkgs}: name: {
  runtimeInputs ? [],
  text,
  ...
} @ args: let
  # Single source of truth for the house strict-mode flags, the `shopt` line and
  # the repo-wide opt-in shellcheck set. Read from here rather than restating
  # them — a copy here would be a second definition that drifts, and a check
  # helper that lints more weakly than the corpus scanner is the one call site
  # where that drift is least visible.
  shellStrict = import ../config/shell-strict.nix;

  script = pkgs.writeShellApplication (
    {
      inherit (shellStrict) bashOptions;
      extraShellCheckFlags = shellStrict.shellcheckFlags;
    }
    // builtins.removeAttrs args ["runtimeInputs" "text"]
    // {
      inherit name runtimeInputs;
      text = ''
        ${shellStrict.shoptHeader}
        # The outer runCommand exports out; require that inherited contract.
        : "''${out:?}"
        ${text}
      '';
    }
  );
in
  pkgs.runCommand name {} ''
    ${pkgs.lib.getExe script}
    touch "$out"
  ''
