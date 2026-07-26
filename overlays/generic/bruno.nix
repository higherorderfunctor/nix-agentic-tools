# bruno — the open-source API client, re-pinned onto this repo's update
# cadence. Our pin sits at 4.0.0; the nixpkgs pin ships 3.5.2. Built from
# source, never from the prebuilt .deb.
#
# `.override`, NOT `overrideAttrs`, AND THAT IS NOT A STYLE CHOICE.
# `buildNpmPackage` is a `lib.extendMkDerivation`, and its `extendDrvArgs`
# computes `npmDeps = fetchNpmDeps { hash = npmDepsHash; src; postPatch; ... }`
# from the INCOMING args. `overrideAttrs` composes on top of that OUTPUT, so
# an `npmDepsHash` injected there is INERT. Measured on this package:
#
#   pkgs.bruno.overrideAttrs (_: {version = "4.0.0"; npmDepsHash = <fake>;})
#     -> version      = "4.0.0"          (moved)
#     -> npmDeps.name = "bruno-3.5.2-npm-deps"
#     -> npmDeps.outputHash = sha256-4VsSXiHj/INCu4ryZ+JxPbfDpsgIb5eYvOUYz+gbKEE=
#                                        (3.5.2's hash — the injected one ignored)
#
# That shape builds 4.0.0 source against 3.5.2's dependency set with NO
# error. The same `.override` was measured to yield `bruno-4.0.0-npm-deps`
# carrying the hash we passed. So the thin-`overrideAttrs` shape used by the
# btop / gh / otel-tui / pnpm files in this directory does NOT transfer to a
# `buildNpmPackage`; wrap the BUILDER instead, the way overlays/lib.nix's
# header for `fodHashFixFn` and the git-tools fragment describe.
#
# THE SRC IS RE-POINTED, NOT RESTATED. `pkgs.bruno.src` is
# `fetchFromGitHub`'s own `lib.makeOverridable`, so overriding `tag` + `hash`
# keeps `owner`, `repo` and — critically — `postFetch`, which runs
# `npm-lockfile-fix` over package-lock.json and is therefore an INPUT to
# `npmDepsHash`. nixpkgs passes `tag` (the fetcher asserts exactly one of
# `rev`/`tag`), so only `tag` is overridden.
#
# That is also why BOTH hashes live in the sidecar and why neither comes from
# `mkUpdateScript`'s prefetch path: the recorded src hash has to be over the
# POST-`postFetch` tree, which `nix-prefetch-url --unpack` cannot produce
# (measured: sha256-uZsw… from the prefetch versus sha256-M4oN… from the
# fetcher). `platforms = {}` therefore records the version alone, and
# `vu.mkNpmDepsFix` restores `srcHash` then `npmDepsHash` as `extraExtract`
# right after the write — which is also why both reads below are
# `sources.<key> or lib.fakeHash`: the `or` covers exactly that window.
#
# THE VERSION FIX IS NOT COSMETIC. nixpkgs' expression is
# `buildNpmPackage rec { … }` and its `postPatch` interpolates the ARGUMENT
# `version`, not `finalAttrs.version` — two `jq '.version |= "3.5.2"'` lines
# rewriting packages/bruno-electron/package.json and
# packages/bruno-app/package.json. Left alone, the shipped app reports 3.5.2
# in its sidebar and About page while being 4.0.0 — the same
# argument-vs-`finalAttrs` trap generic/pnpm-major.nix guards against.
# `replaceStrings` re-points it without restating the phase. No eval-time
# guard is needed here and none would be honest: `replaceStrings` rewrites
# EVERY occurrence of the upstream version, so it cannot silently miss one,
# and if upstream ever switches to `finalAttrs.version` (or drops the jq
# lines) this simply becomes a no-op over already-correct output.
#
# Measured: the rewrite does NOT move `npmDepsHash`, even though `postPatch`
# IS an input to `fetchNpmDeps`. Two fake-hash builds — from two DISTINCT
# `bruno-4.0.0-npm-deps.drv` store paths, one with the rewrite and one
# without, so both genuinely ran — reported the same
# got: sha256-Jrlpztg1JxuPaLD4O9elOaU1eFH3dmr6oWwi4Ch9Zv8=.
#
# BRUNO_REMOTE_IMAGE_DOMAINS IS WHAT MAKES 4.0.0 BUILD AT ALL. 4.0.0 adds
# packages/bruno-app/plugins/remote-images/, wired into rsbuild.config.mjs,
# which downloads images from a CDN during the build — a hard failure in the
# network-free Nix sandbox (`TypeError: fetch failed` … `Rspack build
# failed!`). Upstream's own knob short-circuits it: rsbuild.config.mjs reads
# `process.env.BRUNO_REMOTE_IMAGE_DOMAINS`, and `findRemoteImageUrls` returns
# [] before any fetch once no URL host matches the configured set. The value
# must be non-empty and non-matching — an EMPTY string is falsy in
# `process.env.X || '<cdn host>'` and would restore the CDN default — so an
# RFC 2606 reserved `.invalid` host is used.
#
# Honest behavioral delta: the changelog markdown keeps its original CDN
# URLs instead of inlined assets, so the Changelog tab loads them at runtime
# or not at all offline. NOT runtime-verified.
#
# The `env` merge is a merge and not a replacement on purpose — bruno already
# carries `env.ELECTRON_SKIP_BINARY_DOWNLOAD = 1`.
#
# No platform gating: the source build supports darwin. A `--replace-fail`
# whose anchor moved is a HARD failure and this host cannot build darwin, so
# both darwin-only anchors in
# packages/bruno-electron/electron-builder-config.js were checked against the
# fetched v4.0.0 tree instead: the `identity:` line naming upstream's signing
# identity (line 38) and `afterSign: 'notarize.js',` (line 18). Both present,
# byte-for-byte as nixpkgs spells them. Re-check them on every version bump.
#
# Not agentic-tools-specific — it lives under overlays/generic/ so the
# earmarked repo split can lift the subtree whole.
#
# Free (MIT) BECAUSE WE BUILD FROM SOURCE. The unfree framing that attaches to
# bruno elsewhere is about the prebuilt .deb, which this deliberately does not
# use. ensureUnfreeCheck in default.nix passes free packages through
# unwrapped.
{
  inputs,
  final,
  ...
}: let
  # Cache-hit parity: every build input comes from THIS repo's nixpkgs pin,
  # never the consumer's `final`. `final.stdenv.hostPlatform.system` is the
  # only thing read from the consumer — see
  # dev/fragments/overlays/overlay-pattern.md.
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) lib;
  vu = import ../lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./bruno-sources.json);
  inherit (sources) version;

  # Bound once: passed to BOTH the hash fixer and the update script, and the
  # default (`overlays/<pname>-sources.json`) is wrong for a grouped subtree.
  sourcesFile = "overlays/generic/bruno-sources.json";

  fixNpmDepsHash = vu.mkNpmDepsFix {
    attr = "bruno";
    pkgs = ourPkgs;
    pname = "bruno";
    inherit sourcesFile;
  };
