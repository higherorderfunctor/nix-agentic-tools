{
  harness,
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-language-server =
      pkgs.runCommand "codeql-language-server" {
        nativeBuildInputs = [pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR" LC_ALL=C
        python3 ${./language-server-test.py} ${lib.getExe self.ciPackages.x86_64-linux.codeql-lsp} > "$out"
        cat "$out"
      '';

    codeql-language-server-module = let
      factory = self.lib.ai.mcpServers.mkCodeqlLanguageServer {
        lib = lib // self.lib;
        inherit pkgs;
      };
      entry = factory {
        searchPath = [../ql];
        workspace = "/workspace";
      };
      configured.ai = {
        codex.enable = true;
        mcpServers.codeql = entry;
      };
      hm = (harness.evalHm configured).config;
      devenv = (harness.evalDevenv configured).config;
      disabled = (harness.evalHm {}).config;
      hmServer = hm.ai.codex.files."${hm.ai.codex.configDir}/config.toml".content.value.mcp_servers.codeql;
      devenvServer = devenv.ai.codex.files.".codex/config.toml".content.value.mcp_servers.codeql;
    in
      assert hmServer.command == entry.command && hmServer.args == entry.args;
      assert hmServer == devenvServer;
      assert !(disabled.ai.mcpServers ? codeql);
      assert hm.ai.mcpServers.codeql.command == lib.getExe pkgs.ai.mcpServers.mcp-language-server;
      assert lib.take 3 entry.args == ["-workspace" "/workspace" "-lsp"];
      assert lib.last entry.args == lib.getExe (pkgs.ai.lspServers.codeql-lsp.override {searchPath = [../ql];});
        pkgs.writeText "codeql-language-server-module" "opt-in MCP bridge and extra pack paths agree on Home Manager and devenv\n";
  };
}
