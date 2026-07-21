# Drift check — the committed overlays/kiro-cli-extracted.json must match what
# the packaged kiro binary actually contains (the probed trigger vocabulary).
# Blocking (a typed trigger vanishing, or a documented-absent one becoming
# present, is a correctness signal the typed surface must react to). Mirrors
# checks/claude-code-extracted.nix; the build of passthru.extracted also enforces
# the fail-loud (>=1 present) guard baked into vu.mkKiroExtract.
{
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  extracted = self.packages.${system}.kiro-cli.passthru.extracted;
  committed = ../overlays/kiro-cli-extracted.json;
in {
  kiro-cli-extracted = pkgs.runCommand "kiro-cli-extracted-drift" {} ''
    jq="${pkgs.jq}/bin/jq"
    if "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} \
      '$a == $b' > /dev/null; then
      echo "ok — overlays/kiro-cli-extracted.json matches the packaged kiro binary" > $out
    else
      echo "FAIL: overlays/kiro-cli-extracted.json is out of sync with the kiro binary." >&2
      echo "--- committed ---" >&2
      "$jq" -S . ${committed} >&2
      echo "--- extracted from binary ---" >&2
      "$jq" -S . ${extracted} >&2
      echo "" >&2
      echo "Regenerate: nix build .#kiro-cli.passthru.extracted --no-link --print-out-paths" >&2
      echo "then cp the result over overlays/kiro-cli-extracted.json, 'nix fmt' it, and 'git add'." >&2
      exit 1
    fi
  '';
}
