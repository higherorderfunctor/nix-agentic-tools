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
    printf 'file=%s\n' "$(cat "$root/secret-file")"
    printf 'dir=%s\n' "$(ls -A "$root/secret-dir")"
    printf 'link=%s\n' "$(cat "$root/link")"
    printf 'target=%s\n' "$(cat "$root/link-target")"
    printf 'visible=%s\n' "$(cat "$root/visible")"
    printf 'secret=%s\n' "''${JAIL_SECRET:-unset}"
    printf 'kept=%s\n' "''${JAIL_KEPT:-unset}"
  '';
  # The fixture lives under the build directory, known only at launch, so
  # the masks go through `permissions` with an unescaped `$JAIL_ROOT`; they
  # use the same `mask-path` combinator `exclude.paths` lowers to.
  jailed = jailLib.wrap {
    executables = ["jail-probe"];
    jail = self.lib.ai.jail;
    name = "jail-probe";
    package = probe;
    inherit pkgs;
    profile = {
      exclude = {
        environment = ["JAIL_SECRET"];
        paths = ["/nonexistent/ai-jail-probe"];
      };
      permissions = c:
        map (name: c.mask-path (c.noescape ''"$JAIL_ROOT"/${name}'')) ["secret-file" "secret-dir" "link"];
    };
  };
  expected = pkgs.writeText "ai-jail-wrap-expected" ''
    file=
    dir=
    link=
    target=
    visible=shown
    secret=unset
    kept=kept
  '';
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
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
        JAIL_SECRET=leaked JAIL_KEPT=kept ${jailed}/bin/jail-probe "$JAIL_ROOT" > "$TMPDIR/actual"
        if ! diff -u ${expected} "$TMPDIR/actual"; then
          echo "FAIL: the jailed probe saw something it should not" >&2
          exit 1
        fi
        echo "AI-JAIL-WRAP: masks held inside the jail" | tee "$out"
      else
        cat "$TMPDIR/control.log" >&2
        echo "AI-JAIL-WRAP: structural-only, bubblewrap cannot run in this build sandbox" | tee "$out"
      fi
    '';
  };
}
