{
  lib,
  pkgs,
  harness,
  ...
}: let
  # A stub `lib.hm.dag`, exactly like `checks/ai-own/eval.nix`'s, so `own` can
  # be called here without pulling in real home-manager. This builds one real
  # HM document entry so `dry_run` in runtime.py can execute the SAME text
  # `home-manager switch` would, with home-manager's `run` helper (from
  # `lib/testing/hm-run.sh`) prepended — the shim runtime checks need because
  # they execute activation text under plain bash, which carries no such
  # preamble.
  ownLib =
    lib
    // {
      hm.dag = {
        entryAfter = _: text: {inherit text;};
        entryBefore = _: text: {inherit text;};
      };
    };
  own = import ../../lib/ai/own.nix {lib = ownLib;};
  dryRunEntry =
    (own {
      inherit pkgs;
      backend = "hm";
      entryNames.write = "dryRunProbe";
      python = pkgs.python3;
      targets = [
        {
          codec = "json";
          ledger = "json-settings/dry-run-probe.json";
          path = "settings/probe.json";
          units.text = builtins.toJSON {probe = true;};
        }
      ];
    }).config.home.activation.dryRunProbe.text;
  tools = {
    bash = "${pkgs.bash}/bin/bash";
    hmEntryScript = pkgs.writeText "ai-own-dry-run-entry.sh" (harness.hmRunShim + dryRunEntry);
    # The TSV manifest materialize.nix wrote, captured from that program before
    # it was deleted, exactly as the JSON one below. Both are frozen BYTES
    # because the rollback contract is a byte format and both writers are gone;
    # a fixture built by hand would only prove that the fixture and the reader
    # agree with each other. `.frozen` keeps treefmt away from them.
    legacyDirManifest = "${./fixtures/legacy-dir-manifest.frozen}";
    # The v1 JSON ledger reconcile-toml.py wrote, captured from that program
    # before it was deleted. Frozen bytes rather than a live producer: the
    # rollback contract is a byte format, and the only way to keep testing it
    # after the writer is gone is to keep its output. The `.frozen` extension
    # is load-bearing — treefmt formats `.json`, and a reformatted fixture
    # would assert that own.py agrees with biome rather than with the program
    # whose ledgers are on consumers' disks.
    legacyDocLedger = "${./fixtures/legacy-json-v1-ledger.frozen}";
    own = "${../../lib/ai/own.py}";
    # Deliberately WITHOUT tomlkit: every dir and JSON case runs on this
    # interpreter, which is what proves the TOML import stays lazy.
    python = "${pkgs.python3}/bin/python3";
    tomlPython = "${pkgs.python3.withPackages (pythonPackages: [pythonPackages.tomlkit])}/bin/python3";
  };
in {
  checks.ai-own-runtime = pkgs.runCommand "ai-own-runtime" {} ''
    ${pkgs.python3}/bin/python3 ${./runtime.py} \
      ${pkgs.writeText "ai-own-tools.json" (builtins.toJSON tools)}
    echo 'PASS: ai-own runtime' > "$out"
  '';
}
