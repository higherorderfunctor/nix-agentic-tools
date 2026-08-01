# oh-my-posh — the prompt theme engine, re-pinned onto this repo's update
# cadence. An `.override` (to swap in a floor-derived Go toolchain) plus a
# thin `.overrideAttrs` (version, src, vendorHash, passthru) over nixpkgs'
# own `buildGoModule` derivation.
#
# THREE OVERRIDES THE SIBLING REPO CARRIED ARE DROPPED, all measured to be
# dead weight now that nixpkgs' expression is `finalAttrs`-style — a bare
# version override already produces the right values:
#
#   - the `ldflags` rewrite that patched `build.Version` by string
#     surgery. nixpkgs interpolates `finalAttrs.version` into that flag,
#     so it follows the override on its own.
#   - the `meta.changelog` override. Same reason — it interpolates
#     `finalAttrs.version`.
#   - the `postInstall`. It was a byte-for-byte copy of nixpkgs'.
#
# `postPatch` IS overridden, and it did not used to be. Inheriting
# nixpkgs' was justified as "costs nothing and leaves nothing to keep in
# sync"; the 29.37.0 -> 30.1.1 bump falsified the second half. nixpkgs
# pins 29.1.0 and its list still names `cli/image/image_test.go`, which
# upstream DELETED in v30 (no replacement anywhere in the tree), so its
# bare `rm` failed the patchPhase and the whole vendor build with it:
#
#   > Running phase: patchPhase
#   > rm: cannot remove 'cli/image/image_test.go': No such file or directory
#
# That surfaced as `HELD BACK: oh-my-posh (nix-update or build failed)`
# in the sweep, and NOT as a hash problem — `fix_sidecar_hashes`
# correctly reported "goModules build failed without a '-go-modules' hash
# mismatch" and declined to invent a hash. The self-heal was working; the
# inherited patch was not.
#
# The removals split by how much each is load-bearing, measured at
# 29.36.0 with the check phase enabled — three builds, not reasoned
# about:
#
#   - nixpkgs' list (image, migrate_glyphs, notice, upgrade): GREEN.
#   - the sibling's list (migrate_glyphs, nba, notice, upgrade): also
#     GREEN. Both work, so the divergence buys nothing.
#   - POSITIVE CONTROL, remove NOTHING: FAILS, and fails on exactly one
#     test — `--- FAIL: TestUpgrade … upgrade_test.go:84` in
#     `src/segments`. `cli/image`, `cli/upgrade` and `config` all report
#     `ok`. Without this run, "nixpkgs' list passes" would be equally
#     consistent with the tests not running at all.
#
# So `segments/upgrade_test.go` is the ONE removal doing work, and it
# keeps a strict `rm`: if upstream moves it, the build must fail loudly
# rather than silently re-enable a network-dependent test. The other
# three keep nixpkgs' names — so no test disabled today quietly starts
# running — but take `rm -f`, because they are exactly the ones upstream
# churns and nixpkgs' list lags its own pin.
#
# `-f` cannot mask a regression here. A file that upstream RENAMED rather
# than deleted stops being removed, and the check phase then fails on the
# network test — loudly, just at a different phase. The only thing `-f`
# suppresses is "the file we wanted gone is already gone", which is the
# outcome we wanted.
#
# The tree this produces at 29.37.0 is byte-identical to what nixpkgs'
# `postPatch` produced (all four files still exist there), so `vendorHash`
# is unchanged by this commit — verified by building `.goModules` against
# the untouched sidecar hash. `postPatch` feeds the `goModules`
# derivation, but `vendorHash` is a fixed-output hash over the vendor
# tree CONTENT, so an identical tree keeps an identical hash even though
# the `.drv` moves.
#
# Note that `overrideAttrs` REPLACES `postPatch` rather than appending, so
# this restates the whole list rather than adding to nixpkgs'.
#
# THE GO TOOLCHAIN IS DERIVED, NOT PINNED, and the seemingly-redundant
# `goFloor` below is deliberate — do not "clean it up". The sibling pinned
# `go-bin.versions."1.26.0"` here; that was a gap-filler when written and
# is a DOWNGRADE today, because our nixpkgs pin has since moved to go
# 1.26.5 and nothing announced the transition. `vu.goToolchainForFloor`
# declares the durable fact instead — oh-my-posh 29.36.0's `src/go.mod`
# says `go 1.26.0` with no `toolchain` directive — and returns
# `ourPkgs.go` whenever our pin satisfies it (which it does today, so this
# resolves to plain go 1.26.5 and go-bin is never instantiated). It only
# reaches for a prebuilt toolchain if upstream raises the floor past
# nixpkgs-unstable, and it self-clears the moment nixpkgs catches up. See
# the helper's header in overlays/lib.nix, and
# checks/go-toolchain-floor.nix for its branch coverage.
#
# vendorHash lives in the SIDECAR rather than inline: `mkUpdateScript`
# rebuilds the sidecar from scratch on every write, so any key it does not
# itself produce is destroyed. `vu.mkGoVendorFix` runs as `extraExtract`
# right after and restores it; the `or fakeHash` read covers that window.
#
# AND `postPatch` IS AN INPUT TO IT. buildGoModule threads `postPatch`
# into the `goModules` derivation (build-support/go/module.nix), so which
# test files get removed changes the vendor set: nixpkgs' list drops
# `cli/image/image_test.go`, which is the only importer of
# `golang.org/x/image/font/gofont/gomono`, so `go mod vendor` omits that
# package and `vendor/modules.txt` loses the line. The sibling repo's
# vendorHash therefore does NOT transfer — it was computed against the
# sibling's postPatch, which keeps that test. Landing it here looked fine
# on this workstation only because the sibling's identical-name
# fixed-output path was already in the local store, so nix skipped the
# build and validated nothing; a clean store (CI) would have failed on a
# vendor hash mismatch. Never carry a vendorHash across a `postPatch`
# change, and never trust "it built" when the FOD may have been
# substituted — run the update script against a perturbed version, which
# forces the real computation.
#
# Not agentic-tools-specific — it lives under overlays/generic/ so the
# earmarked repo split can lift the subtree whole.
#
# Free (MIT). ensureUnfreeCheck in default.nix passes free packages
# through unwrapped.
{
  inputs,
  final,
  ...
}: let
  # Cache-hit parity: every build input comes from THIS repo's nixpkgs
  # pin, never the consumer's `final`. `final.stdenv.hostPlatform.system`
  # is the only thing read from the consumer — see
  # dev/fragments/overlays/overlay-pattern.md. go-overlay is applied
  # INSIDE this import, the same way overlays/agnix.nix applies
  # rust-overlay, so `go-bin` is still resolved against our own pin.
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [inputs.go-overlay.overlays.default];
  };
  inherit (ourPkgs) fetchzip lib;
  vu = import ../lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./oh-my-posh-sources.json);

  # Bound once: passed to BOTH the vendor fixer and the update script, and
  # the default (`overlays/<pname>-sources.json`) is wrong for a grouped
  # subtree.
  sourcesFile = "overlays/generic/oh-my-posh-sources.json";

  fixVendorHash = vu.mkGoVendorFix {
    attr = "oh-my-posh";
    pkgs = ourPkgs;
    pname = "oh-my-posh";
    inherit sourcesFile;
  };

  # `go` directive of src/go.mod at the packaged version. Raise it when
  # upstream raises it; never lower it, and never replace it with a
  # toolchain version.
  goFloor = "1.26.0";
  go = vu.goToolchainForFloor {
    floor = goFloor;
    goBin = ourPkgs.go-bin;
    ourGo = ourPkgs.go;
    pname = "oh-my-posh";
    inherit lib;
  };
