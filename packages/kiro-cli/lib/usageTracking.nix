# Opt-in Kiro wire capture; service lifecycle stays in ai.services.
{
  lib,
  pkgs,
}: let
  runtime = "${../usage}/runtime.py";
  proxyNames = ["ALL_PROXY" "HTTP_PROXY" "HTTPS_PROXY" "NO_PROXY" "NODE_EXTRA_CA_CERTS" "all_proxy" "http_proxy" "https_proxy" "no_proxy"];
  stateArgs = cfg: lib.optionals (cfg.dataDirectory != null) ["--state-dir" cfg.dataDirectory];
  # The collector warns once past it; the tool's exec summary repeats the warning.
  warnArgs = cfg: ["--warn-bytes" (toString cfg.payloadWarnBytes)];
  # Set keys only: summary_theme.py owns the defaults, so unset options add no flag and no store file.
  # A direct wrapPackage usageTracking set may predate summary.
  summaryTheme = cfg: lib.filterAttrs (_: value: value != null && value != {}) (cfg.summary or {});
  summaryArgs = cfg: let
    theme = summaryTheme cfg;
  in
    lib.optionals (theme != {}) ["--summary-theme" (toString (pkgs.writeText "kiro-usage-summary-theme.json" (builtins.toJSON theme)))];
  # The tool's `exec` and `report` commands print the exit summary.
  toolArgs = cfg: ["--port" (toString cfg.port)] ++ warnArgs cfg ++ stateArgs cfg ++ summaryArgs cfg;
in {
  inherit summaryTheme toolArgs;
  options = {
    enable = lib.mkEnableOption "private local Kiro usage capture through a loopback TLS proxy";
    dataDirectory = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "/.+");
      default = null;
      description = "Private runtime state directory for usage.sqlite3 and the proxy CA. Null resolves XDG_STATE_HOME/kiro-cli/usage, falling back to HOME/.local/state/kiro-cli/usage, when each process starts. Existing directories must be owned by the user with mode 0700.";
    };
    payloadWarnBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1073741824;
      description = "Compressed payload bytes past which usage capture warns. Payloads are always retained; once the retained compressed payload bytes exceed this, the collector logs one warning per run and each tracked exec summary repeats it with retirement guidance. SQLite metadata and WAL are not counted.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 18089;
      description = "Port claimed by the usage proxy, listening only on 127.0.0.1.";
    };
    summary = {
      border = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum ["ascii" "double" "heavy" "none" "rounded" "single"]);
        default = null;
        description = "Box drawn around the exit summary, its rule becoming a junction line. Null keeps the runtime default, none.";
      };
      color = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum ["always" "auto" "never"]);
        default = null;
        description = "Exit summary styling: auto styles only when its stream (standard error after exec, standard output for report) is a terminal and NO_COLOR is unset or empty. Null keeps the runtime default, auto.";
      };
      icons = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Prefix the exit summary headline and caveat with Nerd Font glyphs. Null keeps the runtime default, false.";
      };
      styles = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        example = {
          border = "bright-black";
          total = "bold #ffaf00";
        };
        description = "Exit summary style specs by element, replacing the built-in defaults per element when color is on; see packages/kiro-cli/usage/README.md. An unknown element or token makes the summary report itself unavailable.";
      };
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
        message = "ai.kiro.cli.usageTracking owns HTTP(S)/ALL/NO_PROXY (both cases) and NODE_EXTRA_CA_CERTS; remove conflicting ai.environmentVariables / ai.kiro.cli.environmentVariables entries, or opt out of ai.proxy with ai.kiro.proxy = {http = null; https = null;}.";
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
        "--mitmdump"
        "${pkgs.mitmproxy}/bin/mitmdump"
        "--addon"
        "${../usage}/mitm_addon.py"
      ]
      ++ warnArgs cfg
      ++ stateArgs cfg;
    ports.proxy = cfg.port;
  };
  tool = cfg:
    import ../../../lib/strict-shell-application.nix pkgs {
      name = "kiro-usage";
      text = ''
        exec ${pkgs.python3}/bin/python3 ${runtime} cli ${lib.escapeShellArgs (toolArgs cfg)} -- "$@"
      '';
    };
  launcherBlock = cfg:
    lib.optionalString cfg.enable ''
      nat_usage_environment="$(${pkgs.python3}/bin/python3 ${runtime} environment ${lib.escapeShellArgs (["--port" (toString cfg.port)] ++ stateArgs cfg)})"
      eval "$nat_usage_environment"
      unset nat_usage_environment
    '';
}
