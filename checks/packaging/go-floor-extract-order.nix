# go-floor-extract-order — assert every sidecar-pinned Go package derives
# its go.mod floor BEFORE anything in its update chain compiles Go.
#
# This is the gate for the bug that held glab and oh-my-posh back on every
# 4x/day sweep from 2026-08-30 to 2026-09-01, and that was latent in five
# more packages.
#
# THE ORDER. `mkUpdateScript`'s `buildCandidate` rebuilds the sidecar from
# scratch (`jq -n '{version: $v}'`), so at the moment `extraExtract` starts,
# `goFloor` is ABSENT and reads as `vu.goFloorUnknown` ("0"), which
# `mkGoToolchain` accepts vacuously. The compiler no longer depends on the
# floor (it is always the newest stable locked go-overlay release), but the
# floor fixer must still run before the Go-compiling vendor fixer: a release
# whose go.mod outruns the locked Go then stops at `mkGoToolchain`'s named
# throw instead of dying inside the vendor build with `go.mod requires go >=
# X`. Until 2026-09-01 the wrong vendor-before-floor order held glab and
# oh-my-posh back on every sweep, because the toolchain was then selected from
# the floor (it stayed floor-selected until mkGoToolchain picked the newest
# locked release); the order stays gated because the chain is still generated
# by `mkGoUpdateExtract`.
#
# WHY A STRUCTURAL CHECK AND NOT AN EXISTING ONE. Neither sibling can
# catch this, and neither can be extended to:
#
#   - `checks/packaging/go-floor-drift.nix` compares the COMMITTED floor against the
#     COMMITTED src's go.mod. It gates the resulting STATE, never the
#     order that produces it.
#   - `checks/packaging/go-toolchain-floor.nix` is eval-only coverage of the
#     `mkGoToolchain` contract. It never touches an updateScript.
#
# WHAT IT READS. `passthru.goUpdateExtract` — the single flat script
# `vu.mkGoUpdateExtract` emits. Reading that rather than
# `passthru.updateScript` is load-bearing: beads composes its update
# script and its vendor fixer from PAIR wrappers whose text contains only
# the sub-script store paths, so a check that grepped the top-level
# updateScript would silently pass for beads and beads-dolt while proving
# nothing about either.
#
# NO REGISTRY, for the reason `go-floor-drift.nix` gives at length: a
# list a new Go package could be added without touching is precisely how
# a package ends up unprotected. Subjects are discovered by filtering for
# `passthru.fixGoFloor.goFloorDestination == "sidecar"`, which distinguishes
# this release-update contract from recipe-owned trunk floors. A sidecar fixer
# with NO `goUpdateExtract` FAILS, because that is exactly the shape of
# hand-rolling the chain again.
#
# `beads.dolt` is walked EXPLICITLY. It is a ninth Go package, and it is
# NOT A TOP-LEVEL ENTRY of `self.ciPackages.<system>` — it is reachable
# only as a nested attribute of one, `self.ciPackages.<system>.beads.dolt`.
# `lib.filterAttrs` over that set therefore never visits it, which is the
# same blind spot `packages/beads/checks/beads-contracts.nix` exists to cover for its
# floor. Any future discovery-based check inherits it.
#
# TWO THINGS THIS ASSERTS, and the second one is why reading the flat
# chain is not enough on its own:
#
#   1. ORDER inside `passthru.goUpdateExtract`.
#   2. That `passthru.updateScript` ACTUALLY RUNS that chain — asserted
#      through its closure, not its text. Without this, a future edit
#      could leave `goUpdateExtract` in passthru (keeping this check
#      green) while wiring a hand-written `extraExtract` into the update
#      script, and the bug would return under a passing gate. The
#      closure reaches it even through beads' pair wrapper, which is why
#      the text-vs-closure distinction matters: `update-beads-pair`'s
#      TEXT names only its two sub-scripts, but its CLOSURE contains
#      `go-update-extract-beads`.
#
# The order comparison is emitted ONCE, by `orderAssertFn`, and consumed
# by both the real check and the positive control. An earlier version
# re-implemented it in the control, which meant flipping the real
# comparison from `-ge` to `-lt` left the control still reporting "ok" —
# a control that cannot fail is not a control.
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    pkgSet = self.ciPackages.${system};

    discovered =
      lib.filterAttrs
      (_: p:
        (p.passthru or {}) ? fixGoFloor
        && (p.passthru.fixGoFloor.goFloorDestination or null) == "sidecar")
      pkgSet;

    # Not in `self.ciPackages` — see the header.
    extras = lib.optionalAttrs ((pkgSet.beads.passthru or {}) ? dolt) {
      "beads.dolt" = pkgSet.beads.dolt;
    };

    subjects = discovered // extras;

    # The ONE definition of the ordering rule. Emitted as a shell function
    # so the real check and the positive control run the SAME comparison —
    # see the header for why a re-implemented control is not a control.
    #
    # `assert_chain_order <chain-file> <label>`: exits 0 if the chain is
    # ordered [src] -> floor -> vendor, non-zero (with a diagnosis on
    # stderr) otherwise.
    orderAssertFn = ''
      # Line number of a stage inside the chain. Matched on the store-path
      # BASENAME PREFIX rather than a pname, so it keeps working for
      # packages whose attr and pname differ (`beads.dolt` -> `beads-dolt`).
      #
      # `grep -F`, not a basic regex: every pattern carries a `-`, and a
      # regex `.` would match any character. A check that matches more than
      # it names proves less than it appears to.
      line_of() {
        ${pkgs.gnugrep}/bin/grep -n -F -- "$1" "$2" \
          | ${pkgs.coreutils}/bin/head -n1 \
          | ${pkgs.coreutils}/bin/cut -d: -f1
      }

      assert_chain_order() {
        local chain="$1" label="$2" floor vendor src

        floor=$(line_of "-fix-go-floor-" "$chain" || :)
        vendor=$(line_of "-fix-vendor-" "$chain" || :)
        src=$(line_of "-fix-src-" "$chain" || :)

        if [ -z "$floor" ]; then
          echo "FAIL: $label: no floor fixer in its extract chain" >&2
          cat "$chain" >&2
          return 1
        fi
        if [ -z "$vendor" ]; then
          echo "FAIL: $label: no vendor fixer in its extract chain" >&2
          cat "$chain" >&2
          return 1
        fi

        # THE INVARIANT. The vendor fixer compiles Go under the toolchain
        # the floor selects, so the floor must already be written.
        if [ "$floor" -ge "$vendor" ]; then
          echo "FAIL: $label: floor fixer (line $floor) does not precede the vendor fixer (line $vendor)." >&2
          echo "" >&2
          echo "The vendor fixer builds .goModules, which compiles Go. With the floor" >&2
          echo "still unwritten the sidecar reads goFloorUnknown, so a release whose" >&2
          echo "go.mod floor exceeds the locked Go fails with 'go.mod requires go >= X'" >&2
          echo "instead of mkGoToolchain's named throw." >&2
          cat "$chain" >&2
          return 1
        fi

        # The other edge, only for packages whose src hash comes from a
        # fixer rather than from mkUpdateScript's prefetch: the floor fixer
        # builds `.src`, which holds lib.fakeHash until then.
        if [ -n "$src" ] && [ "$src" -ge "$floor" ]; then
          echo "FAIL: $label: src fixer (line $src) does not precede the floor fixer (line $floor)." >&2
          echo "The floor fixer builds .src, so a sidecar-held srcHash must be restored first." >&2
          cat "$chain" >&2
          return 1
        fi

        echo "ok — $label: src=''${src:-prefetched} floor=$floor vendor=$vendor"
      }
    '';

    drvName = name: "go-floor-extract-order-${lib.replaceStrings ["."] ["-"] name}";

    mkCheck = name: p:
      if !((p.passthru or {}) ? goUpdateExtract)
      then
        pkgs.runCommand (drvName name) {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          echo "FAIL: ${name} carries passthru.fixGoFloor but no passthru.goUpdateExtract." >&2
          echo "" >&2
          echo "That means its extraExtract chain is hand-written rather than emitted by" >&2
          echo "vu.mkGoUpdateExtract — the exact shape that put the Go-compiling vendor" >&2
          echo "fixer before the floor fixer in all seven chains and held glab and" >&2
          echo "oh-my-posh back on every sweep." >&2
          echo "" >&2
          echo "Fix: build the chain with vu.mkGoUpdateExtract and expose its script as" >&2
          echo "passthru.goUpdateExtract. See lib/packaging.nix." >&2
          exit 1
        ''
      else
        pkgs.runCommand (drvName name) ({
            extract = p.passthru.goUpdateExtract;
          }
          # Closure of the script the pipeline ACTUALLY invokes. Asserting
          # against this is what stops `goUpdateExtract` from becoming a
          # decorative passthru attribute that no longer describes the real
          # chain. Omitted only if a subject somehow has no updateScript,
          # which is itself reported below rather than silently skipped.
          // lib.optionalAttrs ((p.passthru or {}) ? updateScript) {
            exportReferencesGraph = ["updateClosure" p.passthru.updateScript];
          }) ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          ${orderAssertFn}

          assert_chain_order "$extract" "${name}"

          ${
            if (p.passthru or {}) ? updateScript
            then ''
              # The chain must be REACHED by the update script, not merely
              # exposed beside it. Text would not do: beads' pair wrapper
              # names only its two sub-scripts, while its CLOSURE contains
              # the per-package chain.
              if ! ${pkgs.gnugrep}/bin/grep -qF -- "$extract" updateClosure; then
                echo "FAIL: ${name}: passthru.goUpdateExtract is not in passthru.updateScript's closure." >&2
                echo "" >&2
                echo "The ordered chain is exposed but the update script does not run it, so" >&2
                echo "the order asserted above is not the order the sweep executes." >&2
                echo "  chain:  $extract" >&2
                exit 1
              fi
            ''
            else ''
              echo "FAIL: ${name}: carries goUpdateExtract but no passthru.updateScript," >&2
              echo "so nothing proves the ordered chain is ever run." >&2
              exit 1
            ''
          }

          assert_chain_order "$extract" "${name}" > "$out"
        '';

    checks = lib.mapAttrs' (name: p: lib.nameValuePair (drvName name) (mkCheck name p)) subjects;

    # ── Positive control ─────────────────────────────────────────────
    # Without this, "every subject passed" is equally consistent with the
    # assertion never having run. It calls `assert_chain_order` — the SAME
    # function the real checks call — on a deliberately mis-ordered chain
    # and requires it to FAIL. Flip the `-ge` above to `-lt` and this goes
    # red, which is the property a re-implemented control did not have.
    misordered = pkgs.writeText "go-update-extract-MISORDERED" ''
      /nix/store/0000000000000000000000000000000-fix-vendor-fixture
      /nix/store/0000000000000000000000000000000-fix-go-floor-fixture
    '';

    # Second fixture: src AFTER the floor, which the real subjects cannot
    # exercise (only glab carries a src fixer, and it is ordered correctly).
    misorderedSrc = pkgs.writeText "go-update-extract-MISORDERED-SRC" ''
      /nix/store/0000000000000000000000000000000-fix-go-floor-fixture
      /nix/store/0000000000000000000000000000000-fix-src-fixture
      /nix/store/0000000000000000000000000000000-fix-vendor-fixture
    '';

    positiveControl = pkgs.runCommand "go-floor-extract-order-positive-control" {} ''
      ${orderAssertFn}

      # `set -e` is NOT armed in a runCommand's shell by default for these
      # branches, but be explicit: each call is expected to return non-zero,
      # so guard it rather than letting it abort.
      if assert_chain_order "${misordered}" "control-vendor-first" 2>/dev/null; then
        echo "FAIL: a floor-AFTER-vendor chain was accepted. The ordering assertion" >&2
        echo "no longer detects the bug this check exists for, so every green result" >&2
        echo "it reports is meaningless." >&2
        exit 1
      fi

      if assert_chain_order "${misorderedSrc}" "control-src-after-floor" 2>/dev/null; then
        echo "FAIL: a src-AFTER-floor chain was accepted. The floor fixer builds .src," >&2
        echo "so that ordering breaks glab's shape and must be rejected." >&2
        exit 1
      fi

      echo "ok — the invariant rejects both a floor-after-vendor and a src-after-floor chain" > "$out"
    '';
  in
    checks // {go-floor-extract-order-positive-control = positiveControl;};
}
