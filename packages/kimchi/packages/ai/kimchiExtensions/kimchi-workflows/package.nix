# Independent release pin: Kimchi's pnpm lock does not select this build.
{
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) lib;
  pnpm = pkgs.ai.generic.pnpm_10;
  extracted = import ../../../../lib/extracted.nix {
    inherit lib pkgs;
    extracted = builtins.fromJSON (builtins.readFile ../../../../extracted.json);
  };
  virtualPackages = pkgs.writeText "pi-virtual-packages.json" (builtins.toJSON extracted.virtualPackages);
  sources = builtins.fromJSON (builtins.readFile ../../../../workflows-sources.json);
  sourcesFile = repoPath ../../../../workflows-sources.json;
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
    src = pkgs.fetchFromGitHub {
      owner = "getkimchi";
      repo = "kimchi-workflows";
      name = "${versionedName}-source";
      inherit (sources) rev;
      hash = sources.srcHash;
    };
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
      fs.writeFileSync('package.json', JSON.stringify(manifest, null, 2) + '\n');
      JS
      pnpm run dist:metadata
      pnpm run build
      runHook postBuild
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
