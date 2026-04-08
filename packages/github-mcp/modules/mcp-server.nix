{
  lib,
  mcpLib,
  ...
}: let
  inherit (lib) mkOption types concatStringsSep optional optionals;

  knownToolsets = [
    "actions"
    "all"
    "code_security"
    "context"
    "default"
    "discussions"
    "gists"
    "issues"
    "notifications"
    "orgs"
    "packages"
    "pages"
    "projects"
    "pull_requests"
    "releases"
    "repos"
    "search"
    "secret_protection"
    "stargazers"
    "sub_issues"
    "users"
  ];

  knownTools = [
    "add_issue_comment"
    "create_branch"
    "create_or_update_file"
    "create_pull_request"
    "create_repository"
    "delete_file"
    "fork_repository"
    "get_code_scanning_alert"
    "get_commit"
    "get_file_contents"
    "get_issue"
    "get_latest_release"
    "get_me"
    "get_release_by_tag"
    "get_tag"
    "list_branches"
    "list_code_scanning_alerts"
    "list_commits"
    "list_issues"
    "list_pull_requests"
    "list_releases"
    "list_tags"
    "merge_pull_request"
    "push_files"
    "search_code"
    "search_issues"
    "search_pull_requests"
    "search_repositories"
    "search_users"
    "update_pull_request"
    "update_pull_request_branch"
  ];

  toolType = types.either (types.enum knownTools) types.str;
  toolsetType = types.either (types.enum knownToolsets) types.str;
in {
  meta = {
    modes = {
      stdio = "github-mcp-server stdio";
      http = "bridge";
    };
    scope = "remote";
    defaultPort = 19751;
    credentialVars = {
      credentials = {
        envVar = "GITHUB_PERSONAL_ACCESS_TOKEN";
        required = true;
      };
    };
    tools = knownTools;
  };

  settingsOptions = {
    credentials = mcpLib.mkCredentialsOption "GITHUB_PERSONAL_ACCESS_TOKEN";

    ghHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "GitHub hostname for GHE Server or data residency (e.g. https://ghes.example.com). Defaults to public github.com when unset.";
    };

    toolsets = mkOption {
      type = types.listOf toolsetType;
      default = ["all"];
      description = "Toolset groups to enable. Each group activates a related set of tools.";
    };

    tools = mkOption {
      type = types.listOf toolType;
      default = [];
      description = "Individual tool names to enable (additive with toolsets).";
    };

    excludeTools = mkOption {
      type = types.listOf toolType;
      default = [];
      description = "Tool names to forcibly disable regardless of other settings.";
    };

    dynamicToolsets = mkOption {
      type = types.bool;
      default = false;
      description = "Enable dynamic toolsets discovery. When false (default), all tools from configured toolsets are available at startup. When true, only meta-tools are advertised initially and toolsets must be enabled at runtime — requires client support for tools/list_changed notifications.";
    };

    readOnly = mkOption {
      type = types.bool;
      default = false;
      description = "Restrict to read-only operations.";
    };

    logFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to a log file.";
    };

    enableCommandLogging = mkOption {
      type = types.bool;
      default = false;
      description = "Log all command requests and responses.";
    };

    contentWindowSize = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Content window size. Server default is 5000.";
    };

    insiders = mkOption {
      type = types.bool;
      default = false;
      description = "Enable experimental/insiders features.";
    };

    lockdownMode = mkOption {
      type = types.bool;
      default = false;
      description = "Filter public repository content by push access. Only shows repos the token can push to.";
    };

    repoAccessCacheTtl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Cache duration for repository access checks (e.g. \"5m\", \"1h\"). Server default is used when unset.";
    };
  };

  settingsToEnv = _cfg: _mode: {};

  settingsToArgs = cfg: mode:
  # transport-specific
    optionals (mode == "http") ["--port" (toString cfg.service.port)]
    # toolsets and tools
    ++ optionals (cfg.settings.toolsets != []) ["--toolsets" (concatStringsSep "," cfg.settings.toolsets)]
    ++ optionals (cfg.settings.tools != []) ["--tools" (concatStringsSep "," cfg.settings.tools)]
    ++ optionals (cfg.settings.excludeTools != []) ["--exclude-tools" (concatStringsSep "," cfg.settings.excludeTools)]
    # flags
    ++ optional cfg.settings.dynamicToolsets "--dynamic-toolsets"
    ++ optional cfg.settings.insiders "--insiders"
    ++ optional cfg.settings.lockdownMode "--lockdown-mode"
    ++ optional cfg.settings.readOnly "--read-only"
    ++ optional cfg.settings.enableCommandLogging "--enable-command-logging"
    # value flags
    ++ optional (cfg.settings.ghHost != null) "--gh-host=${cfg.settings.ghHost}"
    ++ optional (cfg.settings.logFile != null) "--log-file=${cfg.settings.logFile}"
    ++ optionals (cfg.settings.contentWindowSize != null) ["--content-window-size" (toString cfg.settings.contentWindowSize)]
    ++ optionals (cfg.settings.repoAccessCacheTtl != null) ["--repo-access-cache-ttl" cfg.settings.repoAccessCacheTtl];
}
