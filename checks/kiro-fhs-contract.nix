# Structural guard for the upstream Linux buildFHSEnv assumptions that make
# store-backed extraPackages visible inside Kiro. This deliberately inspects
# the realized wrapper rather than executing bubblewrap: Nix build sandboxes are
# not a reliable place to exercise nested user namespaces.
# cspell:words unsetenv unsets
{pkgs, ...}: let
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  kiroPackage = pkgs.ai.kiro-cli;
  wrapKiroPackage = import ../packages/kiro-cli/lib/wrapPackage.nix {
    inherit (pkgs) lib;
    inherit pkgs;
  };
  trustedKiroPackage = wrapKiroPackage {
    package = kiroPackage;
    trustedMcpTools = ["fs_read"];
    v3 = false;
  };
in
  pkgs.runCommandLocal "kiro-fhs-contract-check" {} ''
    ${
      if isLinux
      then ''
        nat_fail() {
          printf 'kiro-fhs-contract: %s\n' "$1" >&2
          exit 1
        }

        nat_entrypoint="$(${pkgs.coreutils}/bin/readlink -f ${kiroPackage}/bin/kiro-cli)"
        [ -f "$nat_entrypoint" ] || nat_fail "kiro-cli no longer resolves to a generated launcher"

        # nixpkgs 9ddfd8a consolidated the three per-command FHS environments
        # into one shared environment. Its public commands are now thin
        # makeWrapper scripts, so readlink -f on bin/kiro-cli stops one layer
        # before the bubblewrap launcher. Keep accepting the older direct
        # launcher while it remains in the compatibility range.
        nat_entrypoint_root="''${nat_entrypoint%/bin/kiro-cli}"
        nat_shared_launcher="$nat_entrypoint_root/libexec/kiro-cli/kiro-cli-wrapper"
        if [ -e "$nat_shared_launcher" ]; then
          for nat_command in kiro-cli kiro-cli-chat kiro-cli-term; do
            nat_command_wrapper="$(${pkgs.coreutils}/bin/readlink -f ${kiroPackage}/bin/$nat_command)"
            [ -f "$nat_command_wrapper" ] \
              || nat_fail "$nat_command no longer resolves to a generated command wrapper"
            ${pkgs.gnugrep}/bin/grep -Eq \
              "^exec \"$nat_shared_launcher\"[[:space:]]+$nat_command[[:space:]]+\"\\\$@\"[[:space:]]*$" \
              "$nat_command_wrapper" \
              || nat_fail "$nat_command no longer dispatches through the shared FHS launcher"
          done
          nat_launcher="$(${pkgs.coreutils}/bin/readlink -f "$nat_shared_launcher")"
        else
          nat_launcher="$nat_entrypoint"
        fi
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
        nat_exec_count="$(${pkgs.gnugrep}/bin/grep -Ec \
          '^exec (kiro-cli|/nix/store/[^ ]+-kiro-cli) "\$@"$' \
          "$nat_init" || :)"
        [ "$nat_source_count" -eq 1 ] \
          || nat_fail "FHS init must source /etc/profile exactly once"
        [ "$nat_exec_count" -eq 1 ] \
          || nat_fail "FHS init command shape changed; re-measure PATH propagation"
        nat_source_line="$(${pkgs.gnugrep}/bin/grep -nF 'source /etc/profile' "$nat_init" \
          | ${pkgs.gnused}/bin/sed 's/:.*//')"
        nat_exec_line="$(${pkgs.gnugrep}/bin/grep -nE \
          '^exec (kiro-cli|/nix/store/[^ ]+-kiro-cli) "\$@"$' \
          "$nat_init" \
          | ${pkgs.gnused}/bin/sed 's/:.*//')"
        [ "$nat_source_line" -lt "$nat_exec_line" ] \
          || nat_fail "FHS init no longer sources /etc/profile before executing Kiro"
        if ${pkgs.gnugrep}/bin/grep -Eq '(^|[[:space:]])(export[[:space:]]+)?PATH=|unset[[:space:]]+PATH' "$nat_init"; then
          nat_fail "FHS init now mutates PATH outside /etc/profile; re-measure propagation"
        fi

        nat_dispatcher="$(${pkgs.gnused}/bin/sed -n \
          's#^exec \(/nix/store/[^ ]*-kiro-cli\) "\$@"$#\1#p' \
          "$nat_init")"
        if [ -n "$nat_dispatcher" ]; then
          [ -f "$nat_dispatcher" ] \
            || nat_fail "FHS init command dispatcher is no longer a readable script"
          [ "$(${pkgs.gnugrep}/bin/grep -cFx 'command="$1"' "$nat_dispatcher" || :)" -eq 1 ] \
            || nat_fail "shared FHS dispatcher no longer reads one command argument"
          [ "$(${pkgs.gnugrep}/bin/grep -cFx 'shift' "$nat_dispatcher" || :)" -eq 1 ] \
            || nat_fail "shared FHS dispatcher no longer removes one command argument"
          [ "$(${pkgs.gnugrep}/bin/grep -cFx 'exec "$command" "$@"' "$nat_dispatcher" || :)" -eq 1 ] \
            || nat_fail "shared FHS dispatcher no longer executes the selected command"
          nat_dispatch_command_line="$(${pkgs.gnugrep}/bin/grep -nFx 'command="$1"' "$nat_dispatcher" \
            | ${pkgs.gnused}/bin/sed 's/:.*//')"
          nat_dispatch_shift_line="$(${pkgs.gnugrep}/bin/grep -nFx 'shift' "$nat_dispatcher" \
            | ${pkgs.gnused}/bin/sed 's/:.*//')"
          nat_dispatch_exec_line="$(${pkgs.gnugrep}/bin/grep -nFx 'exec "$command" "$@"' "$nat_dispatcher" \
            | ${pkgs.gnused}/bin/sed 's/:.*//')"
          [ "$nat_dispatch_command_line" -lt "$nat_dispatch_shift_line" ] \
            && [ "$nat_dispatch_shift_line" -lt "$nat_dispatch_exec_line" ] \
            || nat_fail "shared FHS dispatcher no longer selects, shifts, then executes the command"
          if ${pkgs.gnugrep}/bin/grep -Eq '(^|[[:space:]])(export[[:space:]]+)?PATH=|unset[[:space:]]+PATH' "$nat_dispatcher"; then
            nat_fail "shared FHS dispatcher now mutates PATH; re-measure propagation"
          fi
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

        # Production-shaped trust injection: the upstream root shadows an
        # outer kiro-cli-chat wrapper, so the configured wrapper must be part
        # of the FHS payload itself. Follow both the consolidated shared
        # launcher and the older per-command launcher to the synthesized root,
        # then inspect the command path dispatch actually selects.
        nat_trusted_entrypoint="$(${pkgs.coreutils}/bin/readlink -f ${trustedKiroPackage}/bin/kiro-cli-chat)"
        nat_trusted_entrypoint_root="''${nat_trusted_entrypoint%/bin/kiro-cli-chat}"
        nat_trusted_shared_launcher="$nat_trusted_entrypoint_root/libexec/kiro-cli/kiro-cli-wrapper"
        if [ -e "$nat_trusted_shared_launcher" ]; then
          nat_trusted_launcher="$(${pkgs.coreutils}/bin/readlink -f "$nat_trusted_shared_launcher")"
        else
          nat_trusted_launcher="$nat_trusted_entrypoint"
        fi
        nat_trusted_rootfs="$(${pkgs.gnused}/bin/sed -n \
          's#^for i in \(/nix/store/[^ ]*-fhsenv-rootfs\)/\*; do$#\1#p' \
          "$nat_trusted_launcher")"
        [ -d "$nat_trusted_rootfs" ] \
          || nat_fail "could not locate the configured FHS root; trustedMcpTools composition is unverified"
        nat_trusted_chat="$(${pkgs.coreutils}/bin/readlink -f "$nat_trusted_rootfs/usr/bin/kiro-cli-chat")"
        [ -f "$nat_trusted_chat" ] \
          || nat_fail "configured FHS root no longer supplies kiro-cli-chat"
        ${pkgs.gnugrep}/bin/grep -qF -- '--trust-tools=fs_read' "$nat_trusted_chat" \
          || nat_fail "trustedMcpTools wrapper is not inside the FHS command path"
      ''
      else ''
        # Darwin has no upstream buildFHSEnv layer, so there is no FHS contract
        # to inspect on this platform.
        :
      ''
    }

    touch "$out"
  ''
