# Drift check — the committed overlays/generic/glab-extracted.json must
# match the config-key schema the packaged glab source actually declares.
# Same contract as checks/claude-code-extracted.nix and
# checks/kiro-cli-extracted.nix.
#
# Blocking: the HM/devenv modules generate their typed `settings` options
# from the committed sidecar, so a stale one means an option surface that
# silently disagrees with the binary — the failure mode the extraction
# exists to prevent.
#
# This check catches STALENESS only. It cannot catch a WRONG extract: the
# update pipeline regenerates the sidecar inside the same version-bump PR,
# so a bad extract is committed as the new truth and this goes green over
# it. Correctness is the job of the shape guards inside
# `passthru.extracted` (see overlays/generic/glab.nix) — the scope/key/
# env-var assertions, and the Go dump's panic on an unknown Scope or
# ValueType constant.
{
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  extracted = self.packages.${system}.glab.passthru.extracted;
  committed = ../overlays/generic/glab-extracted.json;
in {
  glab-extracted = pkgs.runCommand "glab-extracted-drift" {} ''
    jq="${pkgs.jq}/bin/jq"
    if "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} \
      '$a == $b' > /dev/null; then
      echo "ok — overlays/generic/glab-extracted.json matches the packaged glab schema" > $out
    else
      echo "FAIL: overlays/generic/glab-extracted.json is out of sync with glab's internal/config.KeySchema." >&2
      echo "--- committed ---" >&2
      "$jq" -S . ${committed} >&2
      echo "--- extracted from source ---" >&2
      "$jq" -S . ${extracted} >&2
      echo "" >&2
      echo "Regenerate: nix build .#glab.passthru.extracted --no-link --print-out-paths" >&2
      echo "then cp the result over overlays/generic/glab-extracted.json and 'git add' it." >&2
      exit 1
    fi
  '';
}
