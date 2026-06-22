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
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs) fetchurl lib autoPatchelfHook stdenv;
  inherit (ourPkgs.stdenv.hostPlatform) system;
  vu = import ./lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./kimchi-sources.json);
  platformSrc = sources.${system} or (throw "kimchi: unsupported system ${system}");
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
      updateScript = vu.mkUpdateScript {
        pname = "kimchi";
        versionCheck.cmd = "${ourPkgs.curl}/bin/curl -s https://api.github.com/repos/getkimchi/kimchi/releases/latest | ${ourPkgs.jq}/bin/jq -r '.tag_name | ltrimstr(\"v\")'";
        platforms = {
          "x86_64-linux" = ver: "https://github.com/getkimchi/kimchi/releases/download/v${ver}/kimchi_linux_amd64.tar.gz";
          "aarch64-darwin" = ver: "https://github.com/getkimchi/kimchi/releases/download/v${ver}/kimchi_darwin_arm64.tar.gz";
        };
        pkgs = ourPkgs;
      };
    };

    meta = {
      description = "Kimchi — coding agent CLI powered by Cast AI";
      homepage = "https://github.com/getkimchi/kimchi";
      license = lib.licenses.asl20;
      platforms = builtins.attrNames (builtins.removeAttrs sources ["version"]);
      mainProgram = "kimchi";
    };
  }
