# cspell:ignore andrewbranch Funtar
# oxlint — HEAD-tracked JS/TS linter with type-aware (tsgo) support, pinned
# against `ourPkgs` for cache-hit parity. Thin override of nixpkgs' oxlint:
# inject our sibling tsgolint via .override (so --type-aware uses our HEAD
# backend, kept in lockstep), then overrideAttrs to swap src + the three
# hashes (src, cargoDeps, pnpmDeps). The pnpm/JS-plugin build, OXC_VERSION,
# the tsgolint PATH wrapper, and the --type-aware install check are inherited.
{
  inputs,
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  ourPkgs = pkgs;
  vu = packageLib;
  tsgolint = import ../../../../../tsgolint/packages/ai/devTools/tsgolint/package.nix {inherit inputs packageLib pkgs repoPath;};

  rev = "5b4787fb0d4d6d6f26fbbb1477e4643a67d7659f";
  unpatchedSrc = ourPkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "oxc";
    inherit rev;
    hash = "sha256-HhP7fDp6pXaadUwrGifoIDkIzqibOLyZJKRqhRM/QNc=";
  };
  # @napi-rs/cli's filesystem reconciliation probes a process incarnation with
  # execFile(/bin/ps) on Darwin. Node can reject that spawn synchronously under
  # Nix's Seatbelt profile, before the callback's existing error fallback runs.
  # Patch the dependency through pnpm's native patchedDependencies mechanism so
  # every peer variant gets the same fix and the dependency layer owns it; do
  # not admit a host executable into the build. The fetcher FOD still holds the
  # original registry bytes rather than prepatched content; pnpm applies this
  # patch while materializing its virtual store. A failed probe still resolves
  # to null, preserving napi-rs's fail-closed stale-lock behavior. Drop this
  # when the catch ships upstream — re-read `executeProcessIncarnationCommand`
  # in `dist/cli.js` on each repin rather than assuming; it was still uncaught
  # in 3.9.1.
  #
  # The patch file itself is added as a NEW file, which never conflicts. The
  # workspace/lock metadata that points pnpm at it is applied by key in
  # postPatch instead of as hunks: those references track upstream's peer
  # resolution, which reshuffles on its own schedule, and a positional diff
  # turns every reshuffle into a held-back sweep needing hand-realigned hunks.
  # See oxlint-oxlint-pnpm-patch-meta.awk for what stays loud.
  #
  # All three fields below move TOGETHER on an upstream repin, and the awk's
  # catalog assertion is what forces that. Regenerate with real pnpm — `pnpm
  # patch @napi-rs/cli@<ver>` then `patch-commit`, stripping the content-free
  # `deleted file mode` stanzas it emits — and prove the result with a
  # `pnpm install --frozen-lockfile` before landing it. The ifd-patterns
  # fragment carries the full loop.
  napi = rec {
    pkg = "@napi-rs/cli";
    version = "3.9.1";
    # DERIVED, never hand-written. As two independent literals a stale patch
    # could pair with a matching version key and build GREEN: `version =
    # "3.8.6"` alongside `patchPath = ".../@napi-rs__cli@3.9.0.patch"` produced
    # a tree reading `"@napi-rs/cli@3.8.6": patches/@napi-rs__cli@3.9.0.patch`.
    # The awk builds its assertion key from `version` alone, so it cannot catch
    # that — the two halves have to be unable to disagree instead.
    patchPath = "patches/@napi-rs__cli@${version}.patch";
    # pnpm derives this from the patch file's CONTENT — a plain sha256 of its
    # bytes — so it moves only when that file does, not when upstream's lock
    # does. It is the sha256 of the INNER pnpm patch the outer git patch
    # creates, NOT of that outer file.
    patchHash = "cd0ec720c5bdecf81d61c893359063f100271bd27eac5541d8338ec38b239668";
  };
  # The other half of the coupling. Deriving patchPath stops it disagreeing
  # with `version`; this stops BOTH disagreeing with the file on disk. A repin
  # that bumps `version` without regenerating the patch would otherwise stamp a
  # path pnpm never finds, and pnpm then applies nothing and says nothing.
  napiPatchFile = builtins.readFile ../../../../patches/oxlint-napi-rs-cli.patch;
  assertPatchTargetsPin =
    ourPkgs.lib.throwIf
    (!ourPkgs.lib.hasInfix "b/${napi.patchPath}" napiPatchFile)
    ''
      oxlint: packages/oxlint/patches/oxlint-napi-rs-cli.patch does not create ${napi.patchPath}.
      napi.version is "${napi.version}", so the regenerated pnpm patch must be committed as
      that path. Regenerate it (dev/fragments/overlays/ifd-patterns.md carries the loop)
      rather than editing the literal — a mismatch here ships an UNPATCHED dependency
      silently, because pnpm does not error on a patchedDependencies path it cannot find.
    '';
  src = assertPatchTargetsPin (ourPkgs.applyPatches {
    src = unpatchedSrc;
    patches = [../../../../patches/oxlint-napi-rs-cli.patch];
    postPatch = ''
      apply_patch_meta() {
        awk -v pkg="${napi.pkg}" -v ver="${napi.version}" \
            -v val="$1" -v q="$2" -v tag="$3" -v ph="${napi.patchHash}" \
            -f ${../../../../src/oxlint-pnpm-patch-meta.awk} "$4" > "$4.tmp"
        mv "$4.tmp" "$4"
      }
      apply_patch_meta "${napi.patchPath}" '"' "" pnpm-workspace.yaml
      apply_patch_meta "${napi.patchHash}" "'" stamp pnpm-lock.yaml
    '';
  });
  version = vu.mkVersion {
    # upstream: readCargoVersion @ apps/oxlint/Cargo.toml
    upstream = "1.82.0";
    inherit rev;
  };
