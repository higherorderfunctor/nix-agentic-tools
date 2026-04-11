# GitHub Copilot CLI — override nixpkgs with nightly version.
# Per-platform sources in copilot-cli-sources.json, managed by updateScript.
#
# Unfree (proprietary). ensureUnfreeCheck in default.nix wraps the
# output so the consumer's allowUnfree config is respected.
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
  vu = import ./lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./copilot-cli-sources.json);
  platformSrc = sources.${system} or (throw "copilot-cli: unsupported system ${system}");
in
  ourPkgs.github-copilot-cli.overrideAttrs (_: {
    inherit (sources) version;
    src = fetchurl {inherit (platformSrc) url hash;};

    passthru.updateScript = vu.mkUpdateScript {
      pname = "copilot-cli";
      versionCheck.cmd = "${ourPkgs.curl}/bin/curl -s https://api.github.com/repos/github/copilot-cli/releases/latest | ${ourPkgs.jq}/bin/jq -r '.tag_name | ltrimstr(\"v\")'";
      platforms = {
        "x86_64-linux" = ver: "https://github.com/github/copilot-cli/releases/download/v${ver}/copilot-linux-x64.tar.gz";
        "aarch64-darwin" = ver: "https://github.com/github/copilot-cli/releases/download/v${ver}/copilot-darwin-arm64.tar.gz";
      };
      pkgs = ourPkgs;
    };
  })
