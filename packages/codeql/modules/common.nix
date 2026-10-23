{stateDirectory}: {
  config,
  lib,
  ...
}: let
  cfg = config.ai.codeql.queryDaemon;
  package = config.ai.internal.packages.devTools.codeql.codeql-query;
in {
  imports = [
    (import ../../ai-module/lib/runtime.nix {
      enabled = cfg.enable;
      name = "codeql";
    })
  ];
  options.ai.codeql.queryDaemon.enable = lib.mkEnableOption "the local CodeQL query daemon (one lazy query-server2 per database)";
  config.ai.codeql = lib.mkIf cfg.enable {
    # The socket has the same location on both backends and clients; like the
    # generic service launcher it uses a user-qualified TMPDIR fallback.
    claims.path = ["$XDG_RUNTIME_DIR/ai-service-codeql-query/query.sock"];
    services.codeql-query.command = [
      (lib.getExe package)
      "serve"
      "--state-dir"
      (stateDirectory config)
    ];
  };
}
