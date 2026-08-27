# strictdoc — re-exported from UPSTREAM'S OWN FLAKE
# (`inputs.strictdoc.packages.<system>.default`), unchanged.
#
# This file used to be a first-party build: nixpkgs' `strictdoc` recipe with
# the version and `src` moved onto the latest release through a
# `strictdoc-sources.json` sidecar, plus two dependency adjustments nixpkgs'
# dependency set needed (reqif pinned forward to 0.1.0, pygments relaxed off
# its exact 2.21.0 pin). All of that is gone. Upstream's flake is a uv2nix
# package set built from the repository's own `uv.lock`, which pins every
# Python dependency to the exact PyPI artifact the release was tested against
# — reqif and pygments included — so both adjustments are dead, not merely
# unnecessary here.
#
# Every sdoc session, flake check and devShell in this repository runs this
# package (SLICE-STRICTDOC-OVERLAY, docs/plans/strictdoc-tooling/
# 03-executable-rules.sdoc). That node still describes the retired
# first-party build; see MECH-STRICTDOC-UPSTREAM-FLAKE in the plan backlog.
#
# ── What upstream's package IS, because it constrains consumers ────────────
#
# `mkApplication` over a uv2nix virtual environment. `$out` holds
# `bin/strictdoc` and NOTHING ELSE — no interpreter, no activation scripts and
# no `lib/pythonX.Y/site-packages`. The interpreter that carries strictdoc and
# its dependency closure is the venv referenced by that script's shebang, and
# it is not a flake output. A consumer that needs strictdoc as a LIBRARY
# rather than as a CLI has to reach it that way — see
# ./strictdoc-grammar-extract.nix, the only one that does.
#
# `dependencies` exists but is uv2nix-shaped: an ATTRSET of name → extras,
# not nixpkgs' list of derivations. Anything that used to splice it will
# throw rather than silently mis-resolve.
#
# ── Extended by plain attrset update, not `overrideAttrs` ──────────────────
#
# Same contract as ./../semble.nix: `//` preserves the upstream derivation's
# drvPath and outPath byte for byte, which is what lets a consumer on a
# different nixpkgs substitute upstream's build (and the copy mirrored into
# this project's cache) instead of rebuilding it. `overrideAttrs` would
# produce a different derivation for no gain.
#
# Two things the first-party build carried do NOT come back:
#   * The `version ==` install check. The version assertion moved to where it
#     can still hold — the release is whatever the pinned input builds, and
#     `strictdoc version` reporting it is checked by hand at input bumps
#     rather than asserted against a sidecar that no longer exists.
#   * `passthru.updateScript`. There is no sidecar to rewrite; the input is
#     bumped by the ordinary flake-input sweep, claimed below.
#
# No `ourPkgs` here, and no cache-hit-parity concern of the usual kind: the
# derivation closes over upstream's locked nixpkgs, never `final`/`prev`, so
# its store path is the same whatever nixpkgs a consumer brings. The
# `strictdoc` row in config/cache-hit-parity-targets.nix still holds and is
# still worth keeping — it is what would catch a later edit that reintroduces
# a `final`-bound wrapper around this package.
{
  inputs,
  final,
  ...
}: let
  strictdoc = inputs.strictdoc.packages.${final.stdenv.hostPlatform.system}.default;
in
  strictdoc
  // {
    passthru =
      (strictdoc.passthru or {})
      // {
        # checks.update-targets-parity accepts a versioned package whose
        # update owner is a declared flake input. Plain attrset extension
        # preserves the upstream drvPath/outPath identity.
        updateFlakeInput = "strictdoc";
      };
  }
