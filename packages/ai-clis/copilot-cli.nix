# GitHub Copilot CLI — pre-built binary from GitHub releases.
# Platform-specific tarballs: copilot-{linux-x64,darwin-arm64}.tar.gz
{
  final,
  prev,
  nv,
}: let
  platformMap = {
    "x86_64-linux" = "linux-x64";
    "aarch64-darwin" = "darwin-arm64";
  };
  inherit (final.stdenv.hostPlatform) system;
  suffix =
    platformMap.${system}
    or (throw "copilot-cli: unsupported system ${system}");
  src = final.fetchurl {
    url = "https://github.com/github/copilot-cli/releases/download/v${nv.version}/copilot-${suffix}.tar.gz";
    hash =
      nv.${system}
      or (throw "copilot-cli: no hash for ${system}");
  };
in
  prev.github-copilot-cli.overrideAttrs (_: {
    inherit src;
    inherit (nv) version;
  })
