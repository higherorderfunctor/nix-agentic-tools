# jail.nix packaging checks — the acceptance probes for `pkgs.ai.jail`.
#
# Three things are asserted, and they fail for different reasons:
#
#   jail-nix-trivial — a jail around coreutils BUILDS, execs bubblewrap, and
#     runs `true` inside the sandbox. Catches a broken pin, a patch that does
#     not apply, and a library that composes argv but cannot actually enter a
#     namespace.
#
#     The RUNTIME half is deliberately best-effort, and that is a trade-off
#     rather than an oversight. Unprivileged user namespaces are a host
#     policy (Ubuntu 24.04's AppArmor default, unusual container runtimes),
#     so on a host that denies them this check would be permanently red for a
#     reason that has nothing to do with the package. It therefore gates the
#     execution on an INDEPENDENT `bwrap --unshare-all` positive control and
#     skips only when plain bubblewrap cannot run either. What survives the
#     skip is the structural half, which runs everywhere: a library that
#     stopped emitting a bubblewrap invocation is still caught.
#
#     Be honest about the residual: on such a host this goes green with the
#     runtime claim unproven, and the skip prints `JAIL-NIX-SKIPPED-EXEC` to
#     the build log — which a cached output never re-prints. Measured on the
#     development host, bubblewrap DOES nest inside the nix build sandbox and
#     the execution probe ran for real. If a runner is ever found where it
#     does not, grep that token rather than trusting the check mark.
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

  # Positive control for the comparison above, mirroring `followedPkgs` in
  # checks/cache-hit-parity.nix. Here the OVERLAY's own `inputs.nixpkgs` is
  # rewritten, which is what a consumer using `inputs.nixpkgs.follows` does —
  # so `ourPkgs` genuinely moves and the wrapper MUST land on a different
  # store path. Without this the equality above could go green by becoming a
  # tautology (both sides reading one pkgs set, or a wrapper that stopped
  # embedding pin-dependent paths at all) and nothing would notice.
  followedOverlay = import ../overlays {
    inputs = inputs // {nixpkgs = inputs.nixpkgs-test;};
  };
  followedPkgs = import inputs.nixpkgs-test {
    inherit system;
    config.allowUnfree = true;
    overlays = [followedOverlay];
  };
  followedJail = followedPkgs.ai.jail.lib "jail-nix-probe-true" exe [];

  # None of these three is decoration. jail.nix's `base` permission forwards
  # LANG, HOME and TERM with `fwd-env` (upstream lib/combinators/base.nix),
  # each of which expands to a bare `"$VAR"` inside a `writeShellApplication`
  # running under `set -u` — so ANY of the three being unset kills the
  # wrapper on an unbound variable before bubblewrap is ever reached. `HOME`
  # additionally has to point somewhere creatable, because `base` mounts a
  # tmpfs over it and the build environment's `/homeless-shelter` is not.
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
        # A plain line, NOT a `::notice::` workflow command: nix prefixes
        # every build-log line with the derivation name, so GitHub never
        # parses one from in here, and a cached output never prints at all.
        echo "JAIL-NIX-SKIPPED-EXEC: unprivileged user namespaces unavailable on this host;" >&2
        echo "  ran the structural assertions only. Runtime coverage is BEST-EFFORT by" >&2
        echo "  design — see this check's header for why it is not a hard failure." >&2
        cat "$TMPDIR/bwrap.log" >&2
        echo "skipped-exec — bubblewrap positive control failed; structural assertions passed" > "$out"
      fi
    '';

    # No `jailRunEnv`: nothing is executed here, so `LANG`/`TERM`/`HOME` would
    # be dead configuration that reads as if a jail were about to run.
    jail-nix-extend = pkgs.runCommand "jail-nix-extend" {} ''
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
      followed="${followedJail}"

      if [ "$ours" != "$theirs" ]; then
        echo "FAIL: jail.nix is initialized against the CONSUMER's nixpkgs." >&2
        echo "  ours:   $ours" >&2
        echo "  theirs: $theirs" >&2
        echo "" >&2
        echo "overlays/jail-nix.nix must pass its own \`ourPkgs\` to \`extend\`," >&2
        echo "never \`final\`. See dev/fragments/overlays/cache-hit-parity.md." >&2
        exit 1
      fi

      # The control. A `follows` rewrite moves the overlay's OWN pin, so this
      # path must differ; if it does not, the equality above proved nothing.
      if [ "$ours" = "$followed" ]; then
        echo "FAIL: the parity comparison is a tautology." >&2
        echo "  Rewriting the overlay's own nixpkgs to nixpkgs-test produced the" >&2
        echo "  SAME wrapper ($ours), so this check cannot detect a consumer-pin" >&2
        echo "  leak and its green result is meaningless." >&2
        exit 1
      fi

      echo "ok — jail wrappers are pin-independent ($ours)" > "$out"
      echo "control — a follows rewrite moves them ($followed)" >> "$out"
    '';
  }
