# Opt-in Kiro wire capture; service lifecycle stays in ai.services.
{
  lib,
  pkgs,
}: let
  runtime = "${../usage}/runtime.py";
  proxyNames = ["ALL_PROXY" "HTTP_PROXY" "HTTPS_PROXY" "NO_PROXY" "NODE_EXTRA_CA_CERTS" "all_proxy" "http_proxy" "https_proxy" "no_proxy"];
  stateArgs = cfg: lib.optionals (cfg.dataDirectory != null) ["--state-dir" cfg.dataDirectory];
in {
  options = {
    enable = lib.mkEnableOption "private local Kiro usage capture through a loopback TLS proxy";
    dataDirectory = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "/.+");
      default = null;
      description = "Private runtime state directory for usage.sqlite3 and the proxy CA. Null resolves XDG_STATE_HOME/kiro-cli/usage, falling back to HOME/.local/state/kiro-cli/usage, when each process starts. Existing directories must be owned by the user with mode 0700.";
    };
    maxPayloadBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 268435456;
      description = "Maximum compressed payload bytes retained by the collector. At the limit it continues accounting and records omitted payloads; SQLite metadata and WAL can grow beyond this payload budget.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 18089;
      description = "Port claimed by the usage proxy, listening only on 127.0.0.1.";
    };
  };
  assertions = cfg: environment:
    lib.optionals cfg.cli.usageTracking.enable [
      {
        assertion = cfg.cli.package != null;
        message = "ai.kiro.cli.usageTracking requires a managed ai.kiro.cli.package.";
      }
      {
        assertion = cfg.cli.v3;
        message = "ai.kiro.cli.usageTracking requires ai.kiro.cli.v3 for the Node CA trust path.";
      }
      {
        assertion = lib.intersectLists proxyNames (builtins.attrNames environment) == [];
        message = "ai.kiro.cli.usageTracking owns HTTP(S)/ALL/NO_PROXY (both cases) and NODE_EXTRA_CA_CERTS; remove conflicting ai.environmentVariables / ai.kiro.cli.environmentVariables entries.";
      }
    ];
  service = cfg: {
    command =
      [
        "${pkgs.python3}/bin/python3"
        (toString runtime)
        "service"
        "--port"
        (toString cfg.port)
        "--max-bytes"
        (toString cfg.maxPayloadBytes)
        "--mitmdump"
        "${pkgs.mitmproxy}/bin/mitmdump"
        "--addon"
        "${../usage}/mitm_addon.py"
      ]
      ++ stateArgs cfg;
    ports.proxy = cfg.port;
  };
  tool = cfg:
    import ../../../lib/strict-shell-application.nix pkgs {
      name = "kiro-usage";
      text = ''
        exec ${pkgs.python3}/bin/python3 ${runtime} cli ${lib.escapeShellArgs (["--port" (toString cfg.port)] ++ stateArgs cfg)} -- "$@"
      '';
    };
  launcherBlock = cfg:
    lib.optionalString cfg.enable ''
      nat_usage_environment="$(${pkgs.python3}/bin/python3 ${runtime} environment ${lib.escapeShellArgs (["--port" (toString cfg.port)] ++ stateArgs cfg)})"
      eval "$nat_usage_environment"
      unset nat_usage_environment
    '';
}
