# `ai.jail`'s `wrap` run for real: a probe jailed with the exclusion profile
# reads a masked file, a masked directory, and the target of a symlink named
# in a mask request. It also reads its environment inside the build sandbox.
# Linux-only, like bubblewrap.
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
  strictShellApplication = import ../../lib/strict-shell-application.nix pkgs;
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
  wrap = {
    bubblewrap,
    profile,
  }:
    jailLib.wrap {
      inherit profile;
      package = probe;
      executables = ["jail-probe"];
      jail = self.lib.ai.jail;
      name = "jail-probe";
      pkgs = pkgs // {inherit bubblewrap;};
    };
  # The fixture lives under the build directory, known only at launch, so
  # the masks go through `permissions` with an unescaped `$JAIL_ROOT`; they
  # use the same `mask-path` combinator `exclude.paths` lowers to.
  jailed = bubblewrap: restore:
    wrap {
      inherit bubblewrap;
      profile = {
        exclude = {
          environment = ["JAIL_SECRET" "PATH"];
          paths = ["/nonexistent/ai-jail-probe"];
        };
        permissions = c:
          map (name: c.mask-path (c.noescape ''"$JAIL_ROOT"/${name}'')) ["link" "secret-dir" "secret-file"]
          ++ lib.optional restore (c.set-env "PATH" "/jail-permissions-path");
      };
    };
  expected = path:
    pkgs.writeText "ai-jail-wrap-expected" ''
      file=0
      dir=
      target=0
      visible=shown
      secret-present=
      kept=kept
      path=${path}
    '';
  # Observe only PATH operations, in order, up to the child command. This
  # substitute reports what the wrapper passes, not what bubblewrap applies.
  pathArguments = strictShellApplication {
    name = "jail-path-arguments";
    text = ''
      while [ "$#" -gt 0 ]; do
        case "$1:''${2-}" in
          --:*) break ;;
          --setenv:PATH) printf 'set PATH=%s\n' "$3"; shift 3 ;;
          --unsetenv:PATH) printf 'unset PATH\n'; shift 2 ;;
          *) shift ;;
        esac
      done
    '';
  };
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    # The build sandbox may block bubblewrap, but must still exercise actual
    # argument expansion. A space in the caller PATH catches lost quoting;
    # the exact sequence catches a missing, duplicate or late assignment.
    ai-jail-environment-order = pkgs.runCommand "ai-jail-environment-order" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export JAIL_ROOT="$TMPDIR/no-fixture"
      check_order() {
        local label=$1 wrapper=$2
        if ! PATH='/caller tools/bin' "$wrapper" > "$TMPDIR/actual"; then
          echo "FAIL: $label wrapper did not deliver arguments to bubblewrap" >&2
          exit 1
        fi
        if ! diff -u - "$TMPDIR/actual"; then
          echo "FAIL: $label must restore the caller PATH before excluding it and apply explicit permissions last" >&2
          exit 1
        fi
      }
      check_order excluded ${jailed pathArguments false}/bin/jail-probe <<'EOF'
      set PATH=/caller tools/bin
      unset PATH
      EOF
      check_order restored ${jailed pathArguments true}/bin/jail-probe <<'EOF'
      set PATH=/caller tools/bin
      unset PATH
      set PATH=/jail-permissions-path
      EOF
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
            echo "FAIL: $label jailed probe did not deliver the expected masks or environment" >&2
            exit 1
          fi
        }
        check_probe excluded ${jailed pkgs.bubblewrap false}/bin/jail-probe ${expected "unset"}
        # Final permissions must restore PATH without undoing any earlier mask.
        check_probe restored ${jailed pkgs.bubblewrap true}/bin/jail-probe ${expected "value:/jail-permissions-path"}
        echo "AI-JAIL-WRAP: masks, PATH exclusion and final override held inside the jail" | tee "$out"
      else
        cat "$TMPDIR/control.log" >&2
        echo "AI-JAIL-WRAP: structural-only, bubblewrap cannot run in this build sandbox" | tee "$out"
      fi
    '';
  };
}
