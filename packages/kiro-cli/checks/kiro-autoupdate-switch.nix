# The packaged launchers default updates off and honor an explicit opt-in.
{pkgs, ...}: let
  package = pkgs.ai.kiro-cli.passthru.unwrapped;
in {
  checks = {
    kiro-autoupdate-switch = pkgs.runCommand "kiro-autoupdate-switch" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.gnugrep}/bin/grep -qF 'set -euETo pipefail; shopt -s inherit_errexit' "${package}/bin/kiro-cli"
      ${pkgs.gnugrep}/bin/grep -qF '*) export KIRO_NO_AUTO_UPDATE=1' "${package}/bin/kiro-cli"
      ${pkgs.gnugrep}/bin/grep -aqF 'KIRO_NO_AUTO_UPDATE' \
        ${package}/bin/.kiro-cli-wrapped
      ${pkgs.gnugrep}/bin/grep -aqF 'app.disableAutoupdates' \
        ${package}/bin/.kiro-cli-wrapped
      touch "$out"
    '';

    # Use the package's exact wrapper flags without depending on its real
    # binary. The packaged `kiro-cli` is the direct last hop to the 3.0.0
    # binary, so it is modeled as one wrapper over the stub, as production
    # builds it.
    kiro-autoupdate-wrapper-chain =
      pkgs.runCommandLocal "kiro-autoupdate-wrapper-chain" {
        nativeBuildInputs = [pkgs.makeWrapper];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p "$out/bin"
        cat > "$out/bin/binary" <<'EOF'
        #!${pkgs.bash}/bin/bash
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf '%s\n' "''${KIRO_NO_AUTO_UPDATE-unset}"
        EOF
        cat > "$out/bin/reexport" <<EOF
        #!${pkgs.bash}/bin/bash
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export KIRO_NO_AUTO_UPDATE=0
        exec "\$1"
        EOF
        chmod +x "$out/bin/binary" "$out/bin/reexport"
        makeWrapper "$out/bin/binary" "$out/bin/kiro-cli" ${package.autoUpdateWrapperFlags}
        unset KIRO_NO_AUTO_UPDATE
        test "$("$out/bin/kiro-cli")" = 1
        for value in "" 0 false FALSE False off OFF no NO; do
          test "$(KIRO_NO_AUTO_UPDATE="$value" "$out/bin/kiro-cli")" = unset
        done
        for value in 1 true on yes; do
          test "$(KIRO_NO_AUTO_UPDATE="$value" "$out/bin/kiro-cli")" = 1
        done
        # A module wrapper re-exporting the opt-in in front of the command is
        # normalized the same way.
        test "$("$out/bin/reexport" "$out/bin/kiro-cli")" = unset
        echo 'PASS: default and opt-in hold on the direct command; module re-export is normalized'
      '';
  };
}
