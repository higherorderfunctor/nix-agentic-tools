{
  harness,
  lib,
  pkgs,
  ...
}: let
  evaluated = harness.evalDevenv {
    ai = {
      claude.enable = true;
      codex.enable = true;
      programs.delegate-routing = {
        enable = true;
        # A real pool keeps the rendered-exclusion check from passing on an empty table.
        pools.fixture.window = {
          limit = 1;
          resetDay = 1;
          unit = "requests";
        };
        skill.entries.Pools.text = "## Pools\n\n{pools}";
      };
    };
  };
  routing = evaluated.config.ai.programs.delegate-routing;
  techniques = (import ../../delegate-routing/lib/select-families.nix {inherit lib;}).effectiveTechniques evaluated.config;
  # Read actual module registrations; only pool identities and reader commands
  # are inputs to this policy, not unrelated prose or inference techniques.
  inventory = pkgs.writeText "cloudflare-routing-inventory.json" (builtins.toJSON {
    pools = builtins.attrNames routing.pools;
    readers = lib.concatLists (lib.mapAttrsToList (_: runtimeTechniques:
      map (technique: technique.command)
      (builtins.filter (technique: technique.kind == "usage") (builtins.attrValues runtimeTechniques)))
    techniques);
  });
  skills = map (runtime: evaluated.config.ai.${runtime}.skills.delegate-routing) ["claude" "codex"];
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    cloudflare-usage-structure = pkgs.runCommand "cloudflare-usage-structure" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 - ${inventory} ${lib.concatMapStringsSep " " (skill: "${skill}/SKILL.md") skills} <<'PY'
      import json
      from pathlib import Path
      import re
      import sys

      inventory = json.loads(Path(sys.argv[1]).read_text())
      # An unbound technique or a pool with no reader could escape a rendered-only check.
      for command in inventory["readers"]:
          assert "cloudflare-usage" not in (command or "").lower(), "Cloudflare usage technique registered"
      for name in inventory["pools"]:
          assert name.lower() != "cloudflare", "Cloudflare pool registered"
      for path in sys.argv[2:]:
          text = Path(path).read_text()
          pools = re.search(r"^## Pools\n(.*?)(?=^## |\Z)", text, re.M | re.S)
          assert pools is not None and re.search(r"^\|\s*fixture\s*\|", pools[1], re.M), f"{path}: control pool missing"
          # A renderer could inject a pool or reader without registering it.
          assert not re.search(r"^\|\s*cloudflare\s*\|", pools[1], re.M | re.I), f"{path}: Cloudflare pool rendered"
          assert "cloudflare-usage" not in pools[1].lower(), f"{path}: Cloudflare reader rendered"
      print("PASS: actual registrations and generated Pools exclude Cloudflare")
      PY
      touch "$out"
    '';
  };
}
