# Independent release pin: Kimchi's pnpm lock does not select this build.
{
  extractedLib,
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) lib;
  upstreamManifest = builtins.fromJSON (builtins.readFile "${src}/package.json");
  requestedPnpm = upstreamManifest.kimchiWorkflows.packageManager or upstreamManifest.packageManager;
  pnpmMatch = builtins.match "pnpm@([0-9]+)\\..*" requestedPnpm;
  pnpmAttr = "pnpm_${builtins.head pnpmMatch}";
  pnpm =
    if pnpmMatch == null
    then throw "kimchi-workflows: expected pnpm@<major>.<version>, got ${requestedPnpm}"
    else if !(builtins.hasAttr pnpmAttr pkgs.ai.generic)
    then throw "kimchi-workflows: ${requestedPnpm} requires unavailable pkgs.ai.generic.${pnpmAttr}"
    else pkgs.ai.generic.${pnpmAttr};
  runtimePnpm = pkgs.writeShellScriptBin "kimchi-workflows-pnpm" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    export PATH="${lib.makeBinPath [pkgs.bash pkgs.coreutils pkgs.gnused pkgs.nodejs]}''${PATH:+:$PATH}"
    exec ${lib.getExe pnpm} "$@"
  '';
  inherit (extractedLib {inherit pkgs;}) get load;
  inherit (load {dir = ../../../../extracted;}) aggregate;
  virtualPackages = pkgs.writeText "pi-virtual-packages.json" (builtins.toJSON (get aggregate "virtualPackages"));
  sources = builtins.fromJSON (builtins.readFile ../../../../workflows-sources.json);
  sourcesFile = repoPath ../../../../workflows-sources.json;
  src = pkgs.fetchFromGitHub {
    owner = "getkimchi";
    repo = "kimchi-workflows";
    name = "${versionedName}-source";
    inherit (sources) rev;
    hash = sources.srcHash;
  };
  versionedName = "kimchi-workflows-${sources.version}-${builtins.substring 0 7 sources.rev}";
  fixPnpmDepsHash = packageLib.mkHashFix {
    attr = "kimchi-workflows";
    name = "pnpm-deps";
    inherit pkgs sourcesFile;
    pname = "kimchi-workflows";
    targets = [packageLib.hashFixTargets.pnpmDeps];
  };
in
  pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "kimchi-workflows";
    inherit (sources) version;
    inherit src;
    patches = [./native-preflight.patch ./pnpm-runtime.patch ./step-thinking.patch];
    patchFlags = ["-p1" "--fuzz=0"];
    postPatch = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      substituteInPlace src/host/workflow-package-manager.ts \
        --replace-fail '@node@' '${lib.getExe pkgs.nodejs}'
      substituteInPlace src/host/workflow-package-manager.ts test/nix-package-manager.test.ts \
        --replace-fail '@pnpm@' '${lib.getExe runtimePnpm}'
      substituteInPlace test/nix-package-manager.test.ts \
        --replace-fail '@pnpmVersion@' '${pnpm.version}' \
        --replace-fail '@shell@' '${pkgs.bash}/bin/bash'
      substituteInPlace src/host/workflow-package.ts test/nix-preflight.test.ts \
        --replace-fail '@workflowPackage@' "$out"
    '';
    pnpmDeps = pkgs.fetchPnpmDeps {
      pname = versionedName;
      inherit (finalAttrs) src version;
      inherit pnpm;
      fetcherVersion = 3;
      hash = sources.pnpmDepsHash or lib.fakeHash;
    };
    nativeBuildInputs =
      [pkgs.nodejs pnpm pkgs.pnpmConfigHook]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [pkgs.autoPatchelfHook];
    # Vitest's Vite dependencies ship native rolldown/lightningcss bindings.
    buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [pkgs.stdenv.cc.cc.lib];
    # The npm launcher supports this override; its Linux ELF is not Nix-patched.
    env.BIOME_BINARY = lib.getExe pkgs.biome;
    buildPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preBuild
      # Upstream leaves version=0.0.0 in git and stamps it at publication.
      # Run the same metadata generator for our release identity.
      node --input-type=module <<'JS'
      import fs from 'node:fs';
      const manifest = JSON.parse(fs.readFileSync('package.json', 'utf8'));
      manifest.version = '${finalAttrs.version}';
      manifest.nixSourceRev = '${sources.rev}';
      manifest.packageManager = 'pnpm@${pnpm.version}';
      manifest.kimchiWorkflows.packageManager = manifest.packageManager;
      fs.writeFileSync('package.json', JSON.stringify(manifest, null, 2) + '\n');
      JS
      pnpm run dist:metadata
      pnpm run build
      runHook postBuild
    '';
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      pnpm run docs:check
      pnpm run typecheck
      pnpm exec vitest run test/thinking.test.ts test/nix-package-manager.test.ts
      runHook postCheck
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      pnpm exec vitest run test/nix-preflight.test.ts
      runHook postInstallCheck
    '';
    installPhase = ''
      runHook preInstall
      ${pkgs.coreutils}/bin/mkdir -p "$out"
      ${pkgs.coreutils}/bin/cp -r bin dist docs examples src package.json README.md LICENSE NOTICE "$out/"
      node ${../../../../src/install-runtime.mjs} "$out" ${virtualPackages}
      runHook postInstall
    '';
    passthru = {
      inherit fixPnpmDepsHash;
      sourceRev = sources.rev;
      updateScript = packageLib.mkUpdateScript {
        inherit pkgs sourcesFile;
        pname = "kimchi-workflows";
        platforms = {};
        versionCheck.cmd = packageLib.ghLatestVersionCmd {
          inherit pkgs;
          repo = "getkimchi/kimchi-workflows";
        };
        extraExtract = ''
          # Resolve annotated tags to their commit, not the tag object.
          tag_refs=$(${pkgs.git}/bin/git ls-remote https://github.com/getkimchi/kimchi-workflows "refs/tags/v$latest" "refs/tags/v$latest^{}")
          rev=$(${pkgs.gawk}/bin/awk 'END {print $1}' <<< "$tag_refs")
          if [[ ! "$rev" =~ ^[0-9a-f]{40}$ ]]; then
            echo "kimchi-workflows: release tag v$latest has no commit" >&2
            exit 1
          fi
          prefetched=$(${pkgs.nix}/bin/nix store prefetch-file --json --unpack "https://github.com/getkimchi/kimchi-workflows/archive/$rev.tar.gz")
          src_hash=$(${pkgs.jq}/bin/jq -er '.hash' <<< "$prefetched")
          source_tmp=$(${pkgs.coreutils}/bin/mktemp)
          ${pkgs.jq}/bin/jq --arg rev "$rev" --arg hash "$src_hash" \
            '. + {rev: $rev, srcHash: $hash}' ${sourcesFile} > "$source_tmp"
          ${pkgs.coreutils}/bin/mv "$source_tmp" ${sourcesFile}
          ${fixPnpmDepsHash}
          ${pkgs.nix}/bin/nix fmt -- ${sourcesFile}
        '';
      };
    };
    meta = {
      description = "External source-built Kimchi workflows extension with runtime dependencies";
      homepage = "https://github.com/getkimchi/kimchi-workflows";
      license = lib.licenses.asl20;
      platforms = ["aarch64-darwin" "x86_64-linux"];
    };
  })
