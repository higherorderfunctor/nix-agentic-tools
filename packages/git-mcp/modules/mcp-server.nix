{lib, ...}: let
  inherit (lib) mkOption types optional;
in {
  meta = {
    modes = {
      stdio = "mcp-server-git";
      http = "bridge";
    };
    scope = "local";
    defaultPort = 19757;
    tools = ["git_add" "git_branch" "git_checkout" "git_commit" "git_create_branch" "git_diff" "git_diff_staged" "git_diff_unstaged" "git_log" "git_reset" "git_show" "git_status"];
  };

  settingsOptions = {
    repository = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Git repository path. When set, restricts all operations to this path.
        When unset, the server accepts any repo path via tool arguments and
        discovers repos from MCP client roots.
      '';
    };
  };

  settingsToEnv = _cfg: _mode: {};

  settingsToArgs = cfg: _mode:
    optional (cfg.settings.repository != null) "--repository=${cfg.settings.repository}";
}