in
  ourPkgs.bruno.override (_: {
    buildNpmPackage = args:
      ourPkgs.buildNpmPackage (finalAttrs: let
        upstream = (lib.toFunction args) finalAttrs;
      in
        upstream
        // {
          inherit version;

          src = upstream.src.override {
            tag = "v${version}";
            hash = sources.srcHash or lib.fakeHash;
          };

          npmDepsHash = sources.npmDepsHash or lib.fakeHash;

          postPatch =
            builtins.replaceStrings
            [upstream.version]
            [version]
            upstream.postPatch;

          env =
            (upstream.env or {})
            // {
              BRUNO_REMOTE_IMAGE_DOMAINS = "invalid.invalid";
            };

          # Merge, never replace — and here it also keeps whatever nixpkgs
          # hangs off the base expression's passthru.
          passthru =
            (upstream.passthru or {})
            // {
              inherit fixNpmDepsHash;
              updateScript = vu.mkUpdateScript {
                extraExtract = "${fixNpmDepsHash}";
                pkgs = ourPkgs;
                platforms = {};
                pname = "bruno";
                inherit sourcesFile;
                versionCheck.cmd = vu.ghLatestVersionCmd {
                  pkgs = ourPkgs;
                  repo = "usebruno/bruno";
                };
              };
            };
        });
  })
