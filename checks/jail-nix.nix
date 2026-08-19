# jail.nix packaging checks — the acceptance probes for `pkgs.ai.jail`.
#
# Three things are asserted, and they fail for different reasons:
#
#   jail-nix-trivial — a jail around coreutils BUILDS, execs bubblewrap, and
#     runs `true` inside the sandbox. Catches a broken pin, a patch that does
#     not apply, and a library that composes argv but cannot actually enter a
#     namespace.
#   jail-nix-extend  — `extend` with an additional combinator evaluates and
#     the combinator is reachable from a jail. This is the exact seam the
#     `ai.sandbox` layer registers `git-worktree` / `nix-daemon` /
#     `agent-base` through, so it is worth a probe of its own rather than
#     being implied by the one above.
#   jail-nix-parity  — the wrapper a CONSUMER's nixpkgs produces is the same
#     store path ours does. `checks.cache-hit-parity` cannot cover this: its
#     registry compares `self.packages.<system>.<name>` against a consumer
#     attr path, and `pkgs.ai.jail` is deliberately not in `packages` (it is
#     a library, not a derivation). Parity still matters — every profile the
#     sandbox layer ships is built THROUGH this library, so a consumer-pin
#     leak here would cache-miss every one of them at once.
#
# Linux-only, matching the overlay: `pkgs.ai.jail` is absent on darwin, so
# this file contributes no checks there.
{
  inputs,
  lib,
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;

  # Held constant across both sides of the parity probe on purpose: the exe
  # is an INPUT to the jail, so letting each side supply its own would make
  # the wrappers differ for a legitimate reason and turn the comparison into
  # a tautology. Everything that must come from our pin — bubblewrap, bash,
  # coreutils, writeShellApplication — is supplied by the library itself.
  exe = "${pkgs.coreutils}/bin/true";

  trivialJail = pkgs.ai.jail.lib "jail-nix-probe-true" exe [];

  # A no-op combinator: `additionalCombinators` receives the built-in impl
  # map and returns raw `state -> state` functions (see `allCombinators` in
  # the upstream lib/jail.nix), NOT the `{sig, doc, impl}` records the
  # in-tree combinator FILES carry.
  extendedLib = pkgs.ai.jail.extend {
    additionalCombinators = _: {
      repo-noop = state: state;
    };
  };
  extendedJail = extendedLib "jail-nix-probe-extended" exe (c: [c.repo-noop]);

  # Simulate a consumer whose own nixpkgs differs from ours — the same
  # deliberately-divergent pin checks/cache-hit-parity.nix uses.
  consumerPkgs = import inputs.nixpkgs-test {
    inherit system;
    config.allowUnfree = true;
    overlays = [self.overlays.default];
  };
  consumerJail = consumerPkgs.ai.jail.lib "jail-nix-probe-true" exe [];

  # `LANG` and `TERM` are not decoration. jail.nix's `base` permission
  # forwards both with `fwd-env`, which expands to a bare `"$LANG"` inside a
  # `writeShellApplication` running under `set -u` — unset, the wrapper dies
  # on an unbound variable before bubblewrap is ever reached. `HOME` is
  # needed because `base` mounts a tmpfs over it and the build environment's
  # `/homeless-shelter` is not creatable.
  jailRunEnv = {
    LANG = "C";
    TERM = "dumb";
  };
in
  lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    jail-nix-trivial = pkgs.runCommand "jail-nix-trivial" jailRunEnv ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      # Structural assertion, and the reason the capability gate below can be
      # allowed to skip the execution without going quietly green: it holds
      # on any machine, so a library that stopped emitting a bubblewrap
      # invocation is caught even where the sandbox cannot be entered.
      script="${trivialJail}/bin/jail-nix-probe-true"
      for token in bwrap --unshare-user --unshare-net --die-with-parent; do
        if ! grep -qF -- "$token" "$script"; then
          echo "FAIL: generated wrapper does not contain '$token'" >&2
          echo "--- wrapper ---" >&2
          cat "$script" >&2
          exit 1
        fi
      done

      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"

      # Independent positive control. Unprivileged user namespaces are a
      # KERNEL/host-policy capability (Ubuntu's AppArmor restriction, an
      # unusual container runtime), not a property of this package, so the
      # execution probe is gated on plain bubblewrap succeeding rather than
      # on the thing under test. If the control passes, the jail MUST run.
      if "${pkgs.bubblewrap}/bin/bwrap" --unshare-all \
           --ro-bind /nix/store /nix/store --proc /proc --dev /dev \
           -- ${exe} 2>"$TMPDIR/bwrap.log"; then
        "$script"
        echo "ok — trivial jail built and ran 'true' inside the sandbox" > "$out"
      else
        echo "::notice::unprivileged user namespaces unavailable here; ran the structural assertions only" >&2
        cat "$TMPDIR/bwrap.log" >&2
        echo "skipped-exec — bubblewrap positive control failed; structural assertions passed" > "$out"
      fi
    '';

    jail-nix-extend = pkgs.runCommand "jail-nix-extend" jailRunEnv ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      # Building it is the assertion: a combinator that failed to register
      # throws at eval, and one that corrupted the state throws while the
      # wrapper is rendered. Nothing is executed — `jail-nix-trivial` already
      # owns the runtime claim, and repeating it here would only duplicate
      # the host-capability gate.
      test -x "${extendedJail}/bin/jail-nix-probe-extended"
      echo "ok — extend registered an additional combinator and rendered a jail" > "$out"
    '';

    jail-nix-parity = pkgs.runCommand "jail-nix-parity" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      ours="${trivialJail}"
      theirs="${consumerJail}"
      if [ "$ours" = "$theirs" ]; then
        echo "ok — jail wrappers are pin-independent ($ours)" > "$out"
      else
        echo "FAIL: jail.nix is initialized against the CONSUMER's nixpkgs." >&2
        echo "  ours:   $ours" >&2
        echo "  theirs: $theirs" >&2
        echo "" >&2
        echo "overlays/jail-nix.nix must pass its own \`ourPkgs\` to \`extend\`," >&2
        echo "never \`final\`. See dev/fragments/overlays/cache-hit-parity.md." >&2
        exit 1
      fi
    '';
  }
