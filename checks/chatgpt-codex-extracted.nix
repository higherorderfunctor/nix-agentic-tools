# Drift check — the committed Codex sidecar must match the deterministic CLI
# help, feature list, and bundled model catalog exposed by the packaged binary.
{
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  extracted = self.packages.${system}.chatgpt-codex.passthru.extracted;
  committed = ../overlays/chatgpt-codex-extracted.json;
in {
  chatgpt-codex-extracted = pkgs.runCommand "chatgpt-codex-extracted-drift" {} ''
    jq="${pkgs.jq}/bin/jq"
    if "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} \
      '$a == $b' > /dev/null; then
      echo "ok — overlays/chatgpt-codex-extracted.json matches the packaged binary" > $out
    else
      echo "FAIL: overlays/chatgpt-codex-extracted.json is out of sync with the Codex binary." >&2
      echo "--- committed ---" >&2
      "$jq" -S . ${committed} >&2
      echo "--- extracted from binary ---" >&2
      "$jq" -S . ${extracted} >&2
      echo "" >&2
      echo "Regenerate: nix build .#chatgpt-codex.passthru.extracted --no-link --print-out-paths" >&2
      echo "then copy the result over overlays/chatgpt-codex-extracted.json, format it, and git add it." >&2
      exit 1
    fi
  '';
}
