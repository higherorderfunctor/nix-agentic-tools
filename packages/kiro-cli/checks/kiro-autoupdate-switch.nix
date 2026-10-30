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
        ${pkgs.gnugrep}/bin/grep -qF 'export NAT_KIRO_AUTO_UPDATE=on' "${package}/bin/$command"
        ${pkgs.gnugrep}/bin/grep -qF '*) export KIRO_NO_AUTO_UPDATE=1' "${package}/bin/$command"
      done
      ${pkgs.gnugrep}/bin/grep -aqF 'KIRO_NO_AUTO_UPDATE' \
        ${package}/bin/.kiro-cli-chat-wrapped
      ${pkgs.gnugrep}/bin/grep -aqF 'app.disableAutoupdates' \
        ${package}/bin/.kiro-cli-chat-wrapped
      touch "$out"
    '';

    # Use the package's exact wrapper flags without depending on its real binaries.
    kiro-autoupdate-wrapper-chain =
      pkgs.runCommandLocal "kiro-autoupdate-wrapper-chain" {
        nativeBuildInputs = [pkgs.makeWrapper];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p "$out/bin"
        cat > "$out/bin/chat" <<'EOF'
        #!${pkgs.bash}/bin/bash
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        test -z "''${NAT_KIRO_AUTO_UPDATE+x}"
        printf '%s\n' "''${KIRO_NO_AUTO_UPDATE-unset}"
        EOF
        cat > "$out/bin/dispatch" <<EOF
        #!${pkgs.bash}/bin/bash
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        exec "\''${1:-$out/bin/kiro-cli-chat}"
        EOF
        cat > "$out/bin/reexport" <<EOF
        #!${pkgs.bash}/bin/bash
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export KIRO_NO_AUTO_UPDATE=0
        exec "$out/bin/kiro-cli-chat"
        EOF
        chmod +x "$out/bin/chat" "$out/bin/dispatch" "$out/bin/reexport"
        makeWrapper "$out/bin/chat" "$out/bin/kiro-cli-chat" ${package.autoUpdateWrapperFlags true}
        makeWrapper "$out/bin/dispatch" "$out/bin/kiro-cli" ${package.autoUpdateWrapperFlags false}
        unset KIRO_NO_AUTO_UPDATE NAT_KIRO_AUTO_UPDATE
        for command in kiro-cli kiro-cli-chat; do
          test "$("$out/bin/$command")" = 1
          for value in "" 0 false FALSE False off OFF no NO; do
            test "$(KIRO_NO_AUTO_UPDATE="$value" "$out/bin/$command")" = unset
          done
          for value in 1 true on yes; do
            test "$(KIRO_NO_AUTO_UPDATE="$value" "$out/bin/$command")" = 1
          done
        done
        test "$(KIRO_NO_AUTO_UPDATE=0 "$out/bin/kiro-cli" "$out/bin/reexport")" = unset
        echo 'PASS: module re-export is normalized; default and opt-in survive both Kiro wrappers; chat clears the private marker'
      '';
  };
}
