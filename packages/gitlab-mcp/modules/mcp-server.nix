# Typed schema for gitlab-mcp (zereight/gitlab-mcp).
#
# Upstream env vars and tool registry verified 2026-05-20 against
# c2577169b21d62197f767895fe97651ffb2d7443 (v2.1.13). See
# docs/plans/gitlab-mcp-packaging-slim.md for the upstream
# verification trail.
#
# Naming divergence from github-mcp (single generic `credentials`
# vs three named `pat`/`apiUrl`/`jobToken`) is deliberate and
# user-approved: each credential here describes a distinct
# upstream env var whose purpose is meaningful to the consumer.
# Normalizing all MCP modules to a unified credential schema is a
# separate, deferred design — do not "fix" this in passing.
{
  lib,
  mcpLib,
  ...
}: let
  inherit (lib) mkOption types concatStringsSep optionalAttrs;

  # Upstream tool registry — extracted 2026-05-20 from
  # tools/registry.ts:194-1124 at
  # c2577169b21d62197f767895fe97651ffb2d7443 (182 tools total).
  # This is a discovery surface for consumers (`meta.tools`); the
  # `tools` option below stays freeform `listOf str` rather than
  # an enum so consumers can pass through new upstream tools
  # without waiting for a repo bump.
  knownTools = [
    "approve_merge_request"
    "bulk_publish_draft_notes"
    "cancel_pipeline"
    "cancel_pipeline_job"
    "convert_work_item_type"
    "create_branch"
    "create_commit_status"
    "create_draft_note"
    "create_group"
    "create_group_wiki_page"
    "create_issue"
    "create_issue_emoji_reaction"
    "create_issue_link"
    "create_issue_note"
    "create_issue_note_emoji_reaction"
    "create_label"
    "create_merge_request"
    "create_merge_request_discussion_note"
    "create_merge_request_emoji_reaction"
    "create_merge_request_note"
    "create_merge_request_note_emoji_reaction"
    "create_merge_request_thread"
    "create_milestone"
    "create_note"
    "create_or_update_file"
    "create_pipeline"
    "create_release"
    "create_release_evidence"
    "create_repository"
    "create_tag"
    "create_timeline_event"
    "create_wiki_page"
    "create_work_item"
    "create_work_item_emoji_reaction"
    "create_work_item_note"
    "create_work_item_note_emoji_reaction"
    "delete_branch"
    "delete_draft_note"
    "delete_group_wiki_page"
    "delete_issue"
    "delete_issue_emoji_reaction"
    "delete_issue_link"
    "delete_issue_note_emoji_reaction"
    "delete_label"
    "delete_merge_request_discussion_note"
    "delete_merge_request_emoji_reaction"
    "delete_merge_request_note"
    "delete_merge_request_note_emoji_reaction"
    "delete_milestone"
    "delete_release"
    "delete_tag"
    "delete_wiki_page"
    "delete_work_item_emoji_reaction"
    "delete_work_item_note_emoji_reaction"
    "discover_tools"
    "download_attachment"
    "download_job_artifacts"
    "download_release_asset"
    "edit_milestone"
    "execute_graphql"
    "fork_repository"
    "get_branch"
    "get_branch_diffs"
    "get_commit"
    "get_commit_diff"
    "get_deployment"
    "get_draft_note"
    "get_environment"
    "get_file_blame"
    "get_file_contents"
    "get_group_wiki_page"
    "get_issue"
    "get_issue_link"
    "get_job_artifact_file"
    "get_label"
    "get_merge_request"
    "get_merge_request_approval_state"
    "get_merge_request_conflicts"
    "get_merge_request_diffs"
    "get_merge_request_file_diff"
    "get_merge_request_note"
    "get_merge_request_notes"
    "get_merge_request_version"
    "get_milestone"
    "get_milestone_burndown_events"
    "get_milestone_issue"
    "get_milestone_merge_requests"
    "get_namespace"
    "get_pipeline"
    "get_pipeline_job"
    "get_pipeline_job_output"
    "get_project"
    "get_project_events"
    "get_release"
    "get_repository_tree"
    "get_tag"
    "get_tag_signature"
    "get_timeline_events"
    "get_user"
    "get_users"
    "get_webhook_event"
    "get_wiki_page"
    "get_work_item"
    "health_check"
    "list_branches"
    "list_commit_statuses"
    "list_commits"
    "list_custom_field_definitions"
    "list_deployments"
    "list_draft_notes"
    "list_environments"
    "list_events"
    "list_group_iterations"
    "list_group_projects"
    "list_group_wiki_pages"
    "list_issue_discussions"
    "list_issue_emoji_reactions"
    "list_issue_links"
    "list_issue_note_emoji_reactions"
    "list_issues"
    "list_job_artifacts"
    "list_labels"
    "list_merge_request_changed_files"
    "list_merge_request_diffs"
    "list_merge_request_emoji_reactions"
    "list_merge_request_note_emoji_reactions"
    "list_merge_request_pipelines"
    "list_merge_request_versions"
    "list_merge_requests"
    "list_milestones"
    "list_namespaces"
    "list_pipeline_jobs"
    "list_pipeline_trigger_jobs"
    "list_pipelines"
    "list_project_members"
    "list_projects"
    "list_releases"
    "list_tags"
    "list_todos"
    "list_webhook_events"
    "list_webhooks"
    "list_wiki_pages"
    "list_work_item_emoji_reactions"
    "list_work_item_note_emoji_reactions"
    "list_work_item_notes"
    "list_work_item_statuses"
    "list_work_items"
    "mark_all_todos_done"
    "mark_todo_done"
    "merge_merge_request"
    "move_work_item"
    "mr_discussions"
    "my_issues"
    "play_pipeline_job"
    "promote_milestone"
    "publish_draft_note"
    "push_files"
    "resolve_merge_request_thread"
    "retry_pipeline"
    "retry_pipeline_job"
    "search_code"
    "search_group_code"
    "search_project_code"
    "search_repositories"
    "unapprove_merge_request"
    "update_draft_note"
    "update_group_wiki_page"
    "update_issue"
    "update_issue_description_patch"
    "update_issue_note"
    "update_label"
    "update_merge_request"
    "update_merge_request_discussion_note"
    "update_merge_request_note"
    "update_release"
    "update_wiki_page"
    "update_work_item"
    "upload_markdown"
    "validate_ci_lint"
    "validate_project_ci_lint"
    "verify_namespace"
    "whoami"
  ];