in
  (ourPkgs.oh-my-posh.override {
    buildGoModule = ourPkgs.buildGoModule.override {inherit go;};
  })
  .overrideAttrs (prev: {
    inherit (sources) version;
    # fetchzip, so the recorded hash is over the UNPACKED NAR — which is
    # why the updateScript below prefetches with --unpack. nixpkgs derives
    # `sourceRoot` from `finalAttrs.src.name`, and fetchzip names its
    # output "source" exactly as fetchFromGitHub does, so the `src/`
    # subdirectory this project builds from still resolves.
    src = fetchzip {inherit (sources.src) url hash;};
    vendorHash = sources.vendorHash or lib.fakeHash;

    # See the header for why this is overridden rather than inherited,
    # and why exactly one of the four removals is strict.
    postPatch = ''
      # Load-bearing (measured): without it `TestUpgrade` fails. Strict
      # `rm`, so an upstream move fails the build instead of silently
      # re-enabling a network-dependent test.
      rm segments/upgrade_test.go
      # nixpkgs' remaining names, kept so nothing disabled today starts
      # running — but tolerant, because upstream deletes these and
      # nixpkgs' list lags its own pin. v30 dropped image_test.go.
      rm -f cli/image/image_test.go config/migrate_glyphs_test.go \
            cli/upgrade/notice_test.go
    '';

    # Merge, never replace: buildGoModule hangs `goModules` and
    # `overrideModAttrs` here, module.nix warns loudly when an overlay
    # drops them, and `fixVendorHash` builds `.goModules` through this
    # very attrset. See the nix-standards fragment.
    passthru =
      (prev.passthru or {})
      // {
        inherit fixVendorHash;
        updateScript = vu.ghArchiveUpdateScript {
          extraExtract = "${fixVendorHash}";
          pkgs = ourPkgs;
          pname = "oh-my-posh";
          repo = "JanDeDobbeleer/oh-my-posh";
          inherit sourcesFile;
        };
      };
  })
