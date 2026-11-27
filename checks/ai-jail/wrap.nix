# `ai.jail`'s `wrap` run for real: a probe jailed with the exclusion profile
# reads a masked file, a masked directory and a symlink to a masked file, and
# its environment, inside the build sandbox. Linux-only, like bubblewrap.
#
# Unprivileged user namespaces are host policy, so the run is gated on an
# independent bubblewrap positive control with the same namespace flags;
# `$out` says which branch ran.
{
  lib,
  pkgs,
  self,
  ...
}: let
  jailLib = import ../../lib/ai/jail {inherit lib;};
  bwrap = lib.getExe pkgs.bubblewrap;
  probe = pkgs.writeShellScriptBin "jail-probe" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    root=$1
    read_fixture() {
      local name=$1 value
      shift
      # A blocked read is not the same as successfully reading an empty mask.
      if ! value=$("$@"); then
        echo "FAIL: could not read the $name fixture" >&2
        exit 1
      fi
      printf '%s=%s\n' "$name" "$value"
    }
    read_fixture file ${pkgs.coreutils}/bin/wc -c < "$root/secret-file"
    read_fixture dir ${pkgs.coreutils}/bin/ls -A "$root/secret-dir"
    read_fixture link ${pkgs.coreutils}/bin/wc -c < "$root/link"
    read_fixture target ${pkgs.coreutils}/bin/wc -c < "$root/link-target"
    read_fixture visible ${pkgs.coreutils}/bin/cat "$root/visible"
    printf 'secret-present=%s\n' "''${JAIL_SECRET+yes}"
    printf 'kept=%s\n' "''${JAIL_KEPT:-unset}"
    if jail_probe_path="$(${pkgs.coreutils}/bin/printenv PATH)"; then
      printf 'path=value:%s\n' "$jail_probe_path"
    else
      printf 'path=unset\n'
    fi
  '';
  # The fixture lives under the build directory, known only at launch, so
  # the masks go through `permissions` with an unescaped `$JAIL_ROOT`; they
  # use the same `mask-path` combinator `exclude.paths` lowers to.
  jailed = extraPermissions:
    jailLib.wrap {
      executables = ["jail-probe"];
      jail = self.lib.ai.jail;
      name = "jail-probe";
      package = probe;
      inherit pkgs;
      profile = {
        exclude = {
          environment = ["JAIL_SECRET" "PATH"];
          paths = ["/nonexistent/ai-jail-probe"];
        };
        permissions = c:
          map (name: c.mask-path (c.noescape ''"$JAIL_ROOT"/${name}'')) ["secret-file" "secret-dir" "link"]
          ++ extraPermissions c;
      };
    };
  # A launcher with a helper bin: only the entry point is jailed, and the
  # helper is linked through from the package unchanged.
  helper = pkgs.writeShellScriptBin "jail-helper" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    echo helper
  '';
  withHelper = pkgs.symlinkJoin {
    name = "jail-probe-with-helper";
    paths = [probe helper];
  };
  helperWrapped = jailLib.wrap {
    executables = ["jail-probe"];
    jail = self.lib.ai.jail;
    name = "jail-probe";
    package = withHelper;
    inherit pkgs;
    profile = {
      exclude = {
        environment = null;
        paths = null;
      };
      permissions = null;
    };
  };
  wrapped = {
    excluded = jailed (_: []);
    restored = jailed (c: [(c.set-env "PATH" "/jail-permissions-path")]);
  };
  expected = path:
    pkgs.writeText "ai-jail-wrap-expected" ''
      file=0
      dir=
      link=0
      target=0
      visible=shown
      secret-present=
      kept=kept
      path=${path}
    '';
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    # Read the installed wrappers even when the build sandbox cannot run
    # bubblewrap. Restoration must expand at exec, not in RUNTIME_ARGS.
    ai-jail-environment-order = pkgs.runCommand "ai-jail-environment-order" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      restore='--setenv PATH "''${PATH#${pkgs.coreutils}/bin:}"'
      unset_path='--unsetenv PATH'
      check_order() {
        local label=$1 wrapper=$2 text
        text=$(cat "$wrapper")
        if [[ $text != *"$restore"*"$unset_path"* || $text == *'RUNTIME_ARGS+=(--setenv PATH'* ]]; then
          echo "FAIL: $label must restore the caller PATH at exec before excluding it" >&2
          exit 1
        fi
        if [[ $label == restored && $text != *"$unset_path"*'--setenv PATH /jail-permissions-path'* ]]; then
          echo "FAIL: explicit PATH must be assigned after its exclusion" >&2
          exit 1
        fi
      }
      check_order excluded ${wrapped.excluded}/bin/jail-probe
      check_order restored ${wrapped.restored}/bin/jail-probe
      touch "$out"
    '';

    # Read the installed links rather than predicting symlinkJoin's inputs or
    # matching its build command. Both named fixture binaries must survive.
    ai-jail-helper-pass-through = pkgs.runCommand "ai-jail-helper-pass-through" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      entry=${helperWrapped}/bin/jail-probe
      helper=${helperWrapped}/bin/jail-helper
      if ! test -x "$entry" || ! grep -qF -- ${lib.escapeShellArg bwrap} "$entry"; then
        echo "FAIL: the fixture entry point is not an executable jail wrapper" >&2
        exit 1
      fi
      if ! test -L "$helper" || ! test -x "$helper" || ! test "$helper" -ef ${withHelper}/bin/jail-helper; then
        echo "FAIL: the fixture helper does not link to the original executable" >&2
        exit 1
      fi
      touch "$out"
    '';

    ai-jail-wrap-masks = pkgs.runCommand "ai-jail-wrap-masks" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export JAIL_ROOT="$TMPDIR/fixture"
      mkdir -p "$JAIL_ROOT/secret-dir"
      echo secret > "$JAIL_ROOT/secret-file"
      echo secret > "$JAIL_ROOT/secret-dir/key"
      echo secret > "$JAIL_ROOT/link-target"
      ln -s link-target "$JAIL_ROOT/link"
      echo shown > "$JAIL_ROOT/visible"
      if ${bwrap} --unshare-user --unshare-pid --dev-bind / / --proc /proc --dev /dev -- true 2>"$TMPDIR/control.log"; then
        check_probe() {
          local label=$1 wrapper=$2 expected=$3
          if ! JAIL_SECRET=leaked JAIL_KEPT=kept "$wrapper" "$JAIL_ROOT" > "$TMPDIR/actual"; then
            echo "FAIL: $label jailed probe could not run or read its fixtures" >&2
            exit 1
          fi
          if ! diff -u "$expected" "$TMPDIR/actual"; then
            echo "FAIL: $label jailed probe did not deliver the expected masks and environment" >&2
            exit 1
          fi
        }
        check_probe excluded ${wrapped.excluded}/bin/jail-probe ${expected "unset"}
        check_probe restored ${wrapped.restored}/bin/jail-probe ${expected "value:/jail-permissions-path"}
        echo "AI-JAIL-WRAP: masks, PATH exclusion and final override held inside the jail" | tee "$out"
      else
        cat "$TMPDIR/control.log" >&2
        echo "AI-JAIL-WRAP: structural-only, bubblewrap cannot run in this build sandbox" | tee "$out"
      fi
    '';
  };
}
