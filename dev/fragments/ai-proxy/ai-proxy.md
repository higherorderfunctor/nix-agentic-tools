## Named CPA routing for Harnesses

> **Last verified:** 2026-10-22 — Instances own named upstream credentials and
> client keys; Harnesses select `instance` + `clientKey` on Home Manager and
> devenv.

CPA means the local CLIProxyAPI proxy. An Instance is
`ai.cliproxyapi.instances.<name>`. A Harness is Claude Code or Codex CLI. A
Vendor is Anthropic, OpenAI or z.ai; `oauth.vendor` uses CPA's provider field
(`claude`, `codex`). A client key is the secret a Harness presents to CPA. An
upstream credential is either an OAuth login CPA writes to its auth directory or
an API key declared in Nix. An allowlist rule is an `access.key-allowlist`
entry's credential rule.

### Declare once, route by name

An Instance's `credentials.<name>` declares exactly one of `oauth` or `apiKey`.
`clientKeys.<name>` holds a redact `key` and an ordered `routes` list. Each
route names `credential` and, for an API-key credential serving several APIs,
`api`. Omit `api` for OAuth; a single-API credential selects its sole API
automatically. CPA translates Harness protocols, so a Codex client key can
select a chat-only credential. An unserved API or unknown credential is an
evaluation error naming the input.

```nix
{inputs, ...}: let
  redact = inputs.nix-agentic-tools.lib.redact;
  secret = name: redact.file "/run/user/1000/secrets/${name}";
  route = credential: {inherit credential;};
  client = name: routes: {key = secret name; inherit routes;};
in {
  ai.cliproxyapi.instances.main = {
    credentials = {
      chatgpt-oauth-personal.oauth = {
        authFile = "codex-personal.json";
        vendor = "codex";
      };
      chatgpt-oauth-work.oauth = {
        authFile = "codex-work.json";
        vendor = "codex";
      };
      claude-api-personal.apiKey = {
        apis.anthropic.base-url = "https://api.anthropic.com";
        key = secret "claude-api-personal";
        models = ["claude-sonnet-4-6"];
      };
      claude-oauth-personal.oauth = {
        authFile = "claude-personal.json";
        vendor = "claude";
      };
      claude-oauth-work.oauth = {
        authFile = "claude-work.json";
        vendor = "claude";
      };
      zai-api-personal.apiKey = {
        apis.anthropic.base-url = "https://api.z.ai/api/anthropic";
        key = secret "zai-api-personal";
        models = ["glm-5.3"];
      };
    };
    clientKeys = {
      claude-personal = client "claude-personal" [
        (route "claude-oauth-personal")
        (route "claude-api-personal")
        (route "zai-api-personal")
      ];
      claude-work = client "claude-work" [(route "claude-oauth-work")];
      codex-personal = client "codex-personal" [
        (route "chatgpt-oauth-personal")
        (route "zai-api-personal")
      ];
      codex-work = client "codex-work" [(route "chatgpt-oauth-work")];
    };
  };
  ai.claude = {
    enable = true;
    proxy = {instance = "main"; clientKey = "claude-personal";};
  };
  ai.codex = {
    enable = true;
    proxy = {instance = "main"; clientKey = "codex-personal";};
  };
}
```

Replace the illustrative OAuth filenames with filenames from
`ls <stateDir>/auth` after CPA login. CPA 8.0.38's
`internal/watcher/synthesizer/file.go` assigns the file's path relative to the
auth directory as its ID; `internal/auth/claude/filename.go` includes
organization/account identity in Claude filenames. Re-login can produce a new
name: update `authFile`, then restart the Instance. `authFile` accepts one
nonempty JSON filename without path separators or leading ASCII whitespace. CPA
compares allowlist IDs exactly; filenames must match byte for byte.

For devenv, `redact.file "/run/user/<uid>/secrets/<name>"` can read the file
sops-nix already decrypted through Home Manager. Substitute your UID and secret
name. The declarations retain references; the shared service launcher resolves
upstream credentials at start, and `lib/ai/proxy/key-helper.nix` resolves client
keys when either Harness asks. Secret values stay out of generated store files
and evaluation output.

OAuth lowers to `provider = vendor`, `kind = "oauth"`, `ids = [authFile]`; API
keys lower through `packages/cliproxyapi/lib/providers.nix` into
`settings.api-keys` plus `kind = "apikey"` and exact `base-urls`. Shared base
URLs in the same CPA credential family fail evaluation because they would widen
a rule. Printable ASCII URL constraints keep CPA's Unicode trimming from
changing that comparison. Named client keys also cannot have a second
hand-written access entry.

The Vendor sees CPA's OAuth login. The selected client key decides personal/work
access; separate local Harness state requires `CLAUDE_CONFIG_DIR` or
`CODEX_HOME`. Overlapping models across a client's credentials are spread by CPA
today. Route list order is preserved in generated rules and Claude picker rows;
it does not define CPA priority or fallback. Model overlap enforcement,
per-client routing order/fallback and account prefixes are deferred.

### Selection and delivery

`lib/ai/proxy/default.nix` owns selection types, validation and resolution.
`sharedOptions.nix` declares `ai.proxy`; `mkBackendTransform.nix` declares the
same selection for consuming Harnesses and `normalized.proxy`. A per-Harness
selection replaces the root selection whole. Instance selection reads the named
client key and resolves `http://127.0.0.1:<port>`; it publishes nothing.
Missing/disabled Instances and unknown client keys fail evaluation. `url` +
redact `key` selects an external CPA and adds no Instance keys or rules. Origins
cannot contain a path.

Resolved `{key; url; credentials;}` carries names and declared API-key models in
route order. Claude gets picker rows through its user settings or devenv
launcher; Codex discovers CPA's catalog and writes no per-credential profiles.
Other runtimes warn through their declared surface support.
`ai.mcpServers.<name>.proxy` is an unrelated MCP credential proxy.

`module-ai-proxy-instance-clients` checks exact OAuth IDs (two logins of one
Vendor), API rules, model rows, external selection and refused inputs on both
backends. `module-service-instances-runtime-providers` sends requests through
packaged CPA to stand-in upstreams; CI runs it.
