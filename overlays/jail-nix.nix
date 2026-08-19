# jail.nix — the sandbox layer's combinator library, not a binary package.
#
# Upstream (https://sr.ht/~alexdavid/jail.nix/, GPL-3.0) is pure Nix: `jail
# name exe permissions` returns ONE `writeShellApplication` that execs
# bubblewrap with the accumulated `--bind`/`--unshare-*` argv. There is no
# program to build here, so this file exports a LIBRARY rather than a
# derivation — the only such export under `pkgs.ai`. That is why the group is
# nested (flake.nix's `packages` flattening strips it by name) instead of
# riding `flatDrvs`, where every value must be a derivation.
#
# LINUX ONLY, as an explicit exclusion rather than a silent no-op: bubblewrap
# is Linux-only, so on darwin the attribute is ABSENT (overlays/default.nix
# gates it) and a consumer gets "attribute missing" instead of a library that
# evaluates and then fails at build time. Same shape as `generic.gluetun`.
#
# LICENSE / CACHE. Upstream is pristine GPL-3.0 with no "or later" notice, so
# `gpl3Only` is the conservative read. Wrappers generated from this library
# embed GPL-derived shell; publishing them to the public binary cache carries
# the ordinary source-offer obligation, satisfied by the pinned public flake
# input in flake.nix.
{
  inputs,
  final,
  ...
}: let
  # Cache-hit parity: the library is initialized against THIS repo's nixpkgs
  # pin, never the consumer's `final`. Every wrapper a consumer builds through
  # it therefore lands on the same store path CI pushed to Cachix, regardless
  # of the consumer's own nixpkgs. `final.stdenv.hostPlatform.system` is the
  # only thing read from the consumer — see
  # dev/fragments/overlays/overlay-pattern.md.
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) lib;

  # ── The applyPatches seam ────────────────────────────────────────────
  # Reviewed mailing-list patches go HERE, as configuration, so a
  # cherry-picked fix never costs a fork. Worked example, deliberately NOT
  # applied: the community `readonly-paths-from-var` realpath-batching patch
  # (~19x wrapper-startup speedup, verified unmerged at the pinned rev) —
  # this repo's profiles do not use that combinator, so applying it would buy
  # nothing and put an unexercised patch in the review path.
  #
  # A patch file lives beside this one as `jail-nix-<topic>.patch`, per the
  # per-package support-file convention in
  # dev/fragments/packaging/naming-conventions.md.
  patches = [];

  # IFD, and cheap on purpose. `applyPatches` sets `preferLocalBuild` and
  # `allowSubstitutes = false`, so this is an unpack + patch + `cp -R` of a
  # ~40-file pure-Nix tree over a source that flake input resolution has
  # ALREADY realized. Unlike the fetch-backed IFD in the rest of this
  # directory there is no network in the critical path, so the cold-runner
  # failure mode `.github/actions/warm-ifd` exists to absorb cannot occur
  # here — that composite warms `.#packages.<system>`, which by design does
  # not reach this attribute.
  patched = ourPkgs.applyPatches {
    name = "jail.nix-patched";
    src = inputs.jail-nix;
    inherit patches;
  };

  # `meta` is stamped by a WRAPPER rather than passed to `applyPatches` or
  # bolted on with `overrideAttrs`, and both rejected shapes fail for a
  # reason worth keeping written down:
  #
  #   - passing `meta` in is a hard eval error ("applyPatches will not merge
  #     'meta', change it in 'src' instead"), and the `src` it points you at
  #     is a bare flake-input path with no `meta` to change;
  #   - `patched.overrideAttrs` is not safe across nixpkgs revisions, because
  #     `applyPatches` DOES NOT ALWAYS RETURN A DERIVATION. On 25.05 it
  #     short-circuits to its bare `src` when `patches == []` — which is the
  #     shipped configuration here — and a store path has no `overrideAttrs`.
  #     The pinned master rework happens to always build one, so this would
  #     be a latent break armed by a routine nixpkgs bump: eval would start
  #     failing with `attribute 'overrideAttrs' missing`, four levels away
  #     from anything naming a patch.
  #
  # The wrapper is unconditional rather than an `isDerivation` branch so that
  # both shapes take the SAME code path — a branch whose second arm never
  # runs here is a branch nobody would notice rotting. It costs one local
  # copy of a small tree.
  src =
    ourPkgs.runCommandLocal "jail.nix-source" {
      meta = {
        description = "Bubblewrap sandbox combinator library for Nix";
        homepage = "https://sr.ht/~alexdavid/jail.nix/";
        license = lib.licenses.gpl3Only;
        platforms = lib.platforms.linux;
      };
    } ''
      cp -R ${patched} "$out"
      chmod -R u+w "$out"
    '';

  upstream = import "${src}/lib";

  # The seam the `ai.sandbox` layer builds on: forwards
  # `additionalCombinators` (repo-owned `git-worktree`, `nix-daemon`,
  # `agent-base`), `basePermissions`, and `bubblewrapPackage` to upstream
  # while holding `pkgs` at this repo's pin.
  #
  # `pkgs` is REFUSED rather than merged over, because both quieter spellings
  # are worse. `{pkgs = ourPkgs;} // opts` lets a caller substitute its own
  # pkgs and lose cache-hit parity for every profile in the repo, and
  # `jail-nix-parity` cannot see that — it tests THIS file, not its callers.
  # `opts // {pkgs = ourPkgs;}` would silently discard what the caller asked
  # for. A throw is the only spelling that cannot be gotten wrong by
  # accident. Callers must not reach `${src}/lib` themselves either; that is
  # the same leak by another route.
  extend = opts:
    if opts ? pkgs
    then
      throw ''
        pkgs.ai.jail.extend: `pkgs` is fixed to this repo's nixpkgs pin and
        cannot be overridden — every sandbox profile is built through this
        library, so a consumer-pin leak here cache-misses all of them at
        once (see checks/jail-nix.nix:jail-nix-parity). Pass
        `additionalCombinators`, `basePermissions` or `bubblewrapPackage`
        instead.
      ''
    else upstream.extend (opts // {pkgs = ourPkgs;});
in {
  inherit extend src;

  # The stock library, and `upstream.init ourPkgs` by construction: callable
  # as `jail name exe permissions` (upstream returns a `__functor` attrset)
  # with `.combinators` alongside.
  lib = extend {};
}
