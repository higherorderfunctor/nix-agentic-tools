# Advisory model-staleness check — compares the curated
# packages/claude-code/models.json against the binary's firstParty:
# registry. ADVISORY: a new id nudges a curation PR; it never fails CI
# (the curated list is intentionally a subset — no deprecated/date-suffixed
# ids). Distinct from checks/claude-code-extracted.nix, which BLOCKS.
{
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  bin = "${self.packages.${system}.claude-code}/bin/claude";
  committed = ../packages/claude-code/models.json;
in {
  model-staleness-claude = pkgs.runCommand "model-staleness-claude" {} ''
    grep="${pkgs.gnugrep}/bin/grep"
    sed="${pkgs.gnused}/bin/sed"
    jq="${pkgs.jq}/bin/jq"
    sort="${pkgs.coreutils}/bin/sort"
    comm="${pkgs.coreutils}/bin/comm"
    tee="${pkgs.coreutils}/bin/tee"

    binIds=$("$grep" -aoE 'firstParty:"claude-[a-z0-9-]+"' "${bin}" \
      | "$sed" -E 's/^firstParty:"//; s/"$//' | "$sort" -u || true)
    committedIds=$("$jq" -r '.[]' ${committed} | "$sort" -u)
    {
      echo "claude model staleness (advisory):"
      if [ -z "$binIds" ]; then
        echo "  WARNING: no firstParty: ids found — upstream may have changed the registry shape."
      else
        missing=$("$comm" -23 <(printf '%s\n' "$binIds") <(printf '%s\n' "$committedIds") || true)
        if [ -z "$missing" ]; then
          echo "  curated list covers every current binary id (subset by design)."
        else
          echo "  binary exposes ids NOT in packages/claude-code/models.json:"
          printf '    %s\n' $missing
          echo "  curate packages/claude-code/models.json if any are current/non-deprecated."
        fi
      fi
    } | "$tee" $out
  '';
}
