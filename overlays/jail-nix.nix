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
  #
  # `meta` is attached with `overrideAttrs` rather than passed in: passing it
  # to `applyPatches` is a hard eval error ("applyPatches will not merge
  # 'meta', change it in 'src' instead"), and the `src` it points you at is a
  # bare flake-input path with no `meta` to change.
  src =
    (ourPkgs.applyPatches {
      name = "jail.nix-source";
      src = inputs.jail-nix;
      inherit patches;
    })
    .overrideAttrs (_: {
      meta = {
        description = "Bubblewrap sandbox combinator library for Nix";
        homepage = "https://sr.ht/~alexdavid/jail.nix/";
        license = lib.licenses.gpl3Only;
        platforms = lib.platforms.linux;
      };
    });

  upstream = import "${src}/lib";

  # The seam the `ai.sandbox` layer builds on: forwards
  # `additionalCombinators` (repo-owned `git-worktree`, `nix-daemon`,
  # `agent-base`), `basePermissions`, and `bubblewrapPackage` to upstream
  # while holding `pkgs` at this repo's pin. Callers must never reach
  # `${src}/lib` themselves — that is how the pin leaks.
  extend = opts: upstream.extend ({pkgs = ourPkgs;} // opts);
in {
  inherit extend src;

  # The stock library, and `upstream.init ourPkgs` by construction: callable
  # as `jail name exe permissions` (upstream returns a `__functor` attrset)
  # with `.combinators` alongside.
  lib = extend {};
}
