# kiro-crew — AWS's open-source agent orchestrator: a Python gateway plus a
# React dashboard SPA, tracked at `main` rather than at a release tag.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input (the
# interpreter, its package set, nodejs) routes through this repo's pinned
# nixpkgs instead of the consumer's. That is what gives the store path
# cache-hit parity against CI's standalone build — see
# dev/fragments/overlays/overlay-pattern.md.
#
# TWO DERIVATIONS, ONE SOURCE. The dashboard SPA is its own `buildNpmPackage`
# below, not a phase of this one: it is a distinct upstream artifact with its
# own toolchain, its own lockfile and its own fixed-output dependency fetch.
# Anything that patches `website/` belongs to THAT derivation; anything that
# patches `src/kiro_crew/**` belongs to this one. Keep the two patch sets
# apart — a single pooled `patches` list is what makes a package impossible to
# split later.
#
# Both read the SAME `src`, so this file carries exactly one `rev` and one
# source hash. That is not only tidiness: `dev/scripts/resolve-recipe-file.sh`
# (and `checks/packaging/update-targets-parity.nix`, which runs the same
# resolver) require EXACTLY ONE file under `packages/` that pins
# `kirodotdev/KiroCrew` and carries an inline 40-hex `rev`. Splitting the
# frontend into a sibling .nix file that re-declared owner/repo/rev would make
# the resolver ambiguous and hold the package back on every sweep.
{
  pkgs,
  packageLib,
  repoPath,
  # ── Optional overrides ──────────────────────────────────────────────────
  #
  # Null by default, and with both null this derivation is byte-identical to
  # one that never declared them (no wrapper is produced at all). Each is
  # filled by `packages.kiro-crew.override { … }`. They are arguments rather
  # than hardcoded paths precisely so that nothing else's source, build or
  # patches ever has to be lumped into this recipe.
  #
  # `embedModel`: a SEAM for a later, separate derivation — a GGUF embedding
  #   model (upstream bundles qwen3-embedding 0.6b and DOWNLOADS it at first
  #   use). Wired to upstream's own `KIROCREW_EMBED_MODEL_PATH`, which selects
  #   a local GGUF instead.
  #
  # `llamaCppLib`: an ESCAPE HATCH, not a seam — the in-process embedding
  #   runtime is the VENDORED one (kept, relinked and asserted below), and
  #   nothing has to be overridden for embeddings to work. Point this at a
  #   directory whose `lib/` holds `libllama` plus its `libggml*` dependencies
  #   only if you want a different build (a GPU one, say). It sets upstream's
  #   own `LLAMA_CPP_LIB_PATH`, documented in `_vendor/llama_cpp/llama_cpp.py`.
  #
  #   Two things setting it costs you, both measured in `embeddings.py`:
  #
  #   1. It BYPASSES every guard upstream puts in front of the bundled runtime.
  #      `_load_llama_class` skips the vendored-payload completeness check, the
  #      Windows MSVC-runtime check and the Linux x86_64 CPU-feature baseline
  #      (avx, avx2, bmi2, f16c, fma, sse3, ssse3) whenever `LLAMA_CPP_LIB_PATH`
  #      is set — deliberately, so an operator-provided runtime is validated by
  #      its own directory rather than by the bundled tree's contents. A library
  #      that needs an instruction the host lacks then terminates the gateway
  #      with SIGILL instead of degrading.
  #   2. The library must be ABI-compatible with the vendored llama-cpp-python
  #      0.3.34 binding, which is pure ctypes with NO version check.
  #
  #   nixpkgs' `llama-cpp` does NOT qualify, and this is settled — do not
  #   relitigate it by "just using the packaged library":
  #
  #   - It is 0.4.0. `llama_model_params` grew 72 → 80 bytes, with new fields
  #     inserted at offsets 24 and 28 that displace everything after them. The
  #     struct is passed BY VALUE through ctypes, so the mismatch is silent
  #     memory corruption rather than an error.
  #   - It defaults to `cpuArchDynamicDispatch`, which enables `GGML_BACKEND_DL`
  #     and puts every CPU backend in `bin/`, not `lib/`. Pointing
  #     `LLAMA_CPP_LIB_PATH` at its `lib/` registers zero backends, and the
  #     static fallback is compiled out.
  #
  # Not yet seamed, because their runtime contract is a URL rather than a
  # path and inventing one here would be a guess: the PPTX Maker engine
  # (`KIROCREW_PPTX_ENGINE_URL` / `KIROCREW_PPTX_SKIP_ENGINE_DOWNLOAD`, a
  # separate MIT-0 upstream) and the whisper.cpp models
  # (`KIROCREW_WHISPER_MODEL_BASE_URL`). Add them the same way — as arguments
  # with null defaults — when those derivations exist.
  embedModel ? null,
  llamaCppLib ? null,
  # ── Dormant patches ─────────────────────────────────────────────────────
  #
  # Both default OFF, and both are CARRIED rather than deleted. They exist
  # because the situation each answers is one you cannot write a patch for
  # under time pressure — the moment you need them, upstream has already moved
  # and the sites have to be re-found. `checks/patches-apply.nix` applies them
  # on every CI run for exactly that reason: a dormant patch that nothing
  # builds is retired by the first rebase that touches its context, silently.
  #
  # `delegateSandboxToKiroCli`: extends crew's delegation of sandboxing to
  #   kiro-cli onto Linux. The primary arrangement needs no patch at all —
  #   PATH plus `KIRO_KAS_NODE_PATH`, with crew's own namespace sandbox left
  #   on. This is the fallback for a future kiro-cli that reintroduces a bwrap
  #   or FHS step and breaks that arrangement quietly. It touches TWO sites
  #   that must move together; the second is the agents-tree seal, and a
  #   half-applied version opens the hole upstream documents.
  #
  # `disableSelfUpdate`: neutralizes the spawn that would update KiroCrew in
  #   place. On a Nix install that update cannot succeed — the store is
  #   read-only — so the honest states are "it fails loudly" (today) or "it
  #   never tries" (this patch). It is a BEHAVIOR change and is off pending
  #   the operator's decision, not because the patch is unfinished. The
  #   `nix` distribution stamp in the applied set already routes remediation
  #   to "update through your Nix configuration", which is the notify-only
  #   half of the same problem and is safe on its own.
  delegateSandboxToKiroCli ? false,
  disableSelfUpdate ? false,
  ...
}: let
  ourPkgs = pkgs;
  inherit (ourPkgs) autoPatchelfHook buildNpmPackage fetchFromGitHub lib makeWrapper nodejs_24 patchelf python313 python313Packages stdenv writeText;
  vu = packageLib;

  rev = "40624a1fb7df98393a2de57eb6ae1fb017b536fe";
  src = fetchFromGitHub {
    owner = "kirodotdev";
    repo = "KiroCrew";
    inherit rev;
    # A QUOTED SRI LITERAL, never `lib.fakeHash` and never an interpolation.
    # `dev/scripts/update-pkg.sh` Phase 0 locates the value to rewrite with
    # `grep -oP 'hash = "\Ksha256-[^"]+'`; anything that grep cannot see skips
    # the prefetch AND therefore the `# upstream:` version rewrite below,
    # shipping a package that claims one version and builds another.
    hash = "sha256-BbsILZY71th0gekg5J5gk5pTYMR2X5Buj7O1KqnFfSY=";
  };

  # No eval-time `vu.readPyprojectVersion "${src}/pyproject.toml"`: that is
  # IFD, which fails on a cold runner. The marker below is the repo's
  # IFD-free convention — `update-pkg.sh` re-derives the literal from the
  # freshly prefetched tree on every rev bump. See
  # dev/fragments/overlays/ifd-patterns.md.
  # upstream: readPyprojectVersion @ pyproject.toml
  upstreamVersion = "0.8.0";
  version = vu.mkVersion {
    upstream = upstreamVersion;
    inherit rev;
  };

  sources = builtins.fromJSON (builtins.readFile ../../../sources.json);
  sourcesFile = repoPath ../../../sources.json;

  # ── THE PATCH MANIFEST ──────────────────────────────────────────────────
  #
  # Three lists, and the split is the file's whole point: the two derivations
  # below unpack at DIFFERENT roots, so a patch is not merely "for kiro-crew"
  # — it is for one derivation or the other and will not apply to the wrong
  # one. `python` lands at the repo root; `frontend` lands inside `website/`,
  # because that derivation's `sourceRoot` puts patchPhase one level down.
  #
  # A single pooled `patches` list is what makes a package impossible to split
  # later, which is why this is a manifest rather than two inline lists: the
  # membership is stated once, `checks/patches-apply.nix` reads it through
  # `passthru`, and that check asserts the manifest and the directory listing
  # are the same set in both directions. An orphaned patch file and a missing
  # one both fail at EVAL, naming the file.
  #
  # Eight of these eleven are upstreamable on their own merits and are worth
  # sending: upstreaming converts a recurring rebase cost into a one-time one,
  # and against a tree moving ~100 commits a day that is the only lever that
  # actually reduces the maintenance.
  patchManifest = {
    python = [
      # Correctness on a host whose /bin holds only sh.
      ../../../patches/kiro-crew-env-bash.patch
      # The trusted-binary allowlist cannot see a Nix store path.
      ../../../patches/kiro-crew-trusted-bin-nix-store.patch
      # The group-writable floor false-positives on /nix/store (mode 1775).
      ../../../patches/kiro-crew-sticky-dir-writable.patch
      # copytree out of a read-only source yields an unwritable destination.
      ../../../patches/kiro-crew-copytree-readonly-modes.patch
      # The same defect in the PPTX Maker engine, plus the seam that lets an
      # externally provisioned engine skip `uv sync`.
      ../../../patches/kiro-crew-pptx-engine-provisioned.patch
      # Teach the distribution stamp about `nix`, routed to notify-only.
      ../../../patches/kiro-crew-distribution-nix.patch
      # GPU offload is unreachable at any setting without this argument.
      ../../../patches/kiro-crew-n-gpu-layers.patch
    ];
    frontend = [];
    dormant = [
      ../../../patches/kiro-crew-linux-sandbox-delegation.patch
      ../../../patches/kiro-crew-no-self-update.patch
    ];
  };

  pythonPatches =
    patchManifest.python
    ++ lib.optional delegateSandboxToKiroCli
    ../../../patches/kiro-crew-linux-sandbox-delegation.patch
    ++ lib.optional disableSelfUpdate
    ../../../patches/kiro-crew-no-self-update.patch;

  # THE DASHBOARD ASSERTION. Nothing upstream fails when the dashboard is
  # missing: `setup.py`'s `BuildWithFrontend` prints a WARNING and continues,
  # and the gateway then serves an unauthenticated "Dashboard HTML not found"
  # page with HTTP 200. A silently shippable wrong build is exactly what a
  # derivation is supposed to refuse, so assert it twice — over the STAGED
  # tree (did the frontend derivation produce anything?) and over the
  # INSTALLED tree (did setup.py actually carry it into the wheel?).
  #
  # The test is a content test, not a size floor. Vite emits content-hashed
  # `/assets/index-<hash>.js` references into index.html, while the SOURCE
  # `website/index.html` references `/src/main.tsx` — so this distinguishes a
  # real build from a template copied verbatim, which a byte count would not.
  assertDashboard = dir: ''
    if [ ! -f "${dir}/index.html" ]; then
      echo "kiro-crew: dashboard missing at ${dir}/index.html" >&2
      exit 1
    fi
    if ! grep -q '/assets/' "${dir}/index.html"; then
      echo "kiro-crew: ${dir}/index.html carries no built asset reference" >&2
      echo "           (a Vite build emits /assets/<name>-<hash>.js; the" >&2
      echo "            source template references /src/main.tsx instead)" >&2
      exit 1
    fi
  '';

  # ── The vendored llama.cpp runtime ──────────────────────────────────────
  #
  # KEPT, not deleted. This tree is what makes in-process embeddings work, and
  # every failure on that path is SILENT: `embeddings._load_llama_class()`
  # returns None behind one WARNING and memory degrades to keyword search with
  # the gateway still exiting 0. Deleting the tree (an earlier shape of this
  # recipe did) while `llamaCppLib` defaults to null is exactly that failure,
  # shipped by default.
  #
  # Swapping the tree for nixpkgs' `llama-cpp` is settled and rejected — the
  # ABI and backend-layout measurements are on the `llamaCppLib` argument.
  vendoredLibsRoot = "src/kiro_crew/_vendor/llama_cpp_libs";

  buildSystem = stdenv.hostPlatform.system;

  # Which one of upstream's five per-platform directories survives the prune.
  # `embeddings._platform_libs_dirname()` derives the same name at runtime
  # from `sys.platform` + `platform.machine()`; a disagreement here leaves the
  # installed tree holding libs the loader never looks at. A system with no
  # row throws at eval rather than silently keeping the wrong directory.
  vendoredLibsDir =
    {
      aarch64-darwin = "macos_arm64";
      aarch64-linux = "linux_aarch64";
      x86_64-darwin = "macos_x86_64";
      x86_64-linux = "linux_x86_64";
    }
    .${
      buildSystem
    }
    or (throw "kiro-crew: no vendored llama.cpp libs for ${buildSystem}");

  # THE ORDER IS THE WHOLE TRICK, so this runs in postPatch: patchPhase, on
  # the unpacked source tree, before anything has been built or installed.
  # `autoPatchelfHook` registers itself as
  # `postFixupHooks+=(autoPatchelfPostFixup)` (its setup-hook, line 104), so
  # it runs inside fixupPhase — far later. Three constraints, and only this
  # placement satisfies all three:
  #
  #   - relink before delete, or the libs keep a NEEDED on a file that is gone;
  #   - delete before autoPatchelf, or it resolves the hashed name against the
  #     copy sitting in the output and bakes an RPATH to a file we then remove;
  #   - do both in the source tree, so setuptools carries ONE already-correct
  #     copy into the wheel instead of this logic having to find the installed
  #     one under a `sitePackages` path.
  #
  # `postFixup` is NOT the later half of that, despite reading like it.
  # `runHook postFixup` evaluates the postFixup VARIABLE first and the
  # postFixupHooks ARRAY second, so a postFixup body runs BEFORE autoPatchelf
  # — the trap `packages/pnpm/packages/ai/generic/pnpm_12/package.nix` and
  # `packages/kiro-cli/lib/packaging.nix` both record from the other side,
  # where they needed to run a binary AFTER patching.
  #
  # DARWIN DOES THE PRUNE AND NOTHING ELSE, deliberately. The `macos_arm64`
  # dylibs are signed Mach-Os that already resolve each other through
  # `@rpath` + `@loader_path` within their own directory, so there is nothing
  # to relink and no GPL blob to remove (libgomp is a Linux-payload problem;
  # macOS links Accelerate through `libggml-blas` instead). Every tool that
  # would "fix" them — `install_name_tool`, `strip` — REWRITES the Mach-O and
  # invalidates its signature, and arm64 macOS SIGKILLs an invalidly-signed
  # image at load. So: touch nothing, and set `dontStrip` below so fixupPhase
  # does not touch them either.
  #
  # NAMED UNKNOWN: upstream ships `packaging/resign-macos-libs.sh`, which
  # means at least one of their distribution lanes re-signs these dylibs. It
  # is not established whether a Nix build needs the same step, and guessing
  # in either direction is worse than leaving it open — an unnecessary
  # re-sign is itself a Mach-O rewrite. The embeddings assertion below is
  # what settles it in practice: it dlopens the dylibs on the build machine,
  # so a signature that macOS refuses fails the darwin build loudly instead
  # of degrading to keyword search in the field.
  prepareVendoredLibs =
    ''
      vendoredLibs="${vendoredLibsRoot}/${vendoredLibsDir}"
      if [ ! -d "$vendoredLibs" ]; then
        echo "kiro-crew: upstream ships no ${vendoredLibsDir} native libs" >&2
        echo "           (expected at $vendoredLibs)" >&2
        exit 1
      fi

      # Prune the four foreign platforms: ~26MB of prebuilt binaries this
      # system can never load, and four platforms' worth of licence surface.
      # Upstream's runtime guard reads only the RUNNING platform's entry
      # (`_REQUIRED_VENDORED_LIBS.get(libs_dirname, ())`), so the prune is
      # invisible to it. Its cross-platform helper `verify_vendored_libs()`
      # would report every pruned directory as missing — that is why the
      # install-time assertion below cannot reuse it, and checks one platform.
      find "${vendoredLibsRoot}" -mindepth 1 -maxdepth 1 -type d \
        ! -name "${vendoredLibsDir}" -exec rm -rf {} +
    ''
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      # THE GPL BLOB. Both Linux payloads carry a hashed-name libgomp that
      # auditwheel copied in (`libgomp-a34b3233.so.1.0.0` on x86_64). It is
      # GPL-3.0-or-later WITH GCC-exception-3.1 and ships with no licence text
      # anywhere in the artifact, while `_vendor/README.md` calls the whole
      # tree MIT. It is also a hard DT_NEEDED of `libggml-base.so.0` and
      # `libggml-cpu.so.0`, so it cannot simply be removed: relink first,
      # delete second. Getting that order wrong fails the build (autoPatchelf
      # matches by exact basename and would find no `libgomp-<hash>.so.1.0.0`)
      # or ships the blob.
      #
      # Measured on the real artifact, because a half-rewrite would load and
      # then fail on version lookup: patchelf 0.15.2's `--replace-needed`
      # rewrites the `.gnu.version_r` File entry as well as DT_NEEDED, so the
      # GOMP_1.0/4.0/4.5 requirements the vendored libs carry end up
      # attributed to `libgomp.so.1` — the name glibc matches them against.
      # The libgomp `stdenv.cc.cc.lib` resolves to on this pin (gcc 15.3.0)
      # defines GOMP_1.0 through GOMP_6.0, a strict superset, and that set
      # only ever grows.
      mapfile -t gompLibs < <(
        find "$vendoredLibs" -maxdepth 1 -type f -name 'libgomp-*.so.*' -printf '%f\n'
      )
      if [ "''${#gompLibs[@]}" -ne 1 ]; then
        echo "kiro-crew: expected exactly one vendored libgomp under $vendoredLibs," >&2
        echo "           found ''${#gompLibs[@]}: ''${gompLibs[*]-}" >&2
        exit 1
      fi
      gompLib="''${gompLibs[0]}"

      relinkedGomp=0
      while IFS= read -r vendoredLib; do
        # Here-string, not `patchelf --print-needed … | grep -Fxq`. stdenv arms
        # `set -o pipefail` for every phase and `grep -q` exits at its first
        # match, leaving patchelf's remaining writes to EPIPE and poisoning the
        # pipeline status — the same trap `vu.mkMcpSmokeTest` documents.
        vendoredNeeded=$(patchelf --print-needed "$vendoredLib")
        if grep -Fxq "$gompLib" <<<"$vendoredNeeded"; then
          patchelf --replace-needed "$gompLib" libgomp.so.1 "$vendoredLib"
          relinkedGomp=$((relinkedGomp + 1))
        fi
      done < <(find "$vendoredLibs" -maxdepth 1 -type f -name '*.so*')

      if [ "$relinkedGomp" -eq 0 ]; then
        echo "kiro-crew: nothing NEEDs $gompLib — the vendored payload changed" >&2
        echo "           shape upstream; re-derive this relink before trusting it" >&2
        exit 1
      fi
      echo "kiro-crew: relinked $relinkedGomp vendored libs onto libgomp.so.1"

      # Upstream's completeness guard names the hashed file BY NAME, and a
      # miss there returns None from `_load_llama_class()` behind one WARNING
      # — precisely the silent fallback this change exists to remove. So the
      # declaration has to lose the entry the relink made obsolete.
      # `--replace-fail`, not `--replace`: if upstream reformats that tuple
      # this must fail the build rather than skip. The other Linux
      # architecture's entry is left alone on purpose — its directory is
      # pruned, and the guard only ever reads the running platform's row.
      substituteInPlace src/kiro_crew/embeddings.py \
        --replace-fail "\"$gompLib\"," ""

      rm "$vendoredLibs/$gompLib"
    '';

  # THE EMBEDDINGS ASSERTION, and the reason it is a phase rather than prose.
  #
  # Upstream returns None from every embeddings failure path, so an import
  # that merely does not raise proves nothing: `import kiro_crew.embeddings`
  # succeeds just as well on a build whose native libs were deleted. This
  # calls the loader itself. `_load_llama_class()` is the single function
  # whose None return IS the silent fallback, and reaching a non-None result
  # means the platform directory was found, the completeness guard passed, the
  # CPU-feature baseline passed, and `from llama_cpp import Llama` executed —
  # which dlopens `libllama` at module scope (`llama_cpp.py` line 43) and
  # resolves symbols against it immediately (line 143). That is the assertion
  # "the native library actually loaded".
  #
  # It uses private names deliberately. They can rot — we track `main` — and
  # when they do this raises AttributeError and fails the build, which is the
  # correct direction for a check whose whole purpose is refusing silence.
  #
  # One honest limitation: on Linux x86_64 the CPU-feature baseline is read
  # from the BUILD machine's /proc/cpuinfo, so this proves the runtime loads
  # where it was built, not on every host that installs it. Upstream degrades
  # gracefully in that case; a builder that cannot run the bundled libs fails
  # here instead, which is the loud end of the same trade.
  embeddingsCheckScript = writeText "kiro-crew-embeddings-check.py" ''
    import logging
    import sys

    # Upstream reports each failure as one WARNING and returns None, so put
    # those records on stderr before anything can swallow them: they name the
    # exact cause (missing file, absent CPU feature, import traceback).
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)

    from kiro_crew import embeddings  # noqa: E402

    platform_dir = embeddings._platform_libs_dirname()
    if platform_dir is None:
        raise SystemExit(
            "kiro-crew: embeddings claims no vendored lib directory for this "
            "platform, so the build kept the wrong one"
        )

    if embeddings._load_llama_class() is None:
        raise SystemExit(
            "kiro-crew: the vendored llama.cpp runtime did not load for "
            + platform_dir
            + " -- see the WARNING above. Shipped, this failure is SILENT: "
            "memory falls back to keyword search and the gateway exits 0."
        )

    print("kiro-crew: vendored llama.cpp runtime loaded from " + platform_dir)
  '';

  # The dashboard SPA. Its own derivation, its own toolchain, its own
  # fixed-output dependency fetch.
  frontend = buildNpmPackage {
    pname = "kiro-crew-dashboard";
    inherit src version;
    # `website/` has no workspaces and no `prepare` script, so the ordinary
    # `sourceRoot` shape is enough — `fetchNpmDeps` is handed the same
    # `sourceRoot` and finds `website/package-lock.json` (lockfileVersion 3).
    sourceRoot = "${src.name}/website";

    # Upstream's own toolchain pin: `.nvmrc` says 24 and
    # `website/package.json` declares `engines.node ">=22"`. nixpkgs' default
    # `nodejs` moves with the channel, so name the major explicitly.
    nodejs = nodejs_24;

    # ONE HASH FOR BOTH SYSTEMS. `fetchNpmDeps` hashes the resolved tarball
    # set, which the lockfile pins identically for x86_64-linux and
    # aarch64-darwin.
    #
    # No `or lib.fakeHash` fallback, deliberately — bruno needs one only
    # because `mkUpdateScript`'s `buildCandidate` rebuilds its sidecar FROM
    # SCRATCH and destroys every key it does not write. Nothing rebuilds this
    # sidecar, so a missing key is a real defect and should be an eval error
    # naming the file, not a silent fake-hash build.
    inherit (sources) npmDepsHash;

    # `npm run build` is `tsc -p tsconfig.app.json && node
    # --max-old-space-size=6144 vite build`. Upstream already sets its own
    # heap ceiling, so no NODE_OPTIONS here.
    npmBuildScript = "build";

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R dist/. "$out"
      runHook postInstall
    '';

    meta = {
      description = "Built dashboard SPA for Kiro Crew";
      homepage = "https://github.com/kirodotdev/KiroCrew";
      # asl20 is upstream's own; ofl covers the OpenDyslexic woff2 faces Vite
      # copies out of `website/public/fonts/` into the dist; mit is the
      # dominant licence of the npm dependency tree Vite bundles into
      # `assets/`. That tree is an aggregate this list cannot enumerate
      # honestly — it is a `nix build` away, not an eval away — so `mit`
      # stands for it rather than claiming completeness.
      license = with lib.licenses; [asl20 mit ofl];
    };
  };

  # THE HASH FIXER, and why it is `mkHashFix` rather than `mkNpmDepsFix`.
  #
  # `vu.mkNpmDepsFix` (bruno's shape) replays TWO targets — `hashFixTargets.src`
  # writing a `srcHash` key, then `hashFixTargets.npmDeps`. Both of its
  # assumptions are false here:
  #
  #   1. Our src hash is INLINE, not in the sidecar. `update-pkg.sh` Phase 0
  #      rewrites `rev` and `hash` in this file from `nix flake prefetch`. A
  #      `srcHash` key in sources.json would be read by nothing, and on a
  #      genuine src mismatch the fixer would quietly write a
  #      plausible-looking DEAD key — the exact class of silent wrongness
  #      `fodHashFixFn`'s `drvPattern` guard exists to prevent.
  #   2. `hashFixTargets.npmDeps.attrPath` is the bare `npmDeps`, which lives
  #      on a `buildNpmPackage`. This package's top level is a
  #      `buildPythonApplication`; the npm FOD hangs off `passthru.frontend`.
  #
  # So: `vu.mkHashFix` directly, one target, `hashFixTargets.npmDeps`
  # re-pointed at the nested attribute. `hashFixTargets` is exported from
  # `lib/packaging.nix`'s `rec` set precisely so the load-bearing
  # `-npm-deps` derivation-name pattern and the `npmDepsHash` key are reused
  # rather than restated. The frontend's FOD is named
  # `kiro-crew-dashboard-<version>-npm-deps`, which matches.
  #
  # Exposed as `passthru.fixNpmDepsHash` because that is the attribute
  # `fix_sidecar_hashes` (dev/scripts/update-common.sh) DISCOVERS across
  # `packages.<system>` and runs when an input bump's build verification
  # fails. That is what makes the npm hash self-repair on a nixpkgs bump.
  #
  # KNOWN GAP, stated rather than hidden: the REV-bump path does not run it.
  # `update-pkg.sh` has no `extraExtract` hook (that belongs to
  # `mkUpdateScript`, which a rev-pinned package does not use), and
  # `nix-update --version skip` only rewrites hashes it finds on the attribute
  # it was pointed at — it does not descend into `passthru.frontend`. A rev
  # bump that moves `website/package-lock.json` therefore opens a RED PR whose
  # fix is one command: run this fixer and commit the sidecar. That is the
  # same shape as the pnpm/cargo shortfall already recorded as issue #1570.
  fixNpmDepsHash = vu.mkHashFix {
    attr = "kiro-crew";
    name = "npm-deps";
    pkgs = ourPkgs;
    pname = "kiro-crew";
    inherit sourcesFile;
    targets = [(vu.hashFixTargets.npmDeps // {attrPath = "passthru.frontend.npmDeps";})];
  };

  wrapperArgs =
    lib.optionals (embedModel != null) [
      "--set-default"
      "KIROCREW_EMBED_MODEL_PATH"
      # The FILE, not the directory. `validate_custom_model_path` tests
      # `is_file()` plus a size floor, so a directory is rejected. The
      # filename comes from the model recipe's `passthru` so it is not
      # spelled a second time here.
      "${embedModel}/${embedModel.modelFile}"
    ]
    ++ lib.optionals (llamaCppLib != null) ["--set-default" "LLAMA_CPP_LIB_PATH" "${llamaCppLib}/lib"];
in
  python313Packages.buildPythonApplication {
    pname = "kiro-crew";
    inherit src version;
    pyproject = true;

    build-system = with python313Packages; [setuptools wheel];

    # Upstream's runtime `install_requires` (setup.cfg), minus the four
    # Windows-only entries (`pywinpty`, `tzdata`, `tzlocal`) and
    # `pysqlite3-binary`, which is removed below. `truststore` carries a
    # `sys_platform == "darwin"` marker and `pythonRuntimeDepsCheckHook`
    # EVALUATES markers, so it must be present on darwin and must not be
    # pulled in on linux.
    dependencies = with python313Packages;
      [
        aiohttp
        cron-descriptor
        croniter
        cryptography
        defusedxml
        jinja2
        jsonschema
        numpy
        openpyxl
        opentelemetry-api
        opentelemetry-sdk
        pathspec
        pdfplumber
        # `qrcode[pil]` — the extra is not checked by the runtime-deps hook,
        # but the WeChat QR path renders a PNG server-side and genuinely
        # needs it, so name Pillow rather than depend on pdfplumber dragging
        # it in transitively.
        pillow
        python-docx
        pyyaml
        qrcode
        requests
        slack-sdk
        snowballstemmer
        typing-extensions
        # The PyPI `uv` wheel, located at runtime via `uv.find_uv_bin()` by
        # PPTX Maker's venv provisioning — not a build backend.
        uv
        websockets
        yarl
      ]
      ++ lib.optionals stdenv.hostPlatform.isDarwin [truststore];

    nativeBuildInputs =
      lib.optionals (wrapperArgs != []) [makeWrapper]
      # `patchelf` for the relink in `prepareVendoredLibs`; `autoPatchelfHook`
      # for everything after it. Without the hook the vendored manylinux
      # objects do not load at all under a Nix-built interpreter: a dlopen'd
      # object's dependencies do NOT inherit the interpreter's DT_RUNPATH and
      # nixpkgs' ld.so consults no system cache, so `libstdc++.so.6` goes
      # unresolved. That OSError is caught by upstream's `except Exception`,
      # logged once, and the gateway still exits 0.
      ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook patchelf];

    # What the vendored libs NEED beyond glibc, read off the artifact with
    # `patchelf --print-needed`: libstdc++.so.6, libgcc_s.so.1 and (after the
    # relink) libgomp.so.1 — all three in this one output.
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];

    # Prebuilt binaries this derivation did not link are not ours to strip. On
    # darwin that is load-bearing rather than tidy: stripping REWRITES a
    # Mach-O and invalidates its code signature, and arm64 macOS SIGKILLs an
    # invalidly-signed image at load. See
    # `packages/pnpm/packages/ai/generic/pnpm_12/package.nix`, which sets this
    # for the same reason.
    dontStrip = true;

    # ABSENT FROM NIXPKGS ENTIRELY, at any version. Every import site falls
    # back to stdlib `sqlite3` (upstream declares it only for old Linux
    # x86_64, whose system SQLite predates FTS5/UPSERT). The cost is real and
    # narrow: no FTS5 on an interpreter whose bundled SQLite lacks it, which
    # degrades the knowledge library's lexical half to plain matching. nixpkgs'
    # python313 links a modern SQLite, so in practice this is a no-op.
    pythonRemoveDeps = ["pysqlite3-binary"];

    # Four declared ceilings that sit BELOW what nixpkgs ships, measured
    # against this repo's pin: websockets <16 vs 16.1, cron-descriptor <2 vs
    # 2.1.0, croniter <3 vs 6.2.4, cryptography <48 vs 50.0.0. An open nixpkgs
    # PR converged on the same four independently. Nothing else in
    # `install_requires` is out of range — `defusedxml` looks like a fifth
    # (0.8.0rc2 against `>=0.7,<1`) and is not: the runtime-deps hook sets
    # `requirement.specifier.prereleases = True` before comparing.
    pythonRelaxDeps = [
      "cron-descriptor"
      "croniter"
      "cryptography"
      "websockets"
    ];

    # PATCHES ROOTED AT THE REPO ROOT. See `patchManifest` above for what each
    # one does and why the frontend's own patch is not in this list.
    #
    # `patches`, not `applyPatches`: a `patches` list costs ZERO extra store
    # paths because patchPhase runs in-sandbox on the already-unpacked tree,
    # while `applyPatches` materializes a full second copy of a 289 MB source
    # AND sets `allowSubstitutes = false` on it, so every consumer rebuilds it
    # locally. `applyPatches` earns that only when the patched tree is needed
    # as a VALUE — to assert something about it at eval time, as oxlint does.
    # Nothing here needs that.
    patches = pythonPatches;

    # Vendored-libs surgery in patchPhase, dashboard staging in buildPhase —
    # two phases because they are two different clocks. This one is a source
    # rewrite that must land before autoPatchelfHook ever sees the files; the
    # other depends on the `frontend` derivation and on setup.py's staging
    # behavior. See `prepareVendoredLibs` for the ordering argument.
    postPatch =
      prepareVendoredLibs
      + ''
        # STAMP THE DISTRIBUTION, or the `nix` patch above is inert.
        #
        # `kiro-crew-distribution-nix.patch` teaches `update_capability` that a
        # `nix` install is externally managed — notify-only, `can_apply` false,
        # remediation "update through your Nix configuration". But that branch
        # is only reached when `beacon.distribution()` answers "nix", and
        # `beacon` resolves BAKED MODULE first, then `KIROCREW_DISTRIBUTION`,
        # then the "source" default. An unstamped build reports "source" — the
        # git-checkout answer — and is offered an in-place git or wheel update
        # that cannot succeed against a read-only store. The patch would apply,
        # the build would pass, and nothing would change.
        #
        # Upstream's OWN writer, not a heredoc of our own. `_build_info.py`'s
        # shape is upstream's to change, six of their packaging paths already
        # share this script for exactly that reason, and the patch above widens
        # its allowlist rather than bypassing it — so a future field lands here
        # automatically instead of drifting.
        #
        # A baked module rather than a wrapper `--set-default`, which is also
        # upstream's reasoning: `KIROCREW_DISTRIBUTION` is inherited by every
        # child and settable by anyone with a shell, so an export in a profile
        # would relabel the install. The module ships inside the artifact.
        bash scripts/stamp-distribution.sh nix src/kiro_crew

        # Positive control. The stamper prints its own success line, but a
        # rename upstream would make `bash` fail on a missing file and the
        # message would scroll past in a long log. Assert the artifact.
        if ! grep -q 'DISTRIBUTION = "nix"' src/kiro_crew/_build_info.py; then
          echo "kiro-crew: the distribution stamp did not land as nix" >&2
          exit 1
        fi
      '';

    preBuild =
      ''
        # `src/kiro_crew/static/dist` is GITIGNORED and absent from the source
        # tree, so it has to be created before anything can be staged into it.
        #
        # `cp -R --no-preserve=mode`, never a symlink and never a plain copy.
        # `setup.py`'s `BuildWithFrontend` re-stages this tree with
        # `shutil.copytree`, which PRESERVES MODE; a `buildNpmPackage` output
        # is 0555, so a mode-preserving copy lands a read-only directory in
        # `build_lib` that the next phase cannot write into. A symlink to a
        # store path is worse: `copytree` would either follow it into the
        # store or copy a dangling link into the wheel.
        mkdir -p src/kiro_crew/static/dist
        cp -R --no-preserve=mode ${frontend}/. src/kiro_crew/static/dist
      ''
      + assertDashboard "src/kiro_crew/static/dist";

    # doCheck = false, not disabledTests — and the choice is the repo's
    # convention, not a preference: `disabledTests` appears in zero recipes
    # here while `doCheck = false` is the established shape.
    #
    # It is also the honest one. `test/test_platform_compat.py` asserts
    # `trusted_system_bin("ps") is not None`, which cannot hold in a build
    # sandbox that has no `/bin/ps`. But that is one failure in a suite that
    # also wants pytest-xdist, pytest-split, jscpd and a `[tool:pytest]`
    # addopts line demanding coverage — enumerating the sandbox-hostile subset
    # would be a list that silently rots on every upstream commit, since we
    # track `main`. `pythonImportsCheck` plus the installed-dashboard
    # assertion below are the gates that actually hold.
    doCheck = false;

    # Live under `doCheck = false`: `pythonImportsCheckHook` appends its phase
    # to `preDistPhases`, which stdenv runs unconditionally. Measured on this
    # derivation, not assumed.
    pythonImportsCheck = ["kiro_crew"];

    # THE ONLY TWO PLACES A RUNTIME ASSERTION CAN LIVE HERE, and this one
    # needs the later of them.
    #
    # `installCheckPhase` is out, and measurably so rather than as a style
    # call: `mk-python-derivation.nix` line 400 hardcodes
    # `doInstallCheck = attrs.doCheck or true`, so under `doCheck = false` an
    # explicit `doInstallCheck = true` is DISCARDED — the phase text sits in
    # the .drv, unreachable, and the assertion reads as present while never
    # running. `postInstall` is out for a different reason: it runs before
    # fixupPhase, so on Linux the vendored libs still carry their manylinux
    # RUNPATHs and cannot be loaded yet.
    #
    # `preDistPhases` is the one that works. stdenv runs it unconditionally,
    # AFTER fixupPhase — so autoPatchelfHook (which registers into
    # `postFixupHooks`) has already patched the libs. It is the same mechanism
    # `pythonImportsCheckHook` uses (`appendToVar preDistPhases
    # pythonImportsCheckPhase`), so both phases run: this one first, then the
    # plain import check appended by the hook.
    preDistPhases = ["kiroCrewEmbeddingsCheckPhase"];
    kiroCrewEmbeddingsCheckPhase = ''
      echo "Executing kiroCrewEmbeddingsCheckPhase"
      (
        # Subshell to scope the cd and the export — phases share one shell.
        cd "$out"
        export PYTHONPATH="$out/${python313.sitePackages}:''${PYTHONPATH-}"
        ${python313.interpreter} ${embeddingsCheckScript}
      )
    '';

    # postInstall for the file-content assertions, which need no patched
    # binary and are cheapest where the tree is freshest.
    postInstall =
      assertDashboard "$out/${python313.sitePackages}/kiro_crew/static/dist"
      + ''
        # llama.cpp's MIT notice, which binary redistribution requires and
        # which this artifact otherwise ships without — grepping the whole
        # upstream tree for "ggml authors" or "Gerganov" returns nothing.
        # `_vendor/llama_cpp/LICENSE.md` is NOT that notice: it is
        # llama-cpp-python's own (Copyright (c) 2023 Andrei Betlen), and it
        # already reaches site-packages through upstream's `package_data`.
        # This copy is llama.cpp at e3546c7948e3af463d0b401e6421d5a4c2faf565,
        # the submodule llama-cpp-python 0.3.34 built these libs from.
        #
        # Upstream's own Apache-2.0 LICENSE travels with it, for the same
        # reason: it is not in `package_data`, so nothing in the installed
        # tree carried it either. The bundled OpenDyslexic fonts need no line
        # here — Vite copies `website/public/fonts/opendyslexic/OFL.txt` into
        # the dashboard dist, so that notice ships beside its fonts already.
        install -Dm644 ${../../../licenses/llama.cpp-LICENSE} \
          "$out/share/doc/kiro-crew/licenses/llama.cpp-LICENSE"
        install -Dm644 LICENSE "$out/share/doc/kiro-crew/licenses/LICENSE"
      '';

    postFixup = lib.optionalString (wrapperArgs != []) ''
      wrapProgram "$out/bin/kirocrew" ${lib.escapeShellArgs wrapperArgs}
    '';

    passthru = {
      inherit fixNpmDepsHash frontend;
      # Read by `checks/patches-apply.nix`, which applies every entry — the
      # dormant ones included — to the pinned src at zero fuzz, and asserts
      # this manifest and the `patches/` directory listing are the same set.
      inherit patchManifest;
    };

    meta = {
      description = "Personal AI agent that runs locally — CLI, dashboard, desktop app, and messaging channels";
      homepage = "https://github.com/kirodotdev/KiroCrew";
      # The SHIPPED BUNDLE, not just the first-party source — a bare `asl20`
      # was wrong about four fifths of what lands in `$out`:
      #
      #   asl20  upstream's own code
      #   mit    the vendored llama-cpp-python 0.3.34 binding, the
      #          llama.cpp/ggml binaries it loads, and the dashboard's npm
      #          aggregate (see `passthru.frontend.meta.license`)
      #   ofl    the OpenDyslexic faces carried in the dashboard dist
      #
      # No GPL row: the vendored libgomp that would have needed one is
      # relinked onto nixpkgs' libgomp and deleted in `prepareVendoredLibs`.
      license = with lib.licenses; [asl20 mit ofl];
      mainProgram = "kirocrew";
    };
  }
