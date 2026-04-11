# Kiro CLI — override nixpkgs with nightly version.
# Per-platform sources in kiro-cli-sources.json, managed by updateScript.
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
  inherit (ourPkgs) fetchurl makeWrapper writeShellScript;
  inherit (ourPkgs.stdenv.hostPlatform) system;

  sources = builtins.fromJSON (builtins.readFile ./kiro-cli-sources.json);
  platformSrc = sources.${system} or (throw "kiro-cli: unsupported system ${system}");
in
  ourPkgs.kiro-cli.overrideAttrs (attrs: {
    inherit (sources) version;
    src = fetchurl {inherit (platformSrc) url hash;};

    nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [makeWrapper];

    postFixup =
      (attrs.postFixup or "")
      + ''
        wrapProgram $out/bin/kiro-cli --set-default TERM xterm-256color
        wrapProgram $out/bin/kiro-cli-chat --set-default TERM xterm-256color
      '';

    passthru.updateScript = writeShellScript "update-kiro-cli" ''
      set -eu
      latest=$(${ourPkgs.curl}/bin/curl -s \
        https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json \
        | ${ourPkgs.jq}/bin/jq -r '.version')
      [ -z "$latest" ] && echo "Failed to fetch latest version" >&2 && exit 1

      sources="overlays/kiro-cli-sources.json"
      current=$(${ourPkgs.jq}/bin/jq -r '.version' "$sources")
      if [ "$latest" = "$current" ]; then
        echo "kiro-cli: already at $current"
        exit 0
      fi

      echo "kiro-cli: $current -> $latest"
      tmp=$(mktemp)
      ${ourPkgs.jq}/bin/jq -n --arg v "$latest" '{version: $v}' > "$tmp"

      for platform in x86_64-linux aarch64-darwin; do
        case "$platform" in
          x86_64-linux) url="https://desktop-release.q.us-east-1.amazonaws.com/''${latest}/kirocli-x86_64-linux.tar.gz" ;;
          aarch64-darwin) url="https://desktop-release.q.us-east-1.amazonaws.com/''${latest}/Kiro%20CLI.dmg" ;;
        esac
        hash=$(nix hash convert --to sri --hash-algo sha256 \
          "$(nix-prefetch-url --type sha256 "$url" 2>/dev/null)")
        ${ourPkgs.jq}/bin/jq --arg sys "$platform" --arg u "$url" --arg h "$hash" \
          '. + {($sys): {url: $u, hash: $h}}' "$tmp" > "''${tmp}.new" && mv "''${tmp}.new" "$tmp"
      done

      mv "$tmp" "$sources"
      echo "Updated $sources"
    '';
  })
