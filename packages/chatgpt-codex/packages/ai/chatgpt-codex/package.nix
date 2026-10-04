# ChatGPT Codex CLI — nixpkgs' source-built `codex`, compiled with this
# repo's locked Rust platform at the version, source and cargo hashes in
# ../../../sources.json, and installed as upstream's COMPLETE PACKAGE.
#
# nixpkgs owns the build: cargo flags (codex-cli + codex-code-mode-host), the
# postPatch, the prebuilt V8 library, the env and the shell completions. We move only the
# pins, which overrideAttrs has to carry because nixpkgs' version is not an
# argument, and the install layout our package contract needs.
#
# THE COMPLETE PACKAGE. Codex finds its package by resolving its OWN
# executable: `bin/codex` must sit in a directory named `bin` whose parent
# holds `codex-package.json` (codex-rs/install-context). Since 0.157.0
# upstream turns `daemon_auto_start` on by default, and the daemon bootstrap
# (codex-rs/app-server-daemon, prepare_install.rs) refuses to start unless
# that package exists, its `target` equals the running platform's, and it
# carries `bin/codex`, `bin/codex-code-mode-host`, `codex-path/rg` and, on
# Linux, `codex-resources/bwrap`. It then copies the package into
# `$CODEX_HOME/packages/app-server-daemon/` and rejects any symlink that
# leaves the package root, so every file under it is a real file. postInstall
# assembles that layout the way upstream's scripts/codex_package/layout.py
# does, from this build plus nixpkgs' ripgrep and bubblewrap, under
# `$out/libexec/codex`; `$out/bin/{codex,codex-code-mode-host}` are relative
# symlinks into it, so `current_exe` lands on the real
# `libexec/codex/bin/codex`.
#
# NOT BUILT: the optional `codex-resources/zsh` (upstream fetches a prebuilt
# zsh fork) and `codex-resources/voice` (a Bazel-built GStreamer runtime).
# Upstream's own packager treats zsh as optional and assembles voice outside
# it. The bundled-bwrap digest check is compiled in only when
# CODEX_BWRAP_SHA256 is set at build time, which this build does not set.
#
# Prebuilt-release history (musl tarball, voice/zsh autoPatchelf):
# `git show f38b946f:packages/chatgpt-codex/packages/ai/chatgpt-codex/package.nix`.
{
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) lib stdenv;
  inherit (stdenv.hostPlatform) isLinux;
  vu = packageLib // import ../../../lib/packaging.nix;

  sources = builtins.fromJSON (builtins.readFile ../../../sources.json);
  sourcesFile = repoPath ../../../sources.json;
  rustPlatform = vu.mkRustPlatform {inherit pkgs;};
  packageRoot = (import ../../../lib/packageLayout.nix).root;
  # What the daemon's `platform_target()` reports for this build, and so what
  # `codex-package.json` must record: x86_64-unknown-linux-gnu for this glibc
  # build, aarch64-apple-darwin on darwin.
  target = stdenv.hostPlatform.rust.rustcTarget;
  manifest = builtins.toJSON {
    entrypoint = "bin/codex";
    layoutVersion = 1;
    pathDir = "codex-path";
    resourcesDir = "codex-resources";
    inherit target;
    variant = "codex";
    inherit (sources) version;
  };

  # mkUpdateScript writes a version-only candidate; fake hashes let the fixer
  # evaluate it, then restore source before deriving its cargo vendor tree.
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
    # prev.src already reads its tag from finalAttrs.version.
    inherit (sources) version;
    src = prev.src.override {hash = sources.srcHash or lib.fakeHash;};
    # buildRustPackage derives cargoDeps from its ARGUMENT cargoHash, which
    # overrideAttrs cannot reach, so the vendor tree is restated over the
    # final source with the locked platform's fetcher.
    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname src sourceRoot version;
      hash = sources.cargoHash or lib.fakeHash;
    };

    # nixpkgs patches daemon_auto_start's built-in default to false. Our
    # modules write that setting explicitly, and extracted.json records the
    # binary's own feature defaults, so the binary keeps upstream's.
    patches = [];

    postInstall =
      (prev.postInstall or "")
      + ''
        (
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        root=$out/${packageRoot}
        mkdir -p "$root/bin" "$root/codex-path" "$root/codex-resources"
        for exe in codex codex-code-mode-host; do
          mv "$out/bin/$exe" "$root/bin/$exe"
          ln -s "../${packageRoot}/bin/$exe" "$out/bin/$exe"
        done
        install -m755 ${lib.getExe pkgs.ripgrep} "$root/codex-path/rg"
        ${lib.optionalString isLinux ''install -m755 ${lib.getExe pkgs.bubblewrap} "$root/codex-resources/bwrap"''}
        printf '%s\n' ${lib.escapeShellArg manifest} > "$root/codex-package.json"
        )
      '';

    # nixpkgs wraps bin/codex to put ripgrep and bubblewrap on PATH. The
    # package carries both itself, and a wrapper would replace the symlink
    # into it.
    postFixup = "";

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
          root = packageRoot;
          inherit target;
        };
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
          # Restore the source and vendor hashes, then regenerate the
          # committed sidecar from the freshly-bumped binary in the SAME
          # update/chatgpt-codex PR (no intra-PR drift).
          extraExtract = ''
            ${fixVendorHash}
            ${vu.mkExtractRegen {
              attr = "chatgpt-codex";
              dest = repoPath ../../../extracted.json;
              inherit pkgs;
            }}
          '';
        };
        extracted = pkgs.runCommandLocal "chatgpt-codex-extracted.json" {} (
          vu.mkCodexExtract {
            bin = "${finalAttrs.finalPackage}/bin/codex";
            inherit pkgs;
            inherit (sources) version;
            dest = "$out";
          }
        );
      };
  })
