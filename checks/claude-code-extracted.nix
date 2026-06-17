# Drift check — the committed overlays/claude-code-extracted.json must
# match what the packaged claude binary actually contains. Blocking
# (pins/levels must be exact for correctness). The build of
# passthru.extracted also enforces the non-empty / count==1 hardening
# baked into vu.mkClaudeExtract.
{
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  extracted = self.packages.${system}.claude-code.passthru.extracted;
  committed = ../overlays/claude-code-extracted.json;
in {
  claude-code-extracted = pkgs.runCommand "claude-code-extracted-drift" {} ''
    jq="${pkgs.jq}/bin/jq"
    if "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} \
      '$a == $b' > /dev/null; then
      echo "ok — overlays/claude-code-extracted.json matches the packaged binary" > $out
    else
      echo "FAIL: overlays/claude-code-extracted.json is out of sync with the claude binary." >&2
      echo "--- committed ---" >&2
      "$jq" -S . ${committed} >&2
      echo "--- extracted from binary ---" >&2
      "$jq" -S . ${extracted} >&2
      echo "" >&2
      echo "Regenerate: nix build .#claude-code.passthru.extracted --no-link --print-out-paths" >&2
      echo "then cp the result over overlays/claude-code-extracted.json and 'git add' it." >&2
      exit 1
    fi
  '';
}
