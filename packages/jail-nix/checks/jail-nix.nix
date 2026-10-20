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

  # A rendered wrapper must contain each needle, or the check prints it.
  structural = name: wrapper: needles: ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    script=${lib.getExe' wrapper name}
    for needle in ${lib.escapeShellArgs needles}; do
      if ! grep -qF -- "$needle" "$script"; then
        echo "FAIL: $script does not contain '$needle'" >&2
        cat "$script" >&2
        exit 1
      fi
    done
  '';
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    jail-nix-extend = pkgs.runCommand "jail-nix-extend" {} ''
      ${structural "jail-nix-probe-extend" extended ["--setenv JAIL_PROBE"]}
      touch "$out"
    '';

    # Unprivileged user namespaces are host policy, not a property of this
    # library, so execution is gated on an independent bubblewrap positive
    # control. The structural half runs on every host. The base permissions
    # forward LANG, HOME and TERM under nounset and mount a tmpfs over a
    # creatable HOME.
    jail-nix-trivial =
      pkgs.runCommand "jail-nix-trivial" {
        LANG = "C";
        TERM = "dumb";
      } ''
        ${structural "jail-nix-probe" trivial [bwrap "-- ${exe}"]}
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        if ${bwrap} --unshare-user --unshare-pid --ro-bind / / -- ${exe} 2>"$TMPDIR/control.log"; then
          "$script"
          echo "JAIL-NIX-TRIVIAL: executed true inside the jail" | tee "$out"
        else
          cat "$TMPDIR/control.log" >&2
          echo "JAIL-NIX-TRIVIAL: structural-only, bubblewrap cannot run in this build sandbox" | tee "$out"
        fi
      '';
  };
}
