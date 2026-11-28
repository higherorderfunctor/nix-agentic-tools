# Acceptance probes for `lib.ai.jail`. Linux-only: bubblewrap is a Linux
# namespace tool, so the names are absent on Darwin.
{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (self.lib.ai) jail;
  exe = "${pkgs.coreutils}/bin/true";
  bwrap = lib.getExe pkgs.bubblewrap;

  trivial = jail.init pkgs "jail-nix-probe" exe (combinators: [(combinators.share-ns "net")]);
  extended =
    jail.extend {
      inherit pkgs;
      additionalCombinators = combinators: {
        probe = combinators.compose [(combinators.set-env "JAIL_PROBE" "1")];
      };
    }
    "jail-nix-probe-extend"
    exe
    (combinators: [combinators.probe]);

  # Inspect the bubblewrap command itself, not unrelated mentions of the
  # expected executable or setting elsewhere in the generated script.
  # This reads whole physical lines and expects the pinned upstream renderer's
  # `--setenv VAR VALUE` and `-- COMMAND` forms with an unquoted value and store
  # paths; check for upstream formatting changes first if this fails.
  structural = name: wrapper: expected: ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    script=${lib.getExe' wrapper name}
    command_line=$(awk -v bwrap='${bwrap}' '$1 == bwrap || ($1 == "exec" && $2 == bwrap)' "$script")
    expected=${lib.escapeShellArg expected}
    if ! grep -qF -- "$expected" <<< "$command_line"; then
      printf 'FAIL: %s must pass %s to bubblewrap; got %s\n' "$script" "$expected" "$command_line" >&2
      exit 1
    fi
  '';
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    # The public extend builder must apply a caller-defined combinator, not
    # merely accept its name while dropping or changing its environment value.
    jail-nix-extend = pkgs.runCommand "jail-nix-extend" {} ''
      ${structural "jail-nix-probe-extend" extended " --setenv JAIL_PROBE 1 "}
      touch "$out"
    '';

    # Check that the public init builder hands off to the requested executable.
    # The mirror's upstream suite covers stock runtime behavior; bubblewrap
    # cannot run inside CI's build sandbox.
    jail-nix-trivial = pkgs.runCommand "jail-nix-trivial" {} ''
      ${structural "jail-nix-probe" trivial " -- ${exe} "}
      touch "$out"
    '';
  };
}
