# ChatGPT Codex CLI — nixpkgs' source-built `codex`, compiled with this
# repo's locked Rust platform at the version, source and cargo hashes in
# ../../../sources.json, and installed as upstream's COMPLETE PACKAGE with
# the two optional resources taken from upstream's release.
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
# rg and bwrap. rg is looked up in the package's `codex-path` first, then on
# PATH. bwrap is looked up on PATH first; the bundled copy is the fallback, and
# `validate_package` requires it on Linux either way. The bundled-bwrap digest
# check is compiled in only when CODEX_BWRAP_SHA256 is set at build time, which
# this build does not set. So no PATH wrapper is needed, and none is added.
#
# PREBUILT RESOURCES. The optional `codex-resources/zsh` (upstream's patched
# zsh fork) and `codex-resources/voice` (the voice host plus its private
# GStreamer runtime) are not built here: upstream fetches the first prebuilt
# and builds the second with Bazel outside cargo. They are extracted from the
# same release's `codex-package-<target>.tar.gz`, pinned per platform in the
# sidecar; both platforms' archives carry both. They go in during postFixup, so
# strip and the ELF shrinker never see them: stripping would break the macOS
# code signatures. On Linux they are glibc-linked, so a scoped autoPatchelf
# repoints their interpreter and rpath at the nix glibc; the source-built
# binaries are left alone. The voice `manifest.json` lists upstream's digests,
# including its own `bin/codex`; codex does not check them at runtime.
#
# Fully prebuilt history (musl tarball installed verbatim):
# `git show f38b946f:packages/chatgpt-codex/packages/ai/chatgpt-codex/package.nix`.
{
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) lib stdenv;
  inherit (stdenv.hostPlatform) isLinux system;
  vu = packageLib // import ../../../lib/packaging.nix;

  sources = builtins.fromJSON (builtins.readFile ../../../sources.json);
  sourcesFile = repoPath ../../../sources.json;
  rustPlatform = vu.mkRustPlatform {inherit pkgs;};
  packageRoot = (import ../../../lib/packageLayout.nix).root;

  # Nix system -> the Rust target naming upstream's release archive. Only the
  # resources come from it, so this is not the package's `target` below.
  releaseTargets = {
    "aarch64-darwin" = "aarch64-apple-darwin";
    "x86_64-linux" = "x86_64-unknown-linux-musl";
  };
  releaseArchive = pkgs.fetchurl {
    inherit (sources.${system} or (throw "chatgpt-codex: no release archive pinned for ${system}")) url hash;
  };
  # Present in both platforms' archives.
  resourceDirs = map (r: "codex-resources/${r}") ["voice" "zsh"];
  resourcePaths = lib.concatMapStringsSep " " (d: ''"$out/${packageRoot}/${d}"'') resourceDirs;
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

  # mkUpdateScript writes a candidate with the version and the release archive
  # pins only; fake hashes let the fixer evaluate it, then restore source
  # before deriving its cargo vendor tree.
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
    # prev.src already reads its tag from finalAttrs.version.
    inherit (sources) version;
    src = prev.src.override {hash = sources.srcHash or lib.fakeHash;};
    # buildRustPackage derives cargoDeps from its ARGUMENT cargoHash, which
    # overrideAttrs cannot reach, so the vendor tree is restated over the
    # final source with the locked platform's fetcher. It forwards the same
    # optional attributes buildRustPackage's own call does, so a cargoRoot or
    # unpack hook nixpkgs adds later still reaches the vendor tree.
    cargoDeps = rustPlatform.fetchCargoVendor (
      lib.getAttrs (lib.intersectLists [
        "cargoRoot"
        "name"
        "pname"
        "postUnpack"
        "preUnpack"
        "sourceRoot"
        "src"
        "srcs"
        "unpackPhase"
        "version"
      ] (lib.attrNames finalAttrs))
      finalAttrs
      // {
        patches = finalAttrs.cargoPatches or [];
        hash = sources.cargoHash or lib.fakeHash;
      }
    );

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

    nativeBuildInputs = prev.nativeBuildInputs ++ lib.optional isLinux pkgs.autoPatchelfHook;
    # The hook is only for the scoped call below.
    dontAutoPatchelf = true;

    # Replaces nixpkgs' postFixup, which wraps bin/codex to put ripgrep and
    # bubblewrap on PATH: the package carries both itself, and a wrapper would
    # replace the symlink into it. Real files, copied out of the archive.
    postFixup = ''
      (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      tar -xzf ${releaseArchive} -C "$out/${packageRoot}" ${lib.escapeShellArgs resourceDirs}
      ${lib.optionalString isLinux ''
        # The archive ships the voice libraries read-only; patchelf rewrites
        # in place. zsh needs libtinfo; the voice host brings its own
        # GStreamer and glib and needs nothing beyond glibc.
        chmod -R u+w ${resourcePaths}
        addAutoPatchelfSearchPath ${lib.getLib pkgs.ncurses}/lib
        autoPatchelf ${resourcePaths}
      ''}
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
          # The prebuilt resources' entrypoints, relative to `root`.
          resources = ["codex-resources/voice/bin/codex-voice-host" "codex-resources/zsh/bin/zsh"];
          root = packageRoot;
          inherit target;
        };
        # Also discovered by fix_sidecar_hashes after nixpkgs input changes.
        inherit fixVendorHash;
        updateScript = vu.mkUpdateScript {
          inherit pkgs sourcesFile;
          pname = "chatgpt-codex";
          # One archive per platform, for the prebuilt resources. Its entries
          # replace the sidecar, so the fixer below restores srcHash and
          # cargoHash afterwards.
          platforms =
            lib.mapAttrs (
              _: target: ver: "https://github.com/openai/codex/releases/download/rust-v${ver}/codex-package-${target}.tar.gz"
            )
            releaseTargets;
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

    meta =
      prev.meta
      // {
        description = "OpenAI Codex CLI — coding agent that runs locally in your terminal";
        # The systems with a pinned release archive.
        platforms = builtins.attrNames releaseTargets;
      };
  })
