# Kiro CLI — pre-built binary from AWS release channel.
# x86_64-linux: tarball from nvfetcher (kiro-cli)
# aarch64-darwin: .dmg from nvfetcher (kiro-cli-darwin), extracted by nixpkgs undmg
#
# Unfree: wrapped by `wrapUnfree` in default.nix so the consumer's
# allowUnfree config is respected. See overlays/README.md.
{
  inputs,
  final,
  nv,
  nv-darwin,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs.stdenv.hostPlatform) system;
  src =
    if system == "x86_64-linux"
    then nv.src
    else if system == "aarch64-darwin"
    then nv-darwin.src
    else throw "kiro-cli: unsupported system ${system}";
  inherit (nv) version;
in
  # Inner build: ourPkgs for cache-hit parity. wrapUnfree in default.nix
  # adds the consumer-facing unfree check on top.
  ourPkgs.kiro-cli.overrideAttrs (attrs: {
    inherit src version;

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
        changelog = builtins.replaceStrings [ourPkgs.kiro-cli.version] [version] ourPkgs.kiro-cli.meta.changelog;
      };
  })
