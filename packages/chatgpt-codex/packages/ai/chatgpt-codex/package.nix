# ChatGPT Codex CLI uses nixpkgs' source build and complete package at $out.
# nixpkgs builds the CLI, code-mode host and voice host with matching commit
# stamps, and supplies store-linked rg, bwrap and the GStreamer runtime.
# This recipe pins the source and cargo hashes and uses the locked Rust toolchain.
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
  rustPlatform = vu.mkRustPlatform {inherit pkgs;};
  packageRoot = (import ../../../lib/packageLayout.nix).root;

  # The updater resolves the release commit, then fixes source and vendor hashes.
  # Fake hashes let the fixer evaluate each candidate before those downloads.
  fixVendorHash = vu.mkHashFix {
    inherit pkgs sourcesFile;
    attr = "chatgpt-codex";
    name = "vendor-hash";
    pname = "chatgpt-codex";
    targets = [
      vu.hashFixTargets.src
      {
        attrPath = "cargoDeps";
        drvPattern = "-vendor";
        key = "cargoHash";
      }
    ];
  };
in
  (pkgs.codex.override {inherit rustPlatform;}).overrideAttrs (finalAttrs: prev: {
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
      // {
        # Read by checks/chatgpt-codex-package-layout.nix, so the check asserts
        # the layout this recipe says it produces rather than a copy of it.
        codexPackage = {
          resources = ["codex-resources/voice/bin/codex-voice-host"];
          root = packageRoot;
          target = stdenv.hostPlatform.rust.rustcTarget;
        };
        extractedRules = import ../../../extract/rules.nix {inherit extractedLib pkgs;};
        # Also discovered by fix_sidecar_hashes after nixpkgs input changes.
        inherit fixVendorHash;
        updateScript = vu.mkUpdateScript {
          inherit pkgs sourcesFile;
          pname = "chatgpt-codex";
          platforms = {};
          versionCheck.cmd = vu.ghLatestVersionCmd {
            inherit pkgs;
            repo = "openai/codex";
            tagPrefix = "rust-v";
          };
          # Resolve the source commit and hashes, then regenerate the
          # committed sidecar from the freshly-bumped binary in the SAME
          # update/chatgpt-codex PR (no intra-PR drift).
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
            tmp=$(${pkgs.coreutils}/bin/mktemp)
            ${pkgs.jq}/bin/jq --arg commit "$buildCommit" '. + {buildCommit: $commit}' \
              "${sourcesFile}" > "$tmp"
            ${pkgs.coreutils}/bin/mv "$tmp" "${sourcesFile}"
            ${fixVendorHash}
            ${(extractedLib {inherit pkgs;}).regenCommand {name = "chatgpt-codex";}}
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
