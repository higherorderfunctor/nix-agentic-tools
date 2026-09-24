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
  inherit (ourPkgs) fetchzip lib;
  pnpm = ourPkgs.pnpm_10;
  sources = builtins.fromJSON (builtins.readFile ../../../sources.json);
  sourcesFile = repoPath ../../../sources.json;
  extraction = sources.extraction or (throw "kimchi: missing extraction source pins");
  goFloor = sources.goFloor or packageLib.goFloorUnknown;
  goModPath = "tools/proxy-helper/go.mod";

  fetchExtraction = source:
    fetchzip {
      inherit (source) hash url;
    };
  # A fixed-output store path is a function of its name and declared hash
  # only. fetchzip defaults to the unversioned name "source" and
  # fetchPnpmDeps to "<pname>-pnpm-deps", so a bump that leaves a hash
  # untouched resolves to the previous release's cached output and is never
  # re-verified. Putting the version in the name moves the path on every
  # bump, forcing a fetch that checks the hash. The Go vendor FOD needs
  # nothing: buildGoModule already names it <pname>-<version>-go-modules.
  versionedName = "kimchi-${sources.version}";

  # The release source is pinned ONCE, under `extraction.kimchiSource`: the
  # build compiles it and the extractor reads it, so the two can never be
  # pointed at different trees.
  kimchiSource = fetchzip {
    name = "${versionedName}-source";
    inherit (extraction.kimchiSource) hash url;
  };
  piAgentCorePackage = fetchExtraction extraction.piAgentCorePackage;
  piAiPackage = fetchExtraction extraction.piAiPackage;
  piPackage = fetchExtraction extraction.piPackage;
  piTuiPackage = fetchExtraction extraction.piTuiPackage;

  extracted =
    ourPkgs.runCommand "kimchi-extracted.json" {
      nativeBuildInputs = [ourPkgs.nodejs ourPkgs.typescript_5];
    } ''
      ${ourPkgs.yq-go}/bin/yq -o=json '.' ${kimchiSource}/pnpm-lock.yaml > kimchi-lock.json
      ${ourPkgs.nodejs}/bin/node ${../../../extract/extract.mjs} \
        --annotations ${../../../extract/annotations.json} \
        --kimchi-lock kimchi-lock.json \
        --kimchi-source ${kimchiSource} \
        --kimchi-source-url ${lib.escapeShellArg extraction.kimchiSource.url} \
        --kimchi-version ${sources.version} \
        --out "$out" \
        --pi-agent-core-package ${piAgentCorePackage} \
        --pi-ai-package ${piAiPackage} \
        --pi-package ${piPackage} \
        --pi-tui-package ${piTuiPackage} \
        --typescript ${ourPkgs.typescript_5}/lib/node_modules/typescript/lib/typescript.js
    '';

  # `mkUpdateScript` records the version alone (`platforms = {}`), so this
  # runs first and writes every hash-verified source input: the release
  # source that both the build and the extractor read, then pi's packages.
  # The dependency fixers that follow it build against that source pin.
  refreshExtraction = ''
    kimchi_source_url="https://github.com/getkimchi/kimchi/archive/refs/tags/v$latest.tar.gz"
    kimchi_source_json=$(${ourPkgs.nix}/bin/nix store prefetch-file --json --unpack "$kimchi_source_url")
    kimchi_source_hash=$(${ourPkgs.jq}/bin/jq -er '.hash' <<< "$kimchi_source_json")
    kimchi_source_path=$(${ourPkgs.jq}/bin/jq -er '.storePath' <<< "$kimchi_source_json")

    pi_version=$(${ourPkgs.jq}/bin/jq -er \
      '.dependencies["@earendil-works/pi-coding-agent"] | strings | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' \
      "$kimchi_source_path/package.json")
    pi_package_url="https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-$pi_version.tgz"
    pi_package_json=$(${ourPkgs.nix}/bin/nix store prefetch-file --json --unpack "$pi_package_url")
    pi_package_hash=$(${ourPkgs.jq}/bin/jq -er '.hash' <<< "$pi_package_json")

    # pi's declaration packages at the versions Kimchi's lockfile resolves
    # pi's dependencies to, which is what the source build installs.
    kimchi_lock_json=$(${ourPkgs.yq-go}/bin/yq -o=json '.' "$kimchi_source_path/pnpm-lock.yaml")
    pi_reference=$(${ourPkgs.jq}/bin/jq -er \
      '.importers["."].dependencies["@earendil-works/pi-coding-agent"].version | strings' \
      <<< "$kimchi_lock_json")

    prefetch_pi_dependency() {
      local dependency_name="$1"
      local variable_prefix="$2"
      local dependency_version
      local dependency_url
      local dependency_json
      local dependency_hash
      dependency_version=$(${ourPkgs.jq}/bin/jq -er \
        --arg reference "@earendil-works/pi-coding-agent@$pi_reference" \
        --arg name "@earendil-works/$dependency_name" \
        '.snapshots[$reference].dependencies[$name] | strings | sub("\\(.*$"; "") | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' \
        <<< "$kimchi_lock_json")
      dependency_url="https://registry.npmjs.org/@earendil-works/$dependency_name/-/$dependency_name-$dependency_version.tgz"
      dependency_json=$(${ourPkgs.nix}/bin/nix store prefetch-file --json --unpack "$dependency_url")
      dependency_hash=$(${ourPkgs.jq}/bin/jq -er '.hash' <<< "$dependency_json")
      printf -v "''${variable_prefix}_hash" '%s' "$dependency_hash"
      printf -v "''${variable_prefix}_url" '%s' "$dependency_url"
      printf -v "''${variable_prefix}_version" '%s' "$dependency_version"
    }
    prefetch_pi_dependency pi-agent-core pi_agent_core
    prefetch_pi_dependency pi-ai pi_ai
    prefetch_pi_dependency pi-tui pi_tui

    extraction_tmp=$(${ourPkgs.coreutils}/bin/mktemp)
    ${ourPkgs.jq}/bin/jq \
      --arg kh "$kimchi_source_hash" \
      --arg ku "$kimchi_source_url" \
      --arg pi_agent_core_hash "$pi_agent_core_hash" \
      --arg pi_agent_core_url "$pi_agent_core_url" \
      --arg pi_agent_core_version "$pi_agent_core_version" \
      --arg pi_ai_hash "$pi_ai_hash" \
      --arg pi_ai_url "$pi_ai_url" \
      --arg pi_ai_version "$pi_ai_version" \
      --arg ph "$pi_package_hash" \
      --arg pu "$pi_package_url" \
      --arg pv "$pi_version" \
      --arg pth "$pi_tui_hash" \
      --arg ptu "$pi_tui_url" \
      --arg ptv "$pi_tui_version" \
      '. + {extraction: {
        kimchiSource: {hash: $kh, url: $ku},
        piAgentCorePackage: {hash: $pi_agent_core_hash, url: $pi_agent_core_url, version: $pi_agent_core_version},
        piAiPackage: {hash: $pi_ai_hash, url: $pi_ai_url, version: $pi_ai_version},
        piPackage: {hash: $ph, url: $pu, version: $pv},
        piTuiPackage: {hash: $pth, url: $ptu, version: $ptv}
      }}' \
      ${sourcesFile} > "$extraction_tmp"
    ${ourPkgs.coreutils}/bin/mv "$extraction_tmp" ${sourcesFile}
    ${ourPkgs.nix}/bin/nix fmt -- ${sourcesFile}

    ${packageLib.mkExtractRegen {
      attr = "kimchi";
      dest = repoPath ../../../extracted.json;
      pkgs = ourPkgs;
    }}
  '';

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
    src = kimchiSource;

    pnpmDeps = ourPkgs.fetchPnpmDeps {
      # fetchPnpmDeps derives its name from pname alone; see versionedName.
      pname = versionedName;
      inherit (finalAttrs) src version;
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
      inherit extracted fixPnpmDepsHash goFloor goModPath proxyHelper;
      inherit (goUpdate) fixGoFloor fixVendorHash;
      extractionSources = {
        kimchi = kimchiSource;
        pi = piPackage;
        piAgentCore = piAgentCorePackage;
        piAi = piAiPackage;
        piTui = piTuiPackage;
      };
      extractionSourceUrls.kimchi = extraction.kimchiSource.url;
      goUpdateExtract = goUpdate.extract;
      updateScript = packageLib.mkUpdateScript {
        # The source pin lives in the extraction block, so the release
        # version is the only thing mkUpdateScript itself records.
        extraExtract = ''
          ${refreshExtraction}
          ${goUpdate.extract}
        '';
        pkgs = ourPkgs;
        platforms = {};
        pname = "kimchi";
        inherit sourcesFile;
        versionCheck.cmd = packageLib.ghLatestVersionCmd {
          pkgs = ourPkgs;
          repo = "getkimchi/kimchi";
        };
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
