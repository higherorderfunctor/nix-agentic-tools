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
  inherit (ourPkgs) fetchurl writeShellScript;
  inherit (ourPkgs.stdenv.hostPlatform) system;

  sources = builtins.fromJSON (builtins.readFile ./copilot-cli-sources.json);
  platformSrc = sources.${system} or (throw "copilot-cli: unsupported system ${system}");
in
  ourPkgs.github-copilot-cli.overrideAttrs (_: {
    inherit (sources) version;
    src = fetchurl {inherit (platformSrc) url hash;};

    passthru.updateScript = writeShellScript "update-copilot-cli" ''
      set -eu
      latest=$(${ourPkgs.curl}/bin/curl -s https://api.github.com/repos/github/copilot-cli/releases/latest \
        | ${ourPkgs.jq}/bin/jq -r '.tag_name | ltrimstr("v")')
      [ -z "$latest" ] && echo "Failed to fetch latest version" >&2 && exit 1

      sources="overlays/copilot-cli-sources.json"
      current=$(${ourPkgs.jq}/bin/jq -r '.version' "$sources")
      if [ "$latest" = "$current" ]; then
        echo "copilot-cli: already at $current"
        exit 0
      fi

      echo "copilot-cli: $current -> $latest"
      tmp=$(mktemp)
      ${ourPkgs.jq}/bin/jq -n --arg v "$latest" '{version: $v}' > "$tmp"

      for platform in x86_64-linux aarch64-darwin; do
        case "$platform" in
          x86_64-linux) name="copilot-linux-x64" ;;
          aarch64-darwin) name="copilot-darwin-arm64" ;;
        esac
        url="https://github.com/github/copilot-cli/releases/download/v''${latest}/''${name}.tar.gz"
        hash=$(nix hash convert --to sri --hash-algo sha256 \
          "$(nix-prefetch-url --type sha256 "$url" 2>/dev/null)")
        ${ourPkgs.jq}/bin/jq --arg sys "$platform" --arg u "$url" --arg h "$hash" \
          '. + {($sys): {url: $u, hash: $h}}' "$tmp" > "''${tmp}.new" && mv "''${tmp}.new" "$tmp"
      done

      mv "$tmp" "$sources"
      echo "Updated $sources"
    '';
  })
