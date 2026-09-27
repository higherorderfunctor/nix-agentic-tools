# ChatGPT Codex CLI — standalone derivation against upstream's per-platform
# COMPLETE PACKAGE release tarballs.
#
# openai/codex tags Rust releases `rust-v<version>` (the repo also cuts
# unrelated tags, hence `tagPrefix = "rust-v"` on the version check) and
# publishes each platform twice: loose per-binary archives
# (`codex-<target>.tar.gz`, `codex-code-mode-host-<target>.tar.gz`, …) and one
# `codex-package-<target>.tar.gz` holding the whole runtime package:
#
#   codex-package.json      {layoutVersion, version, target, entrypoint, …}
#   bin/codex               the CLI
#   bin/codex-code-mode-host
#   codex-path/rg           prepended to PATH for spawned commands
#   codex-resources/        bwrap (Linux), zsh, voice runtime
#
# We install the complete package, verbatim, as `$out/libexec/codex`. Codex
# finds its package by resolving its OWN executable: `bin/codex` must sit
# in a directory named `bin` whose parent holds `codex-package.json`
# (codex-rs/install-context). Since 0.157.0 `daemon_auto_start` is on by
# default, and the daemon bootstrap (codex-rs/app-server-daemon,
# prepare_install.rs) copies that package into
# `$CODEX_HOME/packages/app-server-daemon/` before it will start. The loose
# binaries carry no manifest, so a Codex installed from them dies at launch
# with "this CLI has no complete local package". The copy also rejects any
# symlink that leaves the package root, so every file under it must be a real
# file: nothing in there may point at another store path.
#
# `$out/bin/{codex,codex-code-mode-host}` are relative symlinks into the
# package. Exec resolves them, so `current_exe` (and the launcher's
# `.codex-wrapped` link) lands on the real `libexec/codex/bin/codex`.
#
# The CLI, code-mode host, rg and bwrap are static (musl on Linux) and are
# left byte-for-byte as shipped: codex verifies the bundled bwrap against a
# digest compiled into the CLI, and the daemon checks the copied `bin/codex`
# against the running executable. Only the glibc-linked optional resources
# (zsh, the voice host and its bundled GStreamer) are repointed at the nix
# glibc, and only on Linux.
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
  inherit (ourPkgs) fetchurl lib stdenv;
  inherit (stdenv.hostPlatform) isLinux system;
  vu = packageLib // import ../../../lib/packaging.nix;

  sources = builtins.fromJSON (builtins.readFile ../../../sources.json);
  platformSrc = sources.${system} or (throw "chatgpt-codex: unsupported system ${system}");

  # Nix system -> upstream Rust target: names the release asset and is what
  # `codex-package.json` records as `target`.
  targets = {
    "aarch64-darwin" = "aarch64-apple-darwin";
    "x86_64-linux" = "x86_64-unknown-linux-musl";
  };
  packageRoot = (import ../../../lib/packageLayout.nix).root;

  # The glibc-linked resources that get their interpreter and rpath patched.
  # Everything else in the package is static and must stay untouched.
  patchedResourceDirs =
    lib.concatMapStringsSep " " (r: "$out/${packageRoot}/codex-resources/${r}") ["voice" "zsh"];
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "chatgpt-codex";
    inherit (sources) version;
    src = fetchurl {inherit (platformSrc) url hash;};

    # The archive has no wrapper directory: bin/, codex-package.json,
    # codex-path/ and codex-resources/ sit at its root.
    sourceRoot = ".";
    dontStrip = true;
    # Generic ELF rewriting would touch the static binaries the header says
    # must stay as shipped; the autoPatchelf call below is scoped instead.
    dontAutoPatchelf = true;
    dontPatchELF = true;

    nativeBuildInputs = lib.optionals isLinux [ourPkgs.autoPatchelfHook];
    # zsh needs libtinfo; the voice host brings its own GStreamer and glib and
    # needs nothing else beyond glibc.
    buildInputs = lib.optionals isLinux [ourPkgs.ncurses];

    installPhase = ''
      runHook preInstall
      mkdir -p $out/${packageRoot} $out/bin
      cp -R bin codex-package.json codex-path codex-resources $out/${packageRoot}/
      for exe in codex codex-code-mode-host; do
        ln -s ../${packageRoot}/bin/$exe $out/bin/$exe
      done
      runHook postInstall
    '';

    # The archive ships the voice libraries read-only; patchelf rewrites in
    # place.
    postFixup = lib.optionalString isLinux ''
      chmod -R u+w ${patchedResourceDirs}
      autoPatchelf ${patchedResourceDirs}
    '';

    # Smoke test only. The package-layout contract Codex enforces at runtime
    # is asserted by checks/chatgpt-codex-package-layout.nix.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      $out/bin/codex --version
      runHook postInstallCheck
    '';

    passthru = {
      # Read by checks/chatgpt-codex-package-layout.nix, so the check asserts
      # the layout this recipe says it produces rather than a copy of it.
      codexPackage = {
        root = packageRoot;
        target = targets.${system};
      };
      updateScript = vu.mkUpdateScript {
        sourcesFile = repoPath ../../../sources.json;

        pname = "chatgpt-codex";
        versionCheck.cmd = vu.ghLatestVersionCmd {
          pkgs = ourPkgs;
          repo = "openai/codex";
          tagPrefix = "rust-v";
        };
        # ONE asset per platform: the complete package carries the CLI and
        # the code-mode host together, so they cannot drift apart on a bump.
        platforms =
          lib.mapAttrs (
            _: target: ver: "https://github.com/openai/codex/releases/download/rust-v${ver}/codex-package-${target}.tar.gz"
          )
          targets;
        # Regenerate the committed sidecar from the freshly-bumped binary
        # in the SAME update/chatgpt-codex PR (no intra-PR drift).
        extraExtract = vu.mkExtractRegen {
          attr = "chatgpt-codex";
          dest = repoPath ../../../extracted.json;
          pkgs = ourPkgs;
        };
        pkgs = ourPkgs;
      };
      extracted = ourPkgs.runCommandLocal "chatgpt-codex-extracted.json" {} (
        vu.mkCodexExtract {
          bin = "${finalAttrs.finalPackage}/bin/codex";
          pkgs = ourPkgs;
          inherit (sources) version;
          dest = "$out";
        }
      );
    };

    meta = {
      description = "OpenAI Codex CLI — coding agent that runs locally in your terminal";
      homepage = "https://github.com/openai/codex";
      license = lib.licenses.asl20;
      platforms = builtins.attrNames (builtins.removeAttrs sources ["version"]);
      mainProgram = "codex";
    };
  })
