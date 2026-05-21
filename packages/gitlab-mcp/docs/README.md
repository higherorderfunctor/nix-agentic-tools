# gitlab-mcp

[zereight/gitlab-mcp](https://github.com/zereight/gitlab-mcp) packaged
as a Nix derivation with a typed home-manager surface. Exposes 182
GitLab REST/GraphQL tools (merge requests, issues, pipelines, wikis,
work items, etc.) to MCP-aware clients (Claude Code, Copilot, Kiro).
Connects to gitlab.com by default; self-hosted instances are
configured per the "Instance URL" section below.

## Quick start (HM)

```nix
{ config, ... }: {
  services.mcp-servers.servers.gitlab-mcp = {
    enable = true;
    settings.pat.file = config.sops.secrets."gitlab-personal-access-token".path;
  };
}
```

The PAT (`GITLAB_PERSONAL_ACCESS_TOKEN`) is the only required
credential. The `settings.pat` option is the standard sops-nix /
agenix surface — `.file` reads a decrypted file at service start,
`.helper` reads from a credential-helper script. Exactly one must
be set; raw inline tokens are intentionally not supported (they
would land in the Nix store).

## Instance URL

Two ways to point at a non-default instance, mutually exclusive:

```nix
# Plain URL — lands in the Nix store. Use when the URL is public
# knowledge (e.g. a self-hosted instance everyone in the org knows).
services.mcp-servers.servers.gitlab-mcp.settings.instanceUrl =
  "https://gitlab.example.com";
```

```nix
# Credential form — keeps the URL out of the store. Use when the
# instance URL itself is sensitive.
services.mcp-servers.servers.gitlab-mcp.settings.apiUrl.file =
  config.sops.secrets."gitlab-instance-url".path;
```

Setting both raises an eval-time error. Both forms end up as
`GITLAB_API_URL` for the server.

## Trust posture knobs

By default every tool is enabled and every project the PAT can see
is reachable. Three sets of settings narrow that surface:

- `readOnly = true` — sets `GITLAB_READ_ONLY_MODE=true`; the server
  refuses tools that mutate state. Use when only read access is
  needed.
- `toolsets = [ "issues" "merge_requests" ]` — restrict to specific
  feature groups. Combines with `tools` (additive).
- `tools = [ "list_issues" "get_merge_request" ]` — fine-grained
  per-tool allowlist. See the upstream
  [`tools/registry.ts`](https://github.com/zereight/gitlab-mcp/blob/c2577169b21d62197f767895fe97651ffb2d7443/tools/registry.ts)
  for the 182 known v2.1.13 names. The type stays freeform `listOf
str` so consumers can opt into newer upstream tools without
  waiting for a repo bump.
- `deniedToolsRegex = "delete_.*"` — regex denylist applied after
  toolsets/tools. Use as a guardrail for the destructive surface.
- `allowedProjectIds = [ "42" "97" ]` — restrict tool calls to a
  specific set of project IDs (joined into
  `GITLAB_ALLOWED_PROJECT_IDS`). Pair with `defaultProjectId`
  if most calls target a single project.

## Optional features

- `useWiki = true` / `useMilestone = true` / `usePipeline = true` —
  enable the upstream `USE_GITLAB_WIKI` / `USE_MILESTONE` /
  `USE_PIPELINE` flags. Off by default to keep the default tool
  list small.
- `caCertPath = "/etc/ssl/certs/ca.pem"` — path to a CA bundle for
  self-signed GitLab instances (`GITLAB_CA_CERT_PATH`).
- `jobToken.file` — set `GITLAB_JOB_TOKEN` for CI-scoped operations
  that prefer the job token over the PAT.

## OAuth and other deferred env vars

The upstream OAuth surface (`GITLAB_USE_OAUTH`, the five
`OAUTH_STATELESS_*` knobs, `GITLAB_OAUTH_APP_ID`, etc.) is out of
v1 scope. So are tool-policy approval lists, native HTTP/SSE
transport (we bridge stdio through `mcp-proxy` instead), and
proxy env vars (`HTTP_PROXY`, `HTTPS_PROXY`). All of these can be
set via the freeform `env = { ... }` escape hatch:

```nix
services.mcp-servers.servers.gitlab-mcp.env = {
  HTTP_PROXY = "http://proxy.example.com:3128";
};
```

See `docs/plans/gitlab-mcp-packaging-slim.md` in the repo for the
full deferred-vars table with upstream source references.
