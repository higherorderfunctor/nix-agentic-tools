# Build the release source and its proxy helper with pinned Nix toolchains.
# Keep upstream's bin/ + share/ layout: the compiled CLI resolves its assets
# relative to the executable, including when the module wraps that executable.
{
  externalizedExtensions ? import ../../../externalized-extensions.nix,
  extractedLib,
  fd,
  packageLib,
  pkgs,
  repoPath,
  ripgrep,
  ...
}: let
  inherit (pkgs) fetchzip lib;
  pnpm = pkgs.ai.generic.pnpm_10;
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
  piMcpAdapterPackage = fetchExtraction extraction.piMcpAdapterPackage;
  piPackage = fetchExtraction extraction.piPackage;
  piTuiPackage = fetchExtraction extraction.piTuiPackage;
  typeboxPackage = fetchExtraction extraction.typeboxPackage;
  extractionSources = {
    kimchi = kimchiSource;
    pi = piPackage;
    piAgentCore = piAgentCorePackage;
    piAi = piAiPackage;
    piMcpAdapter = piMcpAdapterPackage;
    piTui = piTuiPackage;
    typebox = typeboxPackage;
  };
  externalizeExtensions = import ../../../lib/externalizeExtensions.nix {inherit externalizedExtensions lib;};

  # Extend upstream's dependency-owned patch before either pnpm consumer sees
  # the source. Rehash every reference (including peer snapshots) without
  # regenerating unrelated lock resolutions. Registry tarball bytes stay intact.
  piPatchPath = "patches/@earendil-works__pi-coding-agent@${extraction.piPackage.version}.patch";
  patchedSource = pkgs.applyPatches {
    src = kimchiSource;
    postPatch = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      old_pi_patch_hash=$(sha256sum ${lib.escapeShellArg piPatchPath} | cut -d ' ' -f 1)
      cat ${./extension-package-warnings.patch} ${./package-identity.patch} >> ${lib.escapeShellArg piPatchPath}
      new_pi_patch_hash=$(sha256sum ${lib.escapeShellArg piPatchPath} | cut -d ' ' -f 1)
      substituteInPlace pnpm-lock.yaml \
        --replace-fail "$old_pi_patch_hash" "$new_pi_patch_hash"
    '';
  };

  # The release's CodeQL database and its query runner: ../../../lib/codeql.nix.
  codeql = import ../../../lib/codeql.nix {
    engine = pkgs.ai.devTools.codeql.codeql-javascript;
    inherit (extractionSources) kimchi;
    # TypeBox 1.3.27 supplies pi declarations to extract.mjs; Kimchi runs 1.3.7.
    dependencies = builtins.attrValues (builtins.removeAttrs extractionSources ["kimchi" "typebox"]);
    inherit pkgs;
    inherit (sources) version;
  };
  # The `network` fact: ../../../lib/network.nix.
  network = import ../../../lib/network.nix {inherit codeql pkgs;};
  # The `environment` surface (../../../extract/environment.nix) and the
  # `network` fact come from the database, the rest from extract.mjs over the
  # same release source. The engine runs on x86_64-linux only, which is the
  # one system every facts.json row declares, so the raw exists on that
  # system alone.
  codeqlFacts = {
    environment = (import ../../../extract/environment.nix {inherit codeql pkgs;}).surface;
    network = network.fact;
  };
  extracted =
    pkgs.runCommand "kimchi-extracted.json" {
      nativeBuildInputs = [pkgs.nodejs pkgs.typescript_5];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.yq-go}/bin/yq -o=json '.' ${kimchiSource}/pnpm-lock.yaml > kimchi-lock.json
      ${pkgs.nodejs}/bin/node ${../../../extract/extract.mjs} \
        --annotations ${../../../extract/annotations.json} \
        --kimchi-lock kimchi-lock.json \
        --kimchi-source ${kimchiSource} \
        --kimchi-source-url ${lib.escapeShellArg extraction.kimchiSource.url} \
        --kimchi-version ${sources.version} \
        --out - \
        --pi-agent-core-package ${piAgentCorePackage} \
        --pi-ai-package ${piAiPackage} \
        --pi-package ${piPackage} \
        --pi-tui-package ${piTuiPackage} \
        --typebox-package ${typeboxPackage} \
        --typescript ${pkgs.typescript_5}/lib/node_modules/typescript/lib/typescript.js \
        | ${pkgs.jq}/bin/jq -S ${lib.concatStrings (lib.mapAttrsToList (name: fact: "--slurpfile ${name} ${fact} ") codeqlFacts)}'. + ($ARGS.named | map_values(.[0]))' > "$out"
    '';

  # `mkUpdateScript` records the version alone (`platforms = {}`), so this
  # runs first and writes every hash-verified source input: the release
  # source that both the build and the extractor read, then pi's packages.
  # The dependency fixers that follow it build against that source pin.
  refreshExtraction = ''
    kimchi_source_url="https://github.com/getkimchi/kimchi/archive/refs/tags/v$latest.tar.gz"
    kimchi_source_json=$(${pkgs.nix}/bin/nix store prefetch-file --json --unpack "$kimchi_source_url")
    kimchi_source_hash=$(${pkgs.jq}/bin/jq -er '.hash' <<< "$kimchi_source_json")
    kimchi_source_path=$(${pkgs.jq}/bin/jq -er '.storePath' <<< "$kimchi_source_json")

    pi_version=$(${pkgs.jq}/bin/jq -er \
      '.dependencies["@earendil-works/pi-coding-agent"] | strings | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' \
      "$kimchi_source_path/package.json")
    prefetch_package() {
      local package_name="$1"
      local package_version="$2"
      local variable_prefix="$3"
      local package_url="https://registry.npmjs.org/$package_name/-/''${package_name##*/}-$package_version.tgz"
      local package_json
      local package_hash
      package_json=$(${pkgs.nix}/bin/nix store prefetch-file --json --unpack "$package_url")
      package_hash=$(${pkgs.jq}/bin/jq -er '.hash' <<< "$package_json")
      printf -v "''${variable_prefix}_hash" '%s' "$package_hash"
      printf -v "''${variable_prefix}_url" '%s' "$package_url"
      printf -v "''${variable_prefix}_version" '%s' "$package_version"
    }
    prefetch_package @earendil-works/pi-coding-agent "$pi_version" pi_package
    pi_mcp_adapter_version=$(${pkgs.jq}/bin/jq -er \
      '.dependencies["pi-mcp-adapter"] | strings | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' \
      "$kimchi_source_path/package.json")
    prefetch_package pi-mcp-adapter "$pi_mcp_adapter_version" pi_mcp_adapter

    # pi's declaration packages at the versions Kimchi's lockfile resolves
    # pi's dependencies to, which is what the source build installs.
    kimchi_lock_json=$(${pkgs.yq-go}/bin/yq -o=json '.' "$kimchi_source_path/pnpm-lock.yaml")
    pi_reference=$(${pkgs.jq}/bin/jq -er \
      '.importers["."].dependencies["@earendil-works/pi-coding-agent"].version | strings' \
      <<< "$kimchi_lock_json")

    prefetch_pi_dependency() {
      local dependency_name="$1"
      local variable_prefix="$2"
      local dependency_version
      dependency_version=$(${pkgs.jq}/bin/jq -er \
        --arg reference "@earendil-works/pi-coding-agent@$pi_reference" \
        --arg name "$dependency_name" \
        '.snapshots[$reference].dependencies[$name] | strings | sub("\\(.*$"; "") | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' \
        <<< "$kimchi_lock_json")
      prefetch_package "$dependency_name" "$dependency_version" "$variable_prefix"
    }
    prefetch_pi_dependency @earendil-works/pi-agent-core pi_agent_core
    prefetch_pi_dependency @earendil-works/pi-ai pi_ai
    prefetch_pi_dependency @earendil-works/pi-tui pi_tui
    prefetch_pi_dependency typebox typebox

    extraction_tmp=$(${pkgs.coreutils}/bin/mktemp)
    ${pkgs.jq}/bin/jq \
      --arg kh "$kimchi_source_hash" \
      --arg ku "$kimchi_source_url" \
      --arg pi_agent_core_hash "$pi_agent_core_hash" \
      --arg pi_agent_core_url "$pi_agent_core_url" \
      --arg pi_agent_core_version "$pi_agent_core_version" \
      --arg pi_ai_hash "$pi_ai_hash" \
      --arg pi_ai_url "$pi_ai_url" \
      --arg pi_ai_version "$pi_ai_version" \
      --arg pi_mcp_adapter_hash "$pi_mcp_adapter_hash" \
      --arg pi_mcp_adapter_url "$pi_mcp_adapter_url" \
      --arg pi_mcp_adapter_version "$pi_mcp_adapter_version" \
      --arg ph "$pi_package_hash" \
      --arg pu "$pi_package_url" \
      --arg pv "$pi_version" \
      --arg pth "$pi_tui_hash" \
      --arg ptu "$pi_tui_url" \
      --arg ptv "$pi_tui_version" \
      --arg th "$typebox_hash" \
      --arg tu "$typebox_url" \
      --arg tv "$typebox_version" \
      '. + {extraction: {
        kimchiSource: {hash: $kh, url: $ku},
        piAgentCorePackage: {hash: $pi_agent_core_hash, url: $pi_agent_core_url, version: $pi_agent_core_version},
        piAiPackage: {hash: $pi_ai_hash, url: $pi_ai_url, version: $pi_ai_version},
        piMcpAdapterPackage: {hash: $pi_mcp_adapter_hash, url: $pi_mcp_adapter_url, version: $pi_mcp_adapter_version},
        piPackage: {hash: $ph, url: $pu, version: $pv},
        piTuiPackage: {hash: $pth, url: $ptu, version: $ptv},
        typeboxPackage: {hash: $th, url: $tu, version: $tv}
      }}' \
      ${sourcesFile} > "$extraction_tmp"
    ${pkgs.coreutils}/bin/mv "$extraction_tmp" ${sourcesFile}
    ${pkgs.nix}/bin/nix fmt -- ${sourcesFile}
  '';

  fixPnpmDepsHash = packageLib.mkHashFix {
    attr = "kimchi";
    name = "pnpm-deps";
    inherit pkgs;
    pname = "kimchi";
    inherit sourcesFile;
    targets = [packageLib.hashFixTargets.pnpmDeps];
  };
  goUpdate = packageLib.mkGoUpdateExtract {
    attr = "kimchi.proxyHelper";
    extraAfter = "${fixPnpmDepsHash}";
    inherit goModPath sourcesFile;
    inherit pkgs;
    pname = "kimchi";
  };
