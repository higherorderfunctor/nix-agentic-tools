# Kimchi CLI — standalone derivation against per-platform release tarball.
#
# Kimchi (getkimchi/kimchi) is a coding-agent CLI "powered by Cast AI",
# distributed as bun-compiled per-platform tarballs on GitHub Releases.
# The tarball is NOT a lone binary: it is an FHS-style tree —
#   bin/kimchi                     (bun single-exec, dynamically linked)
#   share/kimchi/bin/proxy-helper  (small stripped ELF helper)
#   share/kimchi/{theme,oauth,export-html,package.json}  (runtime assets)
# kimchi resolves share/ relative to the executable, so we preserve the
# whole tree under $out and do not relocate the binary.
#
# Standalone (not overrideAttrs): there is no nixpkgs base package to
# inherit from, and the artifact is a self-contained tarball, so we build
# a fresh stdenv.mkDerivation. On Linux both ELFs need autoPatchelfHook to
# repoint the interpreter/rpath at the nix glibc.
#
# Free (Apache-2.0). ensureUnfreeCheck in default.nix passes free packages
# through unwrapped.
{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  ourPkgs = pkgs;
  inherit (ourPkgs) autoPatchelfHook fetchurl fetchzip lib stdenv;
  inherit (ourPkgs.stdenv.hostPlatform) system;
  vu = packageLib;

  sources = builtins.fromJSON (builtins.readFile ../../../sources.json);
  extraction = sources.extraction or (throw "kimchi: missing extraction source pins");
  platformSrc = sources.${system} or (throw "kimchi: unsupported system ${system}");

  fetchExtraction = source:
    fetchzip {
      inherit (source) hash url;
    };
  kimchiSource = fetchExtraction extraction.kimchiSource;
  piAgentCorePackage = fetchExtraction extraction.piAgentCorePackage;
  piAiPackage = fetchExtraction extraction.piAiPackage;
  piPackage = fetchExtraction extraction.piPackage;
  piTuiPackage = fetchExtraction extraction.piTuiPackage;

  extracted =
    ourPkgs.runCommand "kimchi-extracted.json" {
      nativeBuildInputs = [ourPkgs.nodejs ourPkgs.typescript_5];
    } ''
      ${ourPkgs.nodejs}/bin/node ${../../../extract/extract.mjs} \
        --annotations ${../../../extract/annotations.json} \
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

  # The release binary does not contain dependable source metadata. Refresh
  # both hash-verified source inputs immediately after mkUpdateScript replaces
  # the platform pins, then regenerate the measured sidecar from those inputs.
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
    pi_package_path=$(${ourPkgs.jq}/bin/jq -er '.storePath' <<< "$pi_package_json")

    prefetch_pi_dependency() {
      local dependency_name="$1"
      local variable_prefix="$2"
      local dependency_version
      local dependency_url
      local dependency_json
      local dependency_hash
      dependency_version=$(${ourPkgs.jq}/bin/jq -er \
        --arg name "@earendil-works/$dependency_name" \
        '.dependencies[$name] | strings | ltrimstr("^") | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' \
        "$pi_package_path/package.json")
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
      --arg pach "$pi_agent_core_hash" \
      --arg pacu "$pi_agent_core_url" \
      --arg pacv "$pi_agent_core_version" \
      --arg paih "$pi_ai_hash" \
      --arg paiu "$pi_ai_url" \
      --arg paiv "$pi_ai_version" \
      --arg ph "$pi_package_hash" \
      --arg pu "$pi_package_url" \
      --arg pv "$pi_version" \
      --arg pth "$pi_tui_hash" \
      --arg ptu "$pi_tui_url" \
      --arg ptv "$pi_tui_version" \
      '. + {extraction: {
        kimchiSource: {hash: $kh, url: $ku},
        piAgentCorePackage: {hash: $pach, url: $pacu, version: $pacv},
        piAiPackage: {hash: $paih, url: $paiu, version: $paiv},
        piPackage: {hash: $ph, url: $pu, version: $pv},
        piTuiPackage: {hash: $pth, url: $ptu, version: $ptv}
      }}' \
      ${repoPath ../../../sources.json} > "$extraction_tmp"
    ${ourPkgs.coreutils}/bin/mv "$extraction_tmp" ${repoPath ../../../sources.json}
    ${ourPkgs.nix}/bin/nix fmt -- ${repoPath ../../../sources.json}

    ${vu.mkExtractRegen {
      attr = "kimchi";
      dest = repoPath ../../../extracted.json;
      pkgs = ourPkgs;
    }}
  '';
in
  ourPkgs.stdenv.mkDerivation {
    pname = "kimchi";
    inherit (sources) version;
    src = fetchurl {inherit (platformSrc) url hash;};

    sourceRoot = ".";
    dontStrip = true;

    nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];

    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      stdenv.cc.cc.lib
    ];

    # The bun single-exec bundles its own runtime; autoPatchelf would
    # otherwise chase optional deps that don't matter for a self-contained
    # binary.
    autoPatchelfIgnoreMissingDeps = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r bin share $out/
      chmod +x $out/bin/kimchi $out/share/kimchi/bin/proxy-helper
      runHook postInstall
    '';

    # Lenient smoke test: confirm the patched binary actually executes
    # (loader resolves, bun payload still found post-patchelf) rather than
    # failing with a loader/exec error. Tolerant of non-zero exits from a
    # CLI that may want config/network — we only fail on a hard exec error.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      out_txt=$(timeout 30 $out/bin/kimchi --version 2>&1 || true)
      echo "kimchi --version => $out_txt"
      case "$out_txt" in
        *"No such file or directory"* | *"cannot execute"* | *"not found"*)
          echo "kimchi: binary failed to execute after patching" >&2
          exit 1
          ;;
      esac
      runHook postInstallCheck
    '';

    passthru = {
      inherit extracted;
      extractionSources = {
        kimchi = kimchiSource;
        pi = piPackage;
        piAgentCore = piAgentCorePackage;
        piAi = piAiPackage;
        piTui = piTuiPackage;
      };
      extractionSourceUrls.kimchi = extraction.kimchiSource.url;
      updateScript = vu.mkUpdateScript {
        sourcesFile = repoPath ../../../sources.json;

        pname = "kimchi";
        versionCheck.cmd = vu.ghLatestVersionCmd {
          pkgs = ourPkgs;
          repo = "getkimchi/kimchi";
        };
        platforms = {
          "x86_64-linux" = ver: "https://github.com/getkimchi/kimchi/releases/download/v${ver}/kimchi_linux_amd64.tar.gz";
          "aarch64-darwin" = ver: "https://github.com/getkimchi/kimchi/releases/download/v${ver}/kimchi_darwin_arm64.tar.gz";
        };
        extraExtract = refreshExtraction;
        pkgs = ourPkgs;
      };
    };

    meta = {
      description = "Kimchi — coding agent CLI powered by Cast AI";
      homepage = "https://github.com/getkimchi/kimchi";
      license = lib.licenses.asl20;
      platforms = builtins.attrNames (builtins.removeAttrs sources ["extraction" "version"]);
      mainProgram = "kimchi";
    };
  }
