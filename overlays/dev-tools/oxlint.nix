# oxlint — HEAD-tracked JS/TS linter with type-aware (tsgo) support, pinned
# against `ourPkgs` for cache-hit parity. Thin override of nixpkgs' oxlint:
# inject our sibling tsgolint via .override (so --type-aware uses our HEAD
# backend, kept in lockstep), then overrideAttrs to swap src + the three
# hashes (src, cargoDeps, pnpmDeps). The pnpm/JS-plugin build, OXC_VERSION,
# the tsgolint PATH wrapper, and the --type-aware install check are inherited.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  vu = import ../lib.nix;
  tsgolint = import ./tsgolint.nix {inherit inputs final;};

  rev = "975181512c17bd2cc0438b80851d0c64e6bdc4de";
  unpatchedSrc = ourPkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "oxc";
    inherit rev;
    hash = "sha256-7O8pUPPS71t4S+yJ1qCZ90yvA798nZPTr+OvY71oqHw=";
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
  # in 3.8.6.
  #
  # The patch file itself is added as a NEW file, which never conflicts. The
  # workspace/lock metadata that points pnpm at it is applied by key in
  # postPatch instead of as hunks: those references track upstream's peer
  # resolution, which reshuffles on its own schedule, and a positional diff
  # turns every reshuffle into a held-back sweep needing hand-realigned hunks.
  # See oxlint-pnpm-patch-meta.awk for what stays loud.
  #
  # All three fields below move TOGETHER on an upstream repin, and the awk's
  # catalog assertion is what forces that. Regenerate with real pnpm — `pnpm
  # patch @napi-rs/cli@<ver>` then `patch-commit`, stripping the content-free
  # `deleted file mode` stanzas it emits — and prove the result with a
  # `pnpm install --frozen-lockfile` before landing it. The ifd-patterns
  # fragment carries the full loop.
  napi = {
    pkg = "@napi-rs/cli";
    version = "3.8.6";
    patchPath = "patches/@napi-rs__cli@3.8.6.patch";
    # pnpm derives this from the patch file's CONTENT — a plain sha256 of its
    # bytes — so it moves only when that file does, not when upstream's lock
    # does.
    patchHash = "d6d478f3b84607df7e4453132b48893a86b679e22a0df6151173305350e2c269";
  };
  src = ourPkgs.applyPatches {
    src = unpatchedSrc;
    patches = [./oxlint-napi-rs-cli.patch];
    postPatch = ''
      apply_patch_meta() {
        awk -v pkg="${napi.pkg}" -v ver="${napi.version}" \
            -v val="$1" -v q="$2" -v tag="$3" -v ph="${napi.patchHash}" \
            -f ${./oxlint-pnpm-patch-meta.awk} "$4" > "$4.tmp"
        mv "$4.tmp" "$4"
      }
      apply_patch_meta "${napi.patchPath}" '"' "" pnpm-workspace.yaml
      apply_patch_meta "${napi.patchHash}" "'" stamp pnpm-lock.yaml
    '';
  };
  version = vu.mkVersion {
    # upstream: readCargoVersion @ apps/oxlint/Cargo.toml
    upstream = "1.79.0";
    inherit rev;
  };
in
  (ourPkgs.oxlint.override {inherit tsgolint;}).overrideAttrs (finalAttrs: prev: {
    inherit version src;
    cargoDeps = ourPkgs.rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname version src;
      hash = "sha256-huMyPeKTY543122/AB5A0P1Xtd7I45fpWVsT1EPG6IM=";
    };
    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = ourPkgs.pnpm_11;
      fetcherVersion = 4;
      hash = "sha256-8Wp2hTsF2rXsi7LMTAo5AYiwhVJD1uka0JD0jr4Quos=";
    };
    # Oxc declares pnpm 11.17.0. Replace nixpkgs Oxlint's pnpm 10 build input
    # as well as its dependency fetcher so both phases use the upstream major.
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
    # overlays/git-tools/git-branchless.nix. The inherited installCheckPhase
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