in
  (ourPkgs.oxlint.override {inherit tsgolint;}).overrideAttrs (finalAttrs: prev: {
    inherit version src;
    cargoDeps = ourPkgs.rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname version src;
      hash = "sha256-03imr5xUbz9ZkHeQV+6LY0LWiUL1LaHQyLhQNvf5Cco=";
    };
    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = ourPkgs.pnpm_11;
      fetcherVersion = 4;
      hash = "sha256-bIbBs6+QYoJsRqCV2q7enpw5UIw1ugzRJff4OUOGQ+s=";
    };
    # Oxc declares pnpm@12.3.2 in `packageManager`, and we DELIBERATELY stay on
    # pnpm 11. nixpkgs' fetcher interpolates `--registry="$NIX_NPM_REGISTRY"`
    # unconditionally (fetch-pnpm-deps/default.nix:149) and that variable has no
    # default anywhere in nixpkgs, so the fetcher hands pnpm an EMPTY registry
    # base. pnpm 11 falls back to the default registry; pnpm 12's Rust rewrite
    # does not, and every request becomes a relative URL — measured, the install
    # dies with metadata fetches against bare paths like `/@andrewbranch%2Funtar.js`.
    # Disabling pnpm's supply-chain check does NOT work around it: the same
    # empty-base failure just resurfaces one stage later at the tarball endpoint.
    #
    # Revisit when the nixpkgs pin carries a registry-guard fix; the swap then
    # needs a `NIX_NPM_REGISTRY` default supplied here in the same change.
    # Replace nixpkgs Oxlint's own pnpm in BOTH places — the dependency fetcher
    # above and the build input here — so both phases use the same major.
    # checks/packaging/pnpm-fetcher-parity.nix asserts those two are the same store path,
    # so they can never drift apart silently.
    nativeBuildInputs =
      map
      (input:
        if (input.pname or "") == "pnpm"
        then ourPkgs.pnpm_11
        else input)
      (prev.nativeBuildInputs or []);
    # Strip versionCheckHook: `oxlint --version` prints the bare upstream
    # semver (e.g. 1.74.0) and drops the `+shortrev` build metadata that
    # `mkVersion` puts in the derivation version, so the hook never matches
    # and aborts installCheck. Same handling as
    # packages/git-branchless/packages/ai/gitTools/git-branchless/package.nix. The inherited installCheckPhase
    # (`--type-aware` via our tsgolint + the jsPlugins smoke) is independent
    # and still runs.
    nativeInstallCheckInputs =
      builtins.filter
      (p: (p.pname or "") != "version-check-hook")
      (prev.nativeInstallCheckInputs or []);
    # Base meta.changelog is `…/releases/tag/${src.tag}`, but our rev-based src
    # has no `tag`, so accessing meta.changelog coerces null → eval throw.
    # Re-point it at the pinned commit (also re-anchors meta.position here).
    meta = prev.meta // {changelog = "https://github.com/oxc-project/oxc/commit/${rev}";};
  })
