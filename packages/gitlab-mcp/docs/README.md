# gitlab-mcp

> **Last verified:** 2026-10-07 — redact URL diagnostics name instanceUrl;
> deferred env vars retain their upstream references.

[zereight/gitlab-mcp](https://github.com/zereight/gitlab-mcp) packaged as a Nix
derivation with a typed home-manager surface. Exposes 182 GitLab REST/GraphQL
tools (merge requests, issues, pipelines, wikis, work items, etc.) to MCP-aware
clients (Claude Code, Codex, Copilot, Kiro). Connects to gitlab.com by default;
self-hosted instances are configured per the "Instance URL" section below.

## Quick start (HM)

```nix
{ config, redact, ... }: {
  services.mcp-servers.servers.gitlab-mcp = {
    enable = true;
    settings.pat = redact.file {
      path = config.sops.secrets."gitlab-personal-access-token".path;
    };
  };
}
```

The PAT (`GITLAB_PERSONAL_ACCESS_TOKEN`) is the only required credential. The
`settings.pat` option accepts a `redact.file { path = "…"; }` or
`redact.command { path = "…"; }` reference. Inline tokens are a type error. The
shared reader refuses unreadable, empty, NUL-containing, or failed command
output before starting the server; its diagnostics never include the value.

## Instance URL

`instanceUrl` maps to `GITLAB_API_URL` and accepts a public string or a
reference:

```nix
# Public URL, stored in Nix.
services.mcp-servers.servers.gitlab-mcp.settings.instanceUrl =
  "https://gitlab.example.com";
```

```nix
# Private URL, read only when the server starts.
services.mcp-servers.servers.gitlab-mcp.settings.instanceUrl = redact.file {
  path = config.sops.secrets."gitlab-instance-url".path;
};
```

## Trust posture knobs

By default every tool is enabled and every project the PAT can see is reachable.
Three sets of settings narrow that surface:

- `readOnly = true` — sets `GITLAB_READ_ONLY_MODE=true`; the server refuses
  tools that mutate state. Use when only read access is needed.
- `toolsets = [ "issues" "merge_requests" ]` — restrict to specific feature
  groups. Combines with `tools` (additive).
- `tools = [ "list_issues" "get_merge_request" ]` — fine-grained per-tool
  allowlist. See the upstream
  [`tools/registry.ts`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/tools/registry.ts)
  for the 182 known v2.1.13 names. The type stays freeform `listOf str` so
  consumers can opt into newer upstream tools without waiting for a repo bump.
- `deniedToolsRegex = "delete_.*"` — regex denylist applied after
  toolsets/tools. Use as a guardrail for the destructive surface.
- `allowedProjectIds = [ "42" "97" ]` — restrict tool calls to a specific set of
  project IDs (joined into `GITLAB_ALLOWED_PROJECT_IDS`). Pair with
  `defaultProjectId` if most calls target a single project.

## Startup version check

`disableVersionCheck` defaults to `true`, setting
`GITLAB_DISABLE_VERSION_CHECK=true`. This disables upstream's npm version check
at startup: the Nix-pinned package cannot self-update, and the check causes DNS
and HTTPS egress before any tool call. Set
`settings.disableVersionCheck = false` to restore the upstream check (the
environment variable is omitted).

## Optional features

- `useWiki = true` / `useMilestone = true` / `usePipeline = true` — enable the
  upstream `USE_GITLAB_WIKI` / `USE_MILESTONE` / `USE_PIPELINE` flags. Off by
  default to keep the default tool list small.
- `caCertPath = "/etc/ssl/certs/ca.pem"` — path to a CA bundle for self-signed
  GitLab instances (`GITLAB_CA_CERT_PATH`).
- `jobToken = redact.file { path = "…"; }` — set `GITLAB_JOB_TOKEN` for
  CI-scoped operations that prefer the job token over the PAT.

## OAuth and other deferred env vars

The upstream OAuth surface (`GITLAB_USE_OAUTH`, the five `OAUTH_STATELESS_*`
knobs, `GITLAB_OAUTH_APP_ID`, etc.) is out of v1 scope. So are tool-policy
approval lists, native HTTP/SSE transport (we bridge stdio through `mcp-proxy`
instead), and proxy env vars (`HTTP_PROXY`, `HTTPS_PROXY`). All of these can be
set via the freeform `env = { ... }` escape hatch:

```nix
services.mcp-servers.servers.gitlab-mcp.env = {
  HTTP_PROXY = "http://proxy.example.com:3128";
};
```

| Env var                                   | Upstream                                                                                                                        | Reason deferred                                                                              |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `ENABLE_DYNAMIC_API_URL`                  | [`config.ts:87-88`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L87-L88)     | Per-session API URL routing; OAuth-adjacent                                                  |
| `GITLAB_AUTH_COOKIE_PATH`                 | [`config.ts:34`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L34)            | Niche auth path (cookie-based)                                                               |
| `GITLAB_GRAPHQL_URL`                      | [`index.ts:1934`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/index.ts#L1934)          | Auto-derived from `GITLAB_API_URL`; only override if hosting GraphQL on a non-default origin |
| `GITLAB_IS_OLD`                           | [`config.ts:36`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L36)            | Compatibility flag for old GitLab versions                                                   |
| `GITLAB_OAUTH_APP_ID`                     | [`config.ts:79`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L79)            | OAuth out of scope                                                                           |
| `GITLAB_OAUTH_CALLBACK_PROXY`             | [`config.ts:85`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L85)            | OAuth out of scope                                                                           |
| `GITLAB_OAUTH_SCOPES`                     | [`config.ts:80`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L80)            | OAuth out of scope                                                                           |
| `GITLAB_POOL_MAX_SIZE`                    | [`config.ts:211`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L211)          | Connection-pool tuning; default 100 is fine                                                  |
| `GITLAB_TOOL_POLICY_APPROVE`              | [`config.ts:56-58`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L56-L58)     | Fine-grained policy; revisit once consumers ask                                              |
| `GITLAB_TOOL_POLICY_HIDDEN`               | [`config.ts:60-62`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L60-L62)     | Fine-grained policy; revisit once consumers ask                                              |
| `HOST` / `PORT`                           | [`config.ts:192,196`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L192)      | HTTP-mode only — bridged through mcp-proxy                                                   |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | [`config.ts:202-204`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L202-L204) | Standard env names — picked up from process env via `env = {}` escape hatch                  |
| `MCP_SERVER_URL`                          | [`config.ts:78`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L78)            | OAuth out of scope                                                                           |
| `NODE_TLS_REJECT_UNAUTHORIZED`            | [`config.ts:205`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L205)          | Standard Node flag; rarely set                                                               |
| `OAUTH_STATELESS_*` (5 vars)              | [`config.ts:96,141-186`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L96)    | OAuth out of scope                                                                           |
| `REMOTE_AUTHORIZATION`                    | [`config.ts:71`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L71)            | Part of OAuth surface                                                                        |
| `SESSION_TIMEOUT_SECONDS`                 | [`config.ts:171`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L171)          | Server tuning; defaults are fine                                                             |
| `SSE` / `STREAMABLE_HTTP`                 | [`config.ts:69-70`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/config.ts#L69-L70)     | Native HTTP/SSE transport — we use `mcp-proxy` bridge instead                                |
