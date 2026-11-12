{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  system = pkgs.stdenv.hostPlatform.system;
  # Use the public export: ciPackages alone would miss a private-only command.
  public = self.packages.${system};
  evaluated = harness.evalDevenv {
    ai = {
      claude.enable = true;
      codex.enable = true;
      programs.delegate-routing = {
        enable = true;
        skill.entries.Pools.text = "## Pools\n\n{pools}";
      };
    };
  };
  routing = evaluated.config.ai.programs.delegate-routing;
  techniques = (import ../../delegate-routing/lib/select-families.nix {inherit lib;}).effectiveTechniques evaluated.config;
  # Read actual module registrations; only pool identities and reader commands
  # are inputs to this policy, not unrelated prose or inference techniques.
  registrations =
    lib.mapAttrsToList (name: pool: {
      inherit name;
      command =
        if pool.usage == null
        then null
        else techniques.${pool.usage.runtime}.${pool.usage.technique}.command;
    })
    routing.pools;
  inventory = pkgs.writeText "cloudflare-routing-inventory.json" (builtins.toJSON {
    pools = registrations;
    readers = lib.concatLists (lib.mapAttrsToList (_: runtimeTechniques:
      map (technique: technique.command)
      (builtins.filter (technique: technique.kind == "usage") (builtins.attrValues runtimeTechniques)))
    techniques);
  });
  skills = map (runtime: evaluated.config.ai.${runtime}.skills.delegate-routing) ["claude" "codex"];
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    cloudflare-usage-structure = assert public ? cloudflare-usage;
      pkgs.runCommand "cloudflare-usage-structure" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        test -x ${public.cloudflare-usage}/bin/cloudflare-usage
        ${pkgs.python3}/bin/python3 - ${inventory} ${lib.concatMapStringsSep " " (skill: "${skill}/SKILL.md") skills} <<'PY'
        import json
        from pathlib import Path
        import re
        import sys

        inventory = json.loads(Path(sys.argv[1]).read_text())
        for command in inventory["readers"]:
            assert "cloudflare-usage" not in (command or "").lower(), "Cloudflare usage technique registered"
        for entry in inventory["pools"]:
            assert entry["name"].lower() != "cloudflare", "Cloudflare pool registered"
            assert "cloudflare-usage" not in (entry["command"] or "").lower(), "Cloudflare reader registered"
        for path in sys.argv[2:]:
            text = Path(path).read_text()
            pools = re.search(r"^## Pools\n(.*?)(?=^## |\Z)", text, re.M | re.S)
            # The renderer omits the whole Pools entry when no pools exist.
            assert pools is not None or not inventory["pools"], "generated Pools section missing"
            if pools is None:
                continue
            assert not re.search(r"^\|\s*cloudflare\s*\|", pools[1], re.M | re.I), "Cloudflare pool rendered"
            assert "cloudflare-usage" not in pools[1].lower(), "Cloudflare reader rendered"
        print("PASS: public executable; actual registrations and generated Pools exclude Cloudflare")
        PY
        touch "$out"
      '';
  };
}
