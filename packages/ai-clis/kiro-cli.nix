# Kiro CLI — pre-built binary from AWS release channel.
# x86_64-linux: tarball from nvfetcher (kiro-cli)
# aarch64-darwin: .dmg from nvfetcher (kiro-cli-darwin), extracted by nixpkgs undmg
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so the base derivation
# (kiro-cli) and every build input (makeWrapper) route through this
# repo's pinned nixpkgs instead of the consumer's. This is what gives
# the store path cache-hit parity against CI's standalone build —
# see dev/fragments/overlays/overlay-pattern.md
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
  ourPkgs.kiro-cli.overrideAttrs (attrs: {
    inherit src version;

    nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [ourPkgs.makeWrapper];

    postFixup =
      (attrs.postFixup or "")
      + ''
        wrapProgram $out/bin/kiro-cli --set TERM xterm-256color
        wrapProgram $out/bin/kiro-cli-chat --set TERM xterm-256color
      '';

    meta =
      ourPkgs.kiro-cli.meta
      // {
        changelog = builtins.replaceStrings [ourPkgs.kiro-cli.version] [version] ourPkgs.kiro-cli.meta.changelog;
      };
  })