in {
  meta = {
    modes = {
      stdio = "gitlab-mcp";
      http = "bridge";
    };
    scope = "remote";
    defaultPort = 19761;
    credentialVars = {
      pat = {
        envVar = "GITLAB_PERSONAL_ACCESS_TOKEN";
        required = true;
      };
      apiUrl = {
        envVar = "GITLAB_API_URL";
        required = false;
      };
      jobToken = {
        envVar = "GITLAB_JOB_TOKEN";
        required = false;
      };
    };
    tools = knownTools;
  };

  settingsOptions = {
    # ── Credentials ────────────────────────────────────────────
    pat = mcpLib.mkCredentialsOption "GITLAB_PERSONAL_ACCESS_TOKEN";
    apiUrl = mcpLib.mkCredentialsOption "GITLAB_API_URL";
    jobToken = mcpLib.mkCredentialsOption "GITLAB_JOB_TOKEN";

    # ── Typed options ──────────────────────────────────────────
    instanceUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        GitLab instance URL (plain string, lands in Nix store).
        Flows to GITLAB_API_URL. Use this when the URL is public
        knowledge. For URLs that must stay out of the store, use
        `settings.apiUrl.file` / `settings.apiUrl.helper` instead
        — the two are mutually exclusive.
      '';
    };

    caCertPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to a CA certificate bundle for self-signed GitLab instances. Mapped to GITLAB_CA_CERT_PATH.";
    };

    defaultProjectId = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Default project ID injected into tool calls that accept one. Mapped to GITLAB_PROJECT_ID.";
    };

    allowedProjectIds = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Restrict tool calls to this list of project IDs. Joined with `,` into GITLAB_ALLOWED_PROJECT_IDS.";
    };

    readOnly = mkOption {
      type = types.bool;
      default = false;
      description = "Restrict to read-only operations. Sets GITLAB_READ_ONLY_MODE=true.";
    };

    toolsets = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Toolset groups to enable. Joined with `,` into GITLAB_TOOLSETS.";
    };

    tools = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Individual tool names to enable. Joined with `,` into
        GITLAB_TOOLS. See `meta.tools` for the discovery list of
        names known to v2.1.13 (kept freeform `listOf str` so
        consumers can opt into newer upstream tools without
        waiting for a repo bump).
      '';
    };

    deniedToolsRegex = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Regex pattern matching tool names to deny. Mapped to GITLAB_DENIED_TOOLS_REGEX.";
    };

    useWiki = mkOption {
      type = types.bool;
      default = false;
      description = "Enable wiki tools. Sets USE_GITLAB_WIKI=true.";
    };

    useMilestone = mkOption {
      type = types.bool;
      default = false;
      description = "Enable milestone tools. Sets USE_MILESTONE=true.";
    };

    usePipeline = mkOption {
      type = types.bool;
      default = false;
      description = "Enable pipeline tools. Sets USE_PIPELINE=true.";
    };
  };

  # `evalSettings` discards `eval.assertions` (lib/mcp.nix:27-37),
  # so a module-level `assertions` block silently no-ops here.
  # Encode the instanceUrl ⊕ apiUrl mutex as an `if/throw` at the
  # top — it fires every time `renderServer` evaluates the config.
  settingsToEnv = cfg: _mode: let
    s = cfg.settings;
    instanceUrlSet = s.instanceUrl != null;
    apiUrlCredSet =
      (s.apiUrl.file or null)
      != null
      || (s.apiUrl.helper or null) != null;
  in
    if instanceUrlSet && apiUrlCredSet
    then
      throw ''
        gitlab-mcp: set either `settings.instanceUrl` (plain URL, in
        Nix store) or `settings.apiUrl.file`/`helper` (kept out of
        store) — not both.''
    else
      optionalAttrs (s.instanceUrl != null) {GITLAB_API_URL = s.instanceUrl;}
      // optionalAttrs (s.caCertPath != null) {GITLAB_CA_CERT_PATH = s.caCertPath;}
      // optionalAttrs (s.defaultProjectId != null) {GITLAB_PROJECT_ID = s.defaultProjectId;}
      // optionalAttrs (s.allowedProjectIds != []) {
        GITLAB_ALLOWED_PROJECT_IDS = concatStringsSep "," s.allowedProjectIds;
      }
      // optionalAttrs s.readOnly {GITLAB_READ_ONLY_MODE = "true";}
      // optionalAttrs (s.toolsets != []) {
        GITLAB_TOOLSETS = concatStringsSep "," s.toolsets;
      }
      // optionalAttrs (s.tools != []) {
        GITLAB_TOOLS = concatStringsSep "," s.tools;
      }
      // optionalAttrs (s.deniedToolsRegex != null) {
        GITLAB_DENIED_TOOLS_REGEX = s.deniedToolsRegex;
      }
      // optionalAttrs s.useWiki {USE_GITLAB_WIKI = "true";}
      // optionalAttrs s.useMilestone {USE_MILESTONE = "true";}
      // optionalAttrs s.usePipeline {USE_PIPELINE = "true";};

  # gitlab-mcp takes all configuration via env vars; no CLI args.
  settingsToArgs = _cfg: _mode: [];
}
