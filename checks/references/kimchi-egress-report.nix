# Regenerate through lib.extracted; compare parsed JSON because treefmt owns layout.
{
  lib,
  pkgs,
  ...
}: let
  extracted = import ../../lib/extracted/facts.nix {inherit lib;};
  inherit (extracted.load {dir = ../../packages/kimchi/extracted;}) aggregate;
  facts = {
    environment.variables = extracted.children aggregate "environment.variables.<name>";
    network = extracted.get aggregate "network";
  };
  kimchi = ../../packages/kimchi;
  scripts = ../../dev/skills/kimchi-egress-report/scripts;
in {
  checks.kimchi-egress-report = pkgs.runCommand "kimchi-egress-report-check" {passthru = {inherit facts;};} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    jq="${pkgs.jq}/bin/jq"
    ${pkgs.nodejs}/bin/node ${scripts}/generate.mjs \
      --facts ${pkgs.writeText "kimchi-egress-facts.json" (builtins.toJSON facts)} \
      --report ${kimchi}/egress-report.json \
      --sources ${kimchi}/sources.json \
      --out fresh.json
    if ! "$jq" -e -n --slurpfile a ${kimchi}/egress-report.json \
      --slurpfile b fresh.json '$a == $b' >/dev/null; then
      "$jq" -S . ${kimchi}/egress-report.json >committed.json
      "$jq" -S . fresh.json >regenerated.json
      ${pkgs.diffutils}/bin/diff -u committed.json regenerated.json >&2 || :
      echo "FAIL: packages/kimchi/egress-report.json is out of sync with its facts." >&2
      echo "Regenerate from the repository root:" >&2
      echo "  dev/skills/kimchi-egress-report/scripts/regenerate.sh" >&2
      exit 1
    fi
    echo "ok: the egress report matches its facts" >"$out"
  '';
}
