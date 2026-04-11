# Kiro CLI — pre-built binary from AWS release channel.
# Per-platform inline sources with hashes.
#
# Unfree: wrapped by ensureUnfreeCheck in default.nix so the consumer's
# allowUnfree config is respected.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs) fetchurl;
  inherit (ourPkgs.stdenv.hostPlatform) system;
  version = "1.29.6";
  platformSrc = {
    "x86_64-linux" = {
      inherit version;
      src = fetchurl {
        url = "https://desktop-release.q.us-east-1.amazonaws.com/${version}/kirocli-x86_64-linux.tar.gz";
        hash = "sha256-6FZgHdKBDz8zrrJf0MgGtzKz279j4X3H/B6tW+0WlZ8=";
      };
    };
    "aarch64-darwin" = {
      inherit version;
      src = fetchurl {
        url = "https://desktop-release.q.us-east-1.amazonaws.com/${version}/Kiro%20CLI.dmg";
        name = "kiro-cli.dmg";
        hash = "sha256-qe9svpw3ngk9EU12woeMXW8+gTNYxGfzdePVUgodUWY=";
      };
    };
  };
  nv = platformSrc.${system} or (throw "kiro-cli: unsupported system ${system}");
in
  ourPkgs.kiro-cli.overrideAttrs (attrs: {
    inherit (nv) src version;

    nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [ourPkgs.makeWrapper];

    postFixup =
      (attrs.postFixup or "")
      + ''
        wrapProgram $out/bin/kiro-cli --set-default TERM xterm-256color
        wrapProgram $out/bin/kiro-cli-chat --set-default TERM xterm-256color
      '';

    meta =
      ourPkgs.kiro-cli.meta
      // {
        changelog = builtins.replaceStrings [ourPkgs.kiro-cli.version] [nv.version] ourPkgs.kiro-cli.meta.changelog;
      };
  })
