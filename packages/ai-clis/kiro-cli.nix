# Kiro CLI — pre-built binary from AWS release channel.
# x86_64-linux: tarball from nvfetcher (kiro-cli)
# aarch64-darwin: .dmg from nvfetcher (kiro-cli-darwin), extracted by nixpkgs undmg
{
  final,
  prev,
  nv,
  nv-darwin,
}: let
  inherit (final.stdenv.hostPlatform) system;
  src =
    if system == "x86_64-linux"
    then nv.src
    else if system == "aarch64-darwin"
    then nv-darwin.src
    else throw "kiro-cli: unsupported system ${system}";
  inherit (nv) version;
in
  prev.kiro-cli.overrideAttrs (attrs: {
    inherit src version;

    nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [final.makeWrapper];

    postFixup =
      (attrs.postFixup or "")
      + ''
        wrapProgram $out/bin/kiro-cli --set TERM xterm-256color
        wrapProgram $out/bin/kiro-cli-chat --set TERM xterm-256color
      '';

    meta =
      prev.kiro-cli.meta
      // {
        changelog = builtins.replaceStrings [prev.kiro-cli.version] [version] prev.kiro-cli.meta.changelog;
      };
  })
