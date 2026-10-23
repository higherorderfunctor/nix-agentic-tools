{pkgs, ...}: {
  checks.codeql-nix-contracts = let
    owner = ../.;
    python = pkgs.python3.withPackages (ps: [ps.jsonschema]);
  in
    pkgs.runCommand "codeql-nix-contracts" {
      nativeBuildInputs = [python];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 ${owner}/checks/run-domain-tests.py \
        ${owner}/checks/fixtures/protocol/test_protocol.py \
        ${owner}/checks/fixtures/contracts/test_domain_entrypoint.py \
        ${owner}/checks/fixtures/contracts/test_sentinels.py
      mkdir "$out"
      printf 'Protocol, domain entry point and nonempty ABI/health suites passed\n' > "$out/evidence"
    '';
}
