# Kiro CLI — pre-built binary from AWS release channel.
# Per-platform nvfetcher entries: kiro-cli-linux-x64, kiro-cli-darwin-arm64.
#
# Unfree: wrapped by ensureUnfreeCheck in default.nix so the consumer's
# allowUnfree config is respected.
{
  inputs,
  final,
  nv-linux-x64,
  nv-darwin-arm64,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs.stdenv.hostPlatform) system;
  platformSrc = {
    "x86_64-linux" = nv-linux-x64;
    "aarch64-darwin" = nv-darwin-arm64;
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
