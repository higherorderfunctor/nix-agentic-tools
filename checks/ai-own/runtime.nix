{pkgs, ...}: let
  tools = {
    bash = "${pkgs.bash}/bin/bash";
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
