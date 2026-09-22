{pkgs}: name: {
  runtimeInputs ? [],
  text,
  ...
} @ args: let
  script = pkgs.writeShellApplication (
    builtins.removeAttrs args ["runtimeInputs" "text"]
    // {
      inherit name runtimeInputs;
      # writeShellApplication supplies errexit, nounset, and pipefail by
      # default. inherit_errexit is a shopt and must be enabled separately.
      text = ''
        shopt -s inherit_errexit 2>/dev/null || :
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
