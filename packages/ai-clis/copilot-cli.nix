# GitHub Copilot CLI — pre-built binary from GitHub releases.
{
  final,
  prev,
  nv,
}: let
  src = final.fetchurl {
    url = "https://github.com/github/copilot-cli/releases/download/v${nv.version}/copilot-linux-x64.tar.gz";
    hash = nv.src.outputHash;
  };
in
  prev.github-copilot-cli.overrideAttrs (_: {
    inherit src;
    inherit (nv) version;
  })
