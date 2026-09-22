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

  # A caller may ADD bash options and shellcheck flags; it may never replace or
  # remove the house baseline. Right-biased `//` over the whole of `args` would
  # allow exactly that: `bashOptions = []` disables errexit, and
  # `extraShellCheckFlags = []` disables the repo-wide opt-in set. Both were
  # OBSERVED building clean before this was closed, which made the contract in
  # the header above false for any caller that wanted it to be.
  callerArgs = builtins.removeAttrs args [
    "bashOptions"
    "extraShellCheckFlags"
    "runtimeInputs"
    "text"
  ];

  script = pkgs.writeShellApplication (
    callerArgs
    // {
      inherit name runtimeInputs;
      bashOptions =
        pkgs.lib.unique (shellStrict.bashOptions ++ (args.bashOptions or []));
      extraShellCheckFlags =
        pkgs.lib.unique (shellStrict.shellcheckFlags ++ (args.extraShellCheckFlags or []));
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
