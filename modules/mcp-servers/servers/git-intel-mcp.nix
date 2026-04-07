{lib, ...}: let
  inherit (lib) mkOption types optionalAttrs;
in {
  meta = {
    modes = {
      stdio = "git-intel-mcp";
      http = "bridge";
    };
    scope = "local";
    defaultPort = 19756;
    tools = ["branch_risk" "churn" "code_age" "commit_patterns" "complexity_trend" "contributor_stats" "coupling" "file_history" "hotspots" "knowledge_map" "release_notes" "risk_assessment"];
  };

  settingsOptions = {
    repository = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Default git repository path for analysis.
        Resolution order: this option > GIT_INTEL_REPO env > cwd.
      '';
    };
  };

  settingsToEnv = cfg: _mode:
    optionalAttrs (cfg.settings.repository != null) {
      GIT_INTEL_REPO = cfg.settings.repository;
    };

  settingsToArgs = _cfg: _mode: [];
}
