# `ai.jail`'s `wrap` run for real: a probe jailed with the exclusion profile
# reads a masked file, a masked directory and a symlink to a masked file, and
# its environment, inside the build sandbox. Linux-only, like bubblewrap.
#
# Unprivileged user namespaces are host policy, so the run is gated on an
# independent bubblewrap positive control with the same namespace flags;
# `$out` says which branch ran.
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  jailLib = import ../../lib/ai/jail {inherit lib;};
  bwrap = lib.getExe pkgs.bubblewrap;
  # Inspect direct per-executable derivations, without exposing test metadata
  # on the installed profile or duplicating its base permissions.
  combinatorJail = self.lib.ai.jail.extend {
    inherit pkgs;
    additionalCombinators = self.lib.ai.jail.combinators pkgs;
    basePermissions = [];
  };
  environmentWrapper = explicit:
    combinatorJail "environment-order" "${pkgs.coreutils}/bin/true" (c:
      [c.strict-runtime c.restore-path (c.unset-env "PATH")]
      ++ lib.optional explicit (c.set-env "PATH" "/jail-permissions-path"));
  environmentOrder = explicit: let
    text = builtins.unsafeDiscardStringContext (environmentWrapper explicit).text;
    restoreUnset = builtins.unsafeDiscardStringContext ''--setenv PATH "''${PATH#${pkgs.coreutils}/bin:}" --unsetenv PATH'';
    afterUnset = builtins.elemAt (lib.splitString "--unsetenv PATH" text) 1;
  in
    lib.hasInfix restoreUnset text
    && !(lib.hasInfix "RUNTIME_ARGS+=(--setenv PATH" text)
    && (!explicit || lib.hasInfix "--setenv PATH /jail-permissions-path" afterUnset);
  probe = pkgs.writeShellScriptBin "jail-probe" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    root=$1
    printf 'file=%s\n' "$("${pkgs.coreutils}/bin/cat" "$root/secret-file")"
    printf 'dir=%s\n' "$("${pkgs.coreutils}/bin/ls" -A "$root/secret-dir")"
    printf 'link=%s\n' "$("${pkgs.coreutils}/bin/cat" "$root/link")"
    printf 'target=%s\n' "$("${pkgs.coreutils}/bin/cat" "$root/link-target")"
    printf 'visible=%s\n' "$("${pkgs.coreutils}/bin/cat" "$root/visible")"
    printf 'secret=%s\n' "''${JAIL_SECRET:-unset}"
    printf 'kept=%s\n' "''${JAIL_KEPT:-unset}"
    if jail_probe_path="$(${pkgs.coreutils}/bin/printenv PATH)"; then
      printf 'path=%s\n' "$jail_probe_path"
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
  expected = path:
    pkgs.writeText "ai-jail-wrap-expected" ''
      file=
      dir=
      link=
      target=
      visible=shown
      secret=unset
      kept=kept
      path=${path}
    '';
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    ai-jail-environment-order = harness.mkTest "ai-jail-environment-order" (
      environmentOrder false && environmentOrder true
    );

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
        JAIL_SECRET=leaked JAIL_KEPT=kept ${jailed (_: [])}/bin/jail-probe "$JAIL_ROOT" > "$TMPDIR/actual"
        if ! diff -u ${expected "unset"} "$TMPDIR/actual"; then
          echo "FAIL: the jailed probe saw something it should not" >&2
          exit 1
        fi
        JAIL_SECRET=leaked JAIL_KEPT=kept ${jailed (c: [(c.set-env "PATH" "/jail-permissions-path")])}/bin/jail-probe "$JAIL_ROOT" > "$TMPDIR/override"
        if ! diff -u ${expected "/jail-permissions-path"} "$TMPDIR/override"; then
          echo "FAIL: final permissions did not restore PATH" >&2
          exit 1
        fi
        echo "AI-JAIL-WRAP: masks, PATH exclusion and final override held inside the jail" | tee "$out"
      else
        cat "$TMPDIR/control.log" >&2
        echo "AI-JAIL-WRAP: structural-only, bubblewrap cannot run in this build sandbox" | tee "$out"
      fi
    '';
  };
}
