# Structural guard for the upstream Linux buildFHSEnv assumptions that make
# store-backed extraPackages visible inside Kiro. This deliberately inspects
# the realized wrapper rather than executing bubblewrap: Nix build sandboxes are
# not a reliable place to exercise nested user namespaces.
# cspell:words unsetenv unsets
{pkgs, ...}: let
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  kiroPackage = pkgs.ai.kiro-cli;
in
  pkgs.runCommandLocal "kiro-fhs-contract-check" {} ''
    ${
      if isLinux
      then ''
        nat_fail() {
          printf 'kiro-fhs-contract: %s\n' "$1" >&2
          exit 1
        }

        nat_launcher="$(${pkgs.coreutils}/bin/readlink -f ${kiroPackage}/bin/kiro-cli)"
        [ -f "$nat_launcher" ] || nat_fail "kiro-cli no longer resolves to a generated FHS launcher"

        ${pkgs.gnugrep}/bin/grep -qF -- '--bind /nix /nix' "$nat_launcher" \
          || nat_fail "FHS launcher no longer bind-mounts /nix; re-measure extraPackages visibility"
        for nat_path_mutator in '--clearenv' '--setenv PATH' '--unsetenv PATH'; do
          if ${pkgs.gnugrep}/bin/grep -qF -- "$nat_path_mutator" "$nat_launcher"; then
            nat_fail "FHS launcher now mutates the inherited PATH via $nat_path_mutator; re-measure propagation"
          fi
        done

        nat_rootfs="$(${pkgs.gnused}/bin/sed -n \
          's#^for i in \(/nix/store/[^ ]*-fhsenv-rootfs\)/\*; do$#\1#p' \
          "$nat_launcher")"
        [ -d "$nat_rootfs" ] \
          || nat_fail "could not locate the FHS root from the generated launcher; re-measure its structure"
        ${pkgs.gnugrep}/bin/grep -qF "for i in $nat_rootfs/etc/*; do" "$nat_launcher" \
          || nat_fail "FHS launcher no longer walks the generated root /etc"
        ${pkgs.gnugrep}/bin/grep -qF \
          "if [[ \$path == '/fonts' || \$path == '/ssl' ]]; then" \
          "$nat_launcher" \
          || nat_fail "FHS generated-/etc exclusion set changed; verify /etc/profile is still mounted"
        ${pkgs.gnugrep}/bin/grep -qF 'ro_mounts+=(--ro-bind "$i" "/etc$path")' "$nat_launcher" \
          || nat_fail "FHS launcher no longer mounts generated /etc entries into the runtime root"
        ${pkgs.gnugrep}/bin/grep -qF '"''${ro_mounts[@]}"' "$nat_launcher" \
          || nat_fail "FHS launcher no longer passes generated root mounts to bubblewrap"

        nat_init="$(${pkgs.gnused}/bin/sed -n \
          's#^[[:space:]]*--symlink \(/nix/store/[^ ]*-init\) /init.*$#\1#p' \
          "$nat_launcher")"
        [ -f "$nat_init" ] \
          || nat_fail "could not locate the FHS init from the generated launcher; re-measure its structure"
        nat_source_count="$(${pkgs.gnugrep}/bin/grep -cF 'source /etc/profile' "$nat_init" || :)"
        nat_exec_count="$(${pkgs.gnugrep}/bin/grep -cF 'exec kiro-cli "$@"' "$nat_init" || :)"
        [ "$nat_source_count" -eq 1 ] \
          || nat_fail "FHS init must source /etc/profile exactly once"
        [ "$nat_exec_count" -eq 1 ] \
          || nat_fail "FHS init command shape changed; re-measure PATH propagation"
        nat_source_line="$(${pkgs.gnugrep}/bin/grep -nF 'source /etc/profile' "$nat_init" \
          | ${pkgs.gnused}/bin/sed 's/:.*//')"
        nat_exec_line="$(${pkgs.gnugrep}/bin/grep -nF 'exec kiro-cli "$@"' "$nat_init" \
          | ${pkgs.gnused}/bin/sed 's/:.*//')"
        [ "$nat_source_line" -lt "$nat_exec_line" ] \
          || nat_fail "FHS init no longer sources /etc/profile before executing Kiro"
        if ${pkgs.gnugrep}/bin/grep -Eq '(^|[[:space:]])(export[[:space:]]+)?PATH=|unset[[:space:]]+PATH' "$nat_init"; then
          nat_fail "FHS init now mutates PATH outside /etc/profile; re-measure propagation"
        fi

        nat_profile="$nat_rootfs/etc/profile"
        [ -f "$nat_profile" ] || nat_fail "FHS root no longer provides /etc/profile"
        nat_path_assignments="$(${pkgs.gnugrep}/bin/grep -Ec '(^|[[:space:]])PATH=' "$nat_profile" || :)"
        [ "$nat_path_assignments" -eq 1 ] \
          || nat_fail "FHS profile PATH assignment count changed; re-measure effective precedence"
        if ${pkgs.gnugrep}/bin/grep -Eq 'unset[[:space:]]+PATH' "$nat_profile"; then
          nat_fail "FHS profile now unsets PATH; re-measure propagation"
        fi
        ${pkgs.gnugrep}/bin/grep -qF \
          'export PATH="/run/wrappers/bin:/usr/bin:/usr/sbin:$PATH"' \
          "$nat_profile" \
          || nat_fail "FHS profile no longer preserves inherited PATH as its tail"
      ''
      else ''
        # Darwin has no upstream buildFHSEnv layer, so there is no FHS contract
        # to inspect on this platform.
        :
      ''
    }

    touch "$out"
  ''