in
  pkgs.stdenv.mkDerivation (finalAttrs: let
    proxyHelper =
      (packageLib.mkGoToolchain {
        floor = goFloor;
        inherit pkgs;
        pname = "kimchi-proxy-helper";
      }).buildGoModule {
        pname = "kimchi-proxy-helper";
        inherit (finalAttrs) src version;
        modRoot = "tools/proxy-helper";
        vendorHash = sources.vendorHash or lib.fakeHash;
        env.CGO_ENABLED = "0";
        ldflags = ["-s" "-w"];
        passthru = {inherit goFloor;};
        meta.mainProgram = "proxy-helper";
      };
  in {
    pname = "kimchi";
    inherit (sources) version;
    src = patchedSource;

    # Source changes, one concern per patch; each opens with its own rationale.
    # Refuse changed hunk context on upstream drift instead of applying fuzz.
    patchFlags = ["-p1" "--fuzz=0"];
    patches = [
      ./command-shell.patch
      ./disable-self-update.patch
      ./keep-telemetry-opt-out.patch
      ./remote-feature-toggles.patch
      ./store-skills.patch
    ];

    preBuild = ''
      cp ${./store-skills.test.ts} src/shared/skill-discovery/store-skills.test.ts
    '';

    pnpmDeps = pkgs.fetchPnpmDeps {
      # fetchPnpmDeps derives its name from pname alone; see versionedName.
      pname = versionedName;
      inherit (finalAttrs) src version;
      inherit pnpm;
      fetcherVersion = 3;
      hash = sources.pnpmDepsHash or lib.fakeHash;
    };
    nativeBuildInputs =
      [
        pkgs.ai.generic.bun
        pkgs.nodejs
        pnpm
        pkgs.pnpmConfigHook
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [pkgs.rcodesign];

    # macOS codesign is not available in Nix's build sandbox. Use the same
    # ad-hoc signature repair as nixpkgs' Bun package.
    #
    # Upstream rewrote this block in 1.1.25: the signing commands interpolate a
    # `binaryPath` local instead of `dist/bin/${target.binaryName}` inline, and
    # the ad-hoc path gained a `codesign --verify` step. All three calls invoke
    # Apple's `codesign`, so all three must be replaced. `--replace-fail` turns a
    # pattern that stops matching into a build error instead of a silent skip
    # that would ship an unusable signature.
    postPatch =
      ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
      ''
      + externalizeExtensions
      + lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
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
    # Node sizes its default heap from host memory. From 1.21.0 the build's
    # `tsc --noEmit` step exceeds that default on the 7 GB macOS runners, so
    # pin the heap Linux hosts already get by default.
    env.NODE_OPTIONS = "--max-old-space-size=4096";

    buildPhase = ''
      runHook preBuild
      node scripts/set-version.js v${finalAttrs.version}
      node scripts/patch-pi-ai-oauth.js
      substituteInPlace node_modules/@earendil-works/pi-coding-agent/dist/utils/tools-manager.js \
        --replace-fail $'export function getToolPath(tool) {\n    const config = TOOLS[tool];\n    if (!config)\n        return null;' \
          $'export function getToolPath(tool) {\n    if (tool === "fd")\n        return "${fd}/bin/fd";\n    if (tool === "rg")\n        return "${ripgrep}/bin/rg";\n    const config = TOOLS[tool];\n    if (!config)\n        return null;'
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
        src/shared/skill-discovery/resolve-skill-roots.disables-skills.test.ts \
        src/shared/skill-discovery/resolve-skill-roots.requires-resource.test.ts \
        src/shared/skill-discovery/resolve-skill-roots.test.ts \
        src/shared/skill-discovery/store-skills.test.ts \
        src/extensions/prompt-construction/prompt-enrichment.test.ts
      runHook postCheck
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      export KIMCHI_TELEMETRY_ENABLED=0
      version_output=$(timeout 30 "$out/bin/kimchi" --version)
      printf '%s\n' "$version_output"
      test "$version_output" = '${finalAttrs.version}'
      "$out/share/kimchi/bin/proxy-helper" --help > /dev/null
      test -f "$out/share/kimchi/theme/dark.json"
      test -f "$out/share/kimchi/export-html/template.html"
      test -f "$out/share/kimchi/skills/improve/SKILL.md"
      runHook postInstallCheck
    '';

    passthru =
      {
        inherit codeql externalizedExtensions externalizeExtensions fixPnpmDepsHash goFloor goModPath network proxyHelper;
        inherit (goUpdate) fixGoFloor fixVendorHash;
        extractedRules = import ../../../extract/rules.nix {
          inherit extractedLib pkgs;
          inherit ((extractedLib {inherit pkgs;}).load {dir = ../../../extracted;}) aggregate;
        };
        inherit extractionSources;
        extractionSourceUrls.kimchi = extraction.kimchiSource.url;
        goUpdateExtract = goUpdate.extract;
        updateScript = packageLib.mkUpdateScript {
          # The source pin lives in the extraction block, so the release
          # version is the only thing mkUpdateScript itself records.
          extraExtract = ''
            ${refreshExtraction}
            ${goUpdate.extract}
          '';
          inherit pkgs;
          platforms = {};
          pname = "kimchi";
          inherit sourcesFile;
          versionCheck.cmd = packageLib.ghLatestVersionCmd {
            inherit pkgs;
            repo = "getkimchi/kimchi";
          };
        };
      }
      // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
        inherit extracted;
      };
    meta = {
      description = "Kimchi — coding agent CLI powered by Cast AI";
      homepage = "https://github.com/getkimchi/kimchi";
      license = lib.licenses.asl20;
      mainProgram = "kimchi";
      platforms = ["aarch64-darwin" "x86_64-linux"];
    };
  })
