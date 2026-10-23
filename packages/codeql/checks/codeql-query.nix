# A real engine and tiny Nix fixture exercise fallback, the socket daemon,
# diagnostics, per-database affinity, generation swaps and idle lock release.
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-query = let
      packages = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
      nixCodeql = packages.codeql-extractor-nix.codeql;
    in
      pkgs.runCommand "codeql-query" {
        nativeBuildInputs = [pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR" LC_ALL=C
        python3 ${./query-transport-test.py} ${lib.getExe packages.codeql-query} > "$out"
        python3 ${./query-test.py} ${lib.getExe packages.codeql-query} \
          ${nixCodeql.engine} ${lib.getExe nixCodeql.createDatabase} \
          ${./fixtures/nix-project} >> "$out"
      '';

    codeql-query-module = let
      enabled = {ai.codeql.queryDaemon.enable = true;};
      hm = (harness.evalHm enabled).config;
      devenv = (harness.evalDevenv enabled).config;
      disabled = (harness.evalHm {}).config;
      command = config: config.ai.services.codeql-query.command;
      claimed = config: config.ai.claims.path."$XDG_RUNTIME_DIR/ai-service-codeql-query/query.sock";
    in
      assert !(disabled.ai.services ? codeql-query);
      assert lib.take 3 (command hm) == lib.take 3 (command devenv);
      assert lib.last (command hm) == "/home/test/.local/state/codeql-query";
      assert lib.last (command devenv) == "/tmp/devenv-state/codeql-query";
      assert claimed hm == ["codeql"] && claimed devenv == ["codeql"];
      assert hm.systemd.user.services ? codeql-query;
      assert devenv.processes ? codeql-query;
        pkgs.writeText "codeql-query-module" "off by default; one owner service and socket claim on Home Manager and devenv\n";
  };
}
