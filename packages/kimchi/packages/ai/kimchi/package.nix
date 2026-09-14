# Build the release source and its proxy helper with pinned Nix toolchains.
# Keep upstream's bin/ + share/ layout: the compiled CLI resolves its assets
# relative to the executable, including when the module wraps that executable.
{
  inputs,
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    overlays = [inputs.go-overlay.overlays.default];
  };
  inherit (ourPkgs) lib;
  pnpm = ourPkgs.pnpm_10;
  sources = builtins.fromJSON (builtins.readFile ../../../sources.json);
  sourcesFile = repoPath ../../../sources.json;
  goFloor = sources.goFloor or packageLib.goFloorUnknown;
  goModPath = "tools/proxy-helper/go.mod";
  fixPnpmDepsHash = packageLib.mkHashFix {
    attr = "kimchi";
    name = "pnpm-deps";
    pkgs = ourPkgs;
    pname = "kimchi";
    inherit sourcesFile;
    targets = [packageLib.hashFixTargets.pnpmDeps];
  };
  goUpdate = packageLib.mkGoUpdateExtract {
    attr = "kimchi.proxyHelper";
    extraAfter = "${fixPnpmDepsHash}";
    inherit goModPath sourcesFile;
    pkgs = ourPkgs;
    pname = "kimchi";
  };
in
  ourPkgs.stdenv.mkDerivation (finalAttrs: let
    proxyHelper =
      (packageLib.mkGoBuilder {
        floor = goFloor;
        pkgs = ourPkgs;
        pname = "kimchi-proxy-helper";
      }) {
        pname = "kimchi-proxy-helper";
        inherit (finalAttrs) src version;
        modRoot = "tools/proxy-helper";
        vendorHash = sources.vendorHash or lib.fakeHash;
        env.CGO_ENABLED = "0";
        ldflags = ["-s" "-w"];
        meta.mainProgram = "proxy-helper";
      };
  in {
    pname = "kimchi";
    inherit (sources) version;
    src = ourPkgs.fetchzip {inherit (sources.src) url hash;};

    patches = [./store-skills.patch];

    preBuild = ''
      cp ${./store-skills.test.ts} src/shared/skill-discovery/store-skills.test.ts
    '';

    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname src version;
      inherit pnpm;
      fetcherVersion = 3;
      hash = sources.pnpmDepsHash or lib.fakeHash;
    };
    nativeBuildInputs =
      [
        ourPkgs.bun
        ourPkgs.nodejs
        pnpm
        ourPkgs.pnpmConfigHook
      ]
      ++ lib.optionals ourPkgs.stdenv.hostPlatform.isDarwin [ourPkgs.rcodesign];

    # macOS codesign is not available in Nix's build sandbox. Use the same
    # ad-hoc signature repair as nixpkgs' Bun package.
    #
    # Upstream rewrote this block in 1.1.25: the signing commands interpolate a
    # `binaryPath` local instead of `dist/bin/${target.binaryName}` inline, and
    # the ad-hoc path gained a `codesign --verify` step. All three calls invoke
    # Apple's `codesign`, so all three must be replaced. `--replace-fail` turns a
    # pattern that stops matching into a build error instead of a silent skip
    # that would ship an unusable signature.
    postPatch = lib.optionalString ourPkgs.stdenv.hostPlatform.isDarwin ''
      substituteInPlace scripts/build-binary.js \
        --replace-fail 'run("codesign (strip)", `codesign --remove-signature ''${binaryPath}`)' \
          'run("codesign (rcodesign linker-signed)", `rcodesign sign --code-signature-flags linker-signed ''${binaryPath}`)' \
        --replace-fail 'run("codesign (ad-hoc)", `codesign -s - ''${binaryPath}`)' "" \
        --replace-fail 'run("codesign (verify)", `codesign --verify -v ''${binaryPath}`)' ""
    '';

    # Bun's compiled module graph is part of the executable. Generic ELF
    # rewriting and stripping must not alter it after compilation.
    dontPatchELF = true;
    dontStrip = true;
    env.HUSKY = "0";

    buildPhase = ''
      runHook preBuild
      node scripts/set-version.js v${finalAttrs.version}
      node scripts/patch-pi-ai-oauth.js
      mkdir -p tools/proxy-helper/bin
      cp ${proxyHelper}/bin/proxy-helper tools/proxy-helper/bin/proxy-helper
      CI=1 node scripts/build-binary.js
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r dist/bin dist/share "$out/"
      runHook postInstall
    '';

    doCheck = true;
    checkPhase = ''
      runHook preCheck
      pnpm exec vitest run --maxWorkers=2 \
        src/shared/skill-discovery/resolve-skill-roots.test.ts \
        src/shared/skill-discovery/store-skills.test.ts \
        src/extensions/prompt-construction/prompt-enrichment.test.ts
      runHook postCheck
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      export KIMCHI_NO_UPDATE_CHECK=1 KIMCHI_TELEMETRY_ENABLED=0
      version_output=$(timeout 30 "$out/bin/kimchi" --version)
      printf '%s\n' "$version_output"
      test "$version_output" = '${finalAttrs.version}'
      "$out/share/kimchi/bin/proxy-helper" --help > /dev/null
      test -f "$out/share/kimchi/theme/dark.json"
      test -f "$out/share/kimchi/export-html/template.html"
      test -f "$out/share/kimchi/skills/improve/SKILL.md"
      runHook postInstallCheck
    '';

    passthru = {
      inherit fixPnpmDepsHash goFloor goModPath proxyHelper;
      inherit (goUpdate) fixGoFloor fixVendorHash;
      goUpdateExtract = goUpdate.extract;
      updateScript = packageLib.ghArchiveUpdateScript {
        extraExtract = "${goUpdate.extract}";
        pkgs = ourPkgs;
        pname = "kimchi";
        repo = "getkimchi/kimchi";
        inherit sourcesFile;
      };
    };
    meta = {
      description = "Kimchi — coding agent CLI powered by Cast AI";
      homepage = "https://github.com/getkimchi/kimchi";
      license = lib.licenses.asl20;
      mainProgram = "kimchi";
      platforms = ["aarch64-darwin" "x86_64-linux"];
    };
  })
