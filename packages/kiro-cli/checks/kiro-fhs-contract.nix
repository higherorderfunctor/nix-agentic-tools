# Structural guard for the Linux buildFHSEnv this package owns, whose launcher
# shape makes store-backed extraPackages visible inside Kiro. This deliberately
# inspects the realized launcher rather than executing bubblewrap: Nix build
# sandboxes are not a reliable place to exercise nested user namespaces.
# cspell:words unsetenv unsets
{
  lib,
  pkgs,
  ...
}: {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    kiro-fhs-contract = let
      kiroPackage = pkgs.ai.kiro-cli;
      selectedKiroPackage = (kiroPackage.withBundlePatches {
        replace = ["relativeFileCheckPaths" "stripVendorWorktreeSteering"];
      }).withRolloutFeatures ["background_execution"];
    in
      pkgs.runCommandLocal "kiro-fhs-contract-check" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        nat_fail() {
          printf 'kiro-fhs-contract: %s\n' "$1" >&2
          exit 1
        }

        # One command: every selected variant exposes exactly kiro-cli, and
        # that entry is the bubblewrap launcher itself, not a dispatcher.
        for nat_package in ${kiroPackage} ${selectedKiroPackage}; do
          nat_bin_entries="$(${pkgs.coreutils}/bin/ls -A "$nat_package/bin")"
          [ "$nat_bin_entries" = "kiro-cli" ] \
            || nat_fail "$nat_package/bin must contain exactly kiro-cli, found: $nat_bin_entries"
        done

        nat_check_env() {
          nat_package="$1"
          nat_payload="$2"
          nat_launcher="$(${pkgs.coreutils}/bin/readlink -f "$nat_package/bin/kiro-cli")"
          [ -f "$nat_launcher" ] || nat_fail "could not locate the generated FHS launcher"

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
          [ "$nat_source_count" -eq 1 ] \
            || nat_fail "FHS init must source /etc/profile exactly once"
          # The runScript is the payload itself: no command argument is
          # selected or shifted, so the init's last line execs the payload.
          [ "$(${pkgs.gnugrep}/bin/grep -cFx "exec $nat_payload/bin/kiro-cli \"\$@\"" "$nat_init" || :)" -eq 1 ] \
            || nat_fail "FHS init must exec the pinned payload $nat_payload/bin/kiro-cli directly"
          nat_source_line="$(${pkgs.gnugrep}/bin/grep -nF 'source /etc/profile' "$nat_init" \
            | ${pkgs.gnused}/bin/sed 's/:.*//')"
          nat_exec_line="$(${pkgs.gnugrep}/bin/grep -nFx "exec $nat_payload/bin/kiro-cli \"\$@\"" "$nat_init" \
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
        }
        nat_check_env ${kiroPackage} ${kiroPackage.unwrapped}
        nat_check_env ${selectedKiroPackage} ${selectedKiroPackage.unwrapped}

        # A rollout and prompt-patched payload still binds its own KAS.
        ${pkgs.gnugrep}/bin/grep -qF -- '${selectedKiroPackage.kas}/node_modules/@kiro/agent/dist/server/acp-server.js' \
          "${selectedKiroPackage.unwrapped}/bin/kiro-cli" \
          || nat_fail "selected native command lost its fixed KAS path"
        touch "$out"
      '';
  };
}
