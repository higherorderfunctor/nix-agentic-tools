# The packaged launchers default updates off and honor an explicit opt-in.
{pkgs, ...}: let
  package = pkgs.ai.kiro-cli.passthru.unwrapped;
in {
  checks = {
    kiro-autoupdate-switch = pkgs.runCommand "kiro-autoupdate-switch" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      for command in kiro-cli kiro-cli-chat; do
        ${pkgs.gnugrep}/bin/grep -qF 'set -euETo pipefail; shopt -s inherit_errexit' "${package}/bin/$command"
        ${pkgs.gnugrep}/bin/grep -qF '*) export KIRO_NO_AUTO_UPDATE=1' "${package}/bin/$command"
      done
      ${pkgs.gnugrep}/bin/grep -aqF 'KIRO_NO_AUTO_UPDATE' \
        ${package}/bin/.kiro-cli-wrapped
      ${pkgs.gnugrep}/bin/grep -aqF 'app.disableAutoupdates' \
        ${package}/bin/.kiro-cli-wrapped
      touch "$out"
    '';

    # Use the package's exact wrapper flags without depending on its real
    # binary. Both packaged commands are direct last hops to the one 3.0.0
    # binary, so each is modeled as its own wrapper over the stub, as
    # production builds them.
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
        for command in kiro-cli kiro-cli-chat; do
          makeWrapper "$out/bin/binary" "$out/bin/$command" ${package.autoUpdateWrapperFlags}
        done
        unset KIRO_NO_AUTO_UPDATE
        for command in kiro-cli kiro-cli-chat; do
          test "$("$out/bin/$command")" = 1
          for value in "" 0 false FALSE False off OFF no NO; do
            test "$(KIRO_NO_AUTO_UPDATE="$value" "$out/bin/$command")" = unset
          done
          for value in 1 true on yes; do
            test "$(KIRO_NO_AUTO_UPDATE="$value" "$out/bin/$command")" = 1
          done
          # A module wrapper re-exporting the opt-in in front of either
          # command is normalized the same way.
          test "$("$out/bin/reexport" "$out/bin/$command")" = unset
        done
        echo 'PASS: default and opt-in hold on both direct commands; module re-export is normalized'
      '';
  };
}
