# Claude Code — pre-built binary from Anthropic's GPG-signed manifest.
# Per-platform sources in claude-code-sources.json, managed by updateScript.
#
# This is the raw package. The HM module adds the buddy wrapper on
# top for users who configure buddy salt patching.
#
# Unfree: wrapped by `ensureUnfreeCheck` in default.nix.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs) autoPatchelfHook fetchurl lib stdenv writeShellScript;

  manifestBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";

  sources = builtins.fromJSON (builtins.readFile ./claude-code-sources.json);
  platformSrc = sources.${stdenv.hostPlatform.system} or (throw "claude-code: unsupported system ${stdenv.hostPlatform.system}");
in
  stdenv.mkDerivation {
    pname = "claude-code";
    inherit (sources) version;
    src = fetchurl {inherit (platformSrc) url hash;};
    dontUnpack = true;
    dontBuild = true;
    nativeBuildInputs =
      lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      ourPkgs.glibc
    ];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -Dm755 $src $out/bin/claude
      runHook postInstall
    '';
    passthru.updateScript = writeShellScript "update-claude-code" ''
      set -eu
      latest=$(${ourPkgs.curl}/bin/curl -s "${manifestBase}/latest")
      [ -z "$latest" ] && echo "Failed to fetch latest version" >&2 && exit 1

      sources="overlays/claude-code-sources.json"
      current=$(${ourPkgs.jq}/bin/jq -r '.version' "$sources")
      if [ "$latest" = "$current" ]; then
        echo "claude-code: already at $current"
        exit 0
      fi

      echo "claude-code: $current -> $latest"
      tmp=$(mktemp)
      ${ourPkgs.jq}/bin/jq -n --arg v "$latest" '{version: $v}' > "$tmp"

      for platform in x86_64-linux aarch64-darwin; do
        case "$platform" in
          x86_64-linux) key="linux-x64" ;;
          aarch64-darwin) key="darwin-arm64" ;;
        esac
        url="${manifestBase}/''${latest}/''${key}/claude"
        hash=$(${ourPkgs.nix}/bin/nix hash convert --to sri --hash-algo sha256 \
          "$(${ourPkgs.nix}/bin/nix-prefetch-url --type sha256 "$url" 2>/dev/null)")
        ${ourPkgs.jq}/bin/jq --arg sys "$platform" --arg u "$url" --arg h "$hash" \
          '. + {($sys): {url: $u, hash: $h}}' "$tmp" > "''${tmp}.new" && mv "''${tmp}.new" "$tmp"
      done

      mv "$tmp" "$sources"
      echo "Updated $sources"
    '';
    meta = {
      mainProgram = "claude";
      license = lib.licenses.unfree;
      description = "Anthropic's Claude Code CLI";
    };
  }
