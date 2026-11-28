# The packaged launchers default updates off and honor an explicit opt-in.
{pkgs, ...}: let
  package = pkgs.ai.kiro-cli.passthru.unwrapped;
in {
  checks = {
    kiro-autoupdate-switch = pkgs.runCommand "kiro-autoupdate-switch" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      # The realized command must include the behavior tested by the stub.
      ${pkgs.gnugrep}/bin/grep -qF 'set -euETo pipefail; shopt -s inherit_errexit' "${package}/bin/kiro-cli"
      ${pkgs.gnugrep}/bin/grep -qF '*) export KIRO_NO_AUTO_UPDATE=1' "${package}/bin/kiro-cli"
      # Probe only spelling drift here; binary presence does not establish semantics.
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
        chmod +x "$out/bin/binary"
        makeWrapper "$out/bin/binary" "$out/bin/kiro-cli" ${package.autoUpdateWrapperFlags}
        expect_guard() {
          local regression="$1" expected="$2" observed
          shift 2
          observed="$("$@")"
          if [ "$observed" != "$expected" ]; then
            printf 'FAIL: %s: expected %s, got %s\n' "$regression" "$expected" "$observed" >&2
            return 1
          fi
        }
        unset KIRO_NO_AUTO_UPDATE
        expect_guard 'an absent variable defaults to updates off' 1 "$out/bin/kiro-cli"
        for value in "" 0 FaLsE no off; do
          KIRO_NO_AUTO_UPDATE="$value" expect_guard "opt-in '$value' must be absent at the binary" unset "$out/bin/kiro-cli"
        done
        KIRO_NO_AUTO_UPDATE=yes expect_guard 'a non-opt-in value is normalized rather than forwarded' 1 "$out/bin/kiro-cli"
        echo 'PASS: default and opt-in hold on the direct command'
      '';
  };
}
