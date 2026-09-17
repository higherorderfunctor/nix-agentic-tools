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
  # ── Seams for LATER, SEPARATE derivations ───────────────────────────────
  #
  # Null by default, and with every one null this derivation is byte-identical
  # to one that never declared them (no wrapper is produced at all). Each is
  # filled by `packages.kiro-crew.override { … }` once the corresponding
  # upstream artifact has a derivation of its own. They are arguments rather
  # than hardcoded paths precisely so that nothing else's source, build or
  # patches ever has to be lumped into this recipe.
  #
  # `embedModel`: a GGUF embedding model (upstream bundles qwen3-embedding
  #   0.6b and DOWNLOADS it at first use). Wired to upstream's own
  #   `KIROCREW_EMBED_MODEL_PATH`, which selects a local GGUF instead.
  #
  # `llamaCppLib`: a directory holding `libllama` and its `libggml*`
  #   dependencies. Wired to upstream's own `LLAMA_CPP_LIB_PATH`, documented in
  #   `_vendor/llama_cpp/llama_cpp.py` as the override naming the directory
  #   ctypes loads the native libs from. Deliberately an ENV SEAM and not a
  #   staging step back into `_vendor/llama_cpp_libs/`, so the later pass is
  #   free to pair nixpkgs' own `llama-cpp` with nixpkgs'
  #   `python313Packages.llama-cpp-python` (a matched binding/library pair,
  #   no ABI skew) instead of being forced onto the vendored binding.
  #
  # Not yet seamed, because their runtime contract is a URL rather than a
  # path and inventing one here would be a guess: the PPTX Maker engine
  # (`KIROCREW_PPTX_ENGINE_URL` / `KIROCREW_PPTX_SKIP_ENGINE_DOWNLOAD`, a
  # separate MIT-0 upstream) and the whisper.cpp models
  # (`KIROCREW_WHISPER_MODEL_BASE_URL`). Add them the same way — as arguments
  # with null defaults — when those derivations exist.
  embedModel ? null,
  llamaCppLib ? null,
  ...
}: let
  ourPkgs = pkgs;
  inherit (ourPkgs) buildNpmPackage fetchFromGitHub lib makeWrapper nodejs_24 python313 python313Packages;
  vu = packageLib;

  rev = "40624a1fb7df98393a2de57eb6ae1fb017b536fe";
  src = fetchFromGitHub {
    owner = "kirodotdev";
    repo = "KiroCrew";
    inherit rev;
    # PLACEHOLDER — `lib.fakeHash`, spelled as a quoted literal on purpose.
    # `dev/scripts/update-pkg.sh` Phase 0 finds this with
    # `grep -oP 'hash = "\Ksha256-[^"]+'`; an unquoted `lib.fakeHash` is
    # invisible to it, which skips the prefetch AND therefore the
    # `# upstream:` version rewrite below, shipping a package that claims one
    # version and builds another.
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
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
      license = lib.licenses.asl20;
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
    lib.optionals (embedModel != null) ["--set-default" "KIROCREW_EMBED_MODEL_PATH" "${embedModel}"]
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
      ++ lib.optionals ourPkgs.stdenv.hostPlatform.isDarwin [truststore];

    nativeBuildInputs = lib.optionals (wrapperArgs != []) [makeWrapper];

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

    preBuild =
      ''
        # GPL-3.0 libgomp, vendored with no licence text of its own, under
        # `linux_x86_64/libgomp-a34b3233.so.1.0.0` and
        # `linux_aarch64/libgomp-d22c30c5.so.1.0.0`. The whole directory goes:
        # it is 26MB of prebuilt llama.cpp/ggml binaries for five platforms,
        # none of which belongs in a Nix closure. In-process embeddings are
        # supplied by the `llamaCppLib` seam at the top of this file instead.
        rm -rf src/kiro_crew/_vendor/llama_cpp_libs

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

    # postInstall, NOT installCheckPhase, and that is a measured constraint
    # rather than a style choice. `mk-python-derivation.nix` hardcodes
    # `doInstallCheck = attrs.doCheck or true`, so it DISCARDS an explicit
    # `doInstallCheck = true` whenever `doCheck` is false. Measured on this
    # derivation: with `doInstallCheck = true` written out, the evaluated
    # attribute came back `false` while the phase text sat in the .drv,
    # unreachable — the assertion would have read as present and never run.
    postInstall = assertDashboard "$out/${python313.sitePackages}/kiro_crew/static/dist";

    postFixup = lib.optionalString (wrapperArgs != []) ''
      wrapProgram "$out/bin/kirocrew" ${lib.escapeShellArgs wrapperArgs}
    '';

    passthru = {
      inherit fixNpmDepsHash frontend;
    };

    meta = {
      description = "Personal AI agent that runs locally — CLI, dashboard, desktop app, and messaging channels";
      homepage = "https://github.com/kirodotdev/KiroCrew";
      license = lib.licenses.asl20;
      mainProgram = "kirocrew";
    };
  }
