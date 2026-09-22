{pkgs}: name: {
  runtimeInputs ? [],
  text,
  ...
} @ args: let
  script = pkgs.writeShellApplication (
    {
      # The house strict-mode standard requires errtrace and functrace in
      # addition to writeShellApplication's three default shell options.
      bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    }
    // builtins.removeAttrs args ["runtimeInputs" "text"]
    // {
      inherit name runtimeInputs;
      # inherit_errexit is a shopt and must be enabled separately.
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
