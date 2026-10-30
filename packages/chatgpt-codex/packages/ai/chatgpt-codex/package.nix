# ChatGPT Codex CLI uses nixpkgs' source build and complete package at $out.
# nixpkgs builds the CLI, code-mode host and voice host with matching commit
# stamps, and supplies store-linked rg, bwrap and the GStreamer runtime.
# This recipe pins the source, cargo and rusty_v8 hashes and uses the locked
# Rust toolchain.
{
  extractedLib,
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) lib stdenv;
  vu = packageLib // import ../../../lib/packaging.nix;

  sources = builtins.fromJSON (builtins.readFile ../../../sources.json);
  sourcesFile = repoPath ../../../sources.json;
  rustPlatform = vu.mkRustPlatform {
    inherit pkgs sources sourcesFile;
    pname = "chatgpt-codex";
    sourceRoot = "codex-rs";
  };
  packageRoot = (import ../../../lib/packageLayout.nix).root;

  # rusty_v8 release assets: the static V8 library and its prebuilt binding,
  # both matching the `v8` crate version in codex's Cargo.lock. The updater
  # pins them in sources.librustyV8 on every bump, so a codex release that
  # moves the crate does not compile against nixpkgs' older pin. It is pinned
  # even when nixpkgs' pin matches, so a nixpkgs bump cannot move it under an
  # unchanged codex. Systems are the ones nixpkgs' own librusty_v8 pin covers.
  rustyV8 = {
    assets = {
      archive = target: "librusty_v8_release_${target}.a.gz";
      srcBinding = target: "src_binding_release_${target}.rs";
    };
    pin = sources.librustyV8 or null;
    systems = ["aarch64-darwin" "aarch64-linux" "riscv64-linux" "x86_64-linux"];
    url = version: asset: "https://github.com/denoland/rusty_v8/releases/download/v${version}/${asset}";
  };
  fetchRustyV8 = name: key:
    pkgs.fetchurl {
      name = "${name}-${rustyV8.pin.version}";
      url = rustyV8.url rustyV8.pin.version (rustyV8.assets.${key} stdenv.hostPlatform.rust.rustcTarget);
      hash = rustyV8.pin.${key}.${stdenv.hostPlatform.system};
      # As nixpkgs' fetchers: allowNonSource = false still refuses the blob.
      meta.sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  # Prefetches every asset for each system into the JSON object "$rustyV8".
  prefetchRustyV8 = lib.concatMapStrings (system:
    lib.concatMapStrings (key: ''
      hash=$(
        ${pkgs.nix}/bin/nix store prefetch-file --json --hash-type sha256 \
          "${rustyV8.url "\${v8}" (rustyV8.assets.${key} (lib.systems.elaborate system).rust.rustcTarget)}" \
          | ${pkgs.jq}/bin/jq -r .hash
      )
      rustyV8=$(${pkgs.jq}/bin/jq --arg h "$hash" '.${key}."${system}" = $h' <<<"$rustyV8")
    '') (builtins.attrNames rustyV8.assets))
  rustyV8.systems;
in
  (pkgs.codex.override ({inherit rustPlatform;}
    // lib.optionalAttrs (rustyV8.pin != null) {
      librusty_v8 = fetchRustyV8 "librusty_v8" "archive";
      librusty_v8_src_binding = fetchRustyV8 "src_binding" "srcBinding";
    })).overrideAttrs (finalAttrs: prev: {
    pname = "chatgpt-codex";
    # nixpkgs uses buildCommit for src, STABLE_GIT_COMMIT and CODEX_BUILD_COMMIT.
    inherit (sources) buildCommit version;
    cargoHash = sources.cargoHash or lib.fakeHash;
    src = prev.src.override {hash = sources.srcHash or lib.fakeHash;};

    # Keep nixpkgs' layout and voice patches. Modules declare daemon auto-start
    # explicitly, while the binary retains upstream's feature default.
    patches = builtins.filter (patch: baseNameOf patch != "no-daemon_auto_start.patch") prev.patches;
    patchFlags = ["-p1" "--fuzz=0"];

    postInstall =
      (prev.postInstall or "")
      + ''
        (
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        # Cargo also installs the CLI crate's standalone SQLite log viewer.
        rm "$out/bin/logs_client"
        )
      '';

    # nixpkgs' versionCheckHook only requires the version as a substring.
    postInstallCheck =
      (prev.postInstallCheck or "")
      + ''
        (
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        got=$("$out/bin/codex" --version)
        if [ "''${got##* }" != "${finalAttrs.version}" ]; then
          echo "chatgpt-codex: binary reports '$got', sidecar pins ${finalAttrs.version}" >&2
          false
        fi
        )
      '';

    passthru =
      (prev.passthru or {})
      // rustPlatform.passthru
      // {
        # Read by checks/chatgpt-codex-package-layout.nix, so the check asserts
        # the layout this recipe says it produces rather than a copy of it.
        codexPackage = {
          resources = ["codex-resources/voice/bin/codex-voice-host"];
          root = packageRoot;
          target = stdenv.hostPlatform.rust.rustcTarget;
        };
        extractedRules = import ../../../extract/rules.nix {inherit extractedLib pkgs;};
        updateScript = vu.mkUpdateScript {
          inherit pkgs sourcesFile;
          pname = "chatgpt-codex";
          platforms = {};
          versionCheck.cmd = vu.ghLatestVersionCmd {
            inherit pkgs;
            repo = "openai/codex";
            tagPrefix = "rust-v";
          };
          # Resolve the source commit, rusty_v8 pin and dependency hashes.
          extraExtract = ''
            buildCommit=$(
              ${pkgs.git}/bin/git ls-remote --exit-code https://github.com/openai/codex \
                "refs/tags/rust-v$latest" "refs/tags/rust-v$latest^{}" \
                | ${pkgs.gawk}/bin/awk 'NR == 1 {commit = $1} /\^\{\}$/ {commit = $1} END {print commit}'
            )
            if [[ ! "$buildCommit" =~ ^[0-9a-f]{40}$ ]]; then
              echo "chatgpt-codex: no commit for rust-v$latest" >&2
              exit 1
            fi
            v8=$(
              ${pkgs.curl}/bin/curl -fsSL "https://raw.githubusercontent.com/openai/codex/$buildCommit/codex-rs/Cargo.lock" \
                | ${pkgs.gnused}/bin/sed -n '/^name = "v8"$/{n;s/^version = "\(.*\)"$/\1/p;}'
            )
            if [[ ! "$v8" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              echo "chatgpt-codex: no single v8 crate version in Cargo.lock at $buildCommit" >&2
              exit 1
            fi
            rustyV8=$(${pkgs.jq}/bin/jq -n --arg v "$v8" '{version: $v}')
            ${prefetchRustyV8}
            tmp=$(${pkgs.coreutils}/bin/mktemp)
            ${pkgs.jq}/bin/jq --arg commit "$buildCommit" --argjson v8 "$rustyV8" \
              '. + {buildCommit: $commit, librustyV8: $v8}' "${sourcesFile}" > "$tmp"
            ${pkgs.coreutils}/bin/mv "$tmp" "${sourcesFile}"
            ${rustPlatform.passthru.rustUpdateExtract}
          '';
        };
        extracted = pkgs.runCommandLocal "chatgpt-codex-facts-raw" {} (
          vu.mkCodexExtract {
            bin = "${finalAttrs.finalPackage}/bin/codex";
            inherit pkgs;
            dest = "$out";
          }
        );
      };

    meta =
      prev.meta
      // {
        description = "OpenAI Codex CLI — coding agent that runs locally in your terminal";
      };
  })
