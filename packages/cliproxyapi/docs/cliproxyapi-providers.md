## ai.settings.inference providers: CLIProxyAPI upstream credentials

> **Last verified:** 2026-10-30 — OAuth upstream credentials require vendor and
> a secret account email; named API-key credentials can select the built-in z.ai
> or OpenCode Go vendor defaults and a priority, and serve per-API models.

How a harness selects an instance and its client key is in
`dev/fragments/ai-inference/ai-inference.md`; this covers the upstream
credentials an instance's client routes reach.

`ai.cliproxyapi.instances.<n>.credentials.<name>` declares exactly one of
`oauth` or `apiKey`. OAuth requires `vendor` (CPA's provider name, such as
`claude` or `codex`) and `account`, a redact reference holding the account
email:

```nix
credentials.personal.oauth = {
  account = secret "claude-personal-email";
  vendor = "claude";
};
```

Each route becomes `provider = vendor`, `kind = "oauth"`, and
`accounts = [<account reference>]`. The shared settings renderer lifts that
reference into a secret placeholder; the existing service file launcher fills it
at start. CPA compares the login's native `AccountInfo()` email and the rule's
account after trimming whitespace, case-sensitively. Empty emails never match.
Multiple logins with the same vendor and account are all eligible; a missing
account selects nothing. New logins become eligible when CPA registers them,
without restarting the service. Nix never names, renames or creates CPA login
files. Account references receive the same provider ordering and restart
triggers as other service secrets.

The pinned CPA 8.0.40's `sdk/cliproxy/auth/types.go:788` implements
`AccountInfo()`: OAuth reads trimmed `Metadata.email`, falling back to
`Metadata.service_account.client_email`. API keys never match `accounts` rules.

An `apiKey` declares `key`, `models` and `apis.<api>.base-url` for the
`anthropic`, `chat` or `responses` API. The API table in
`packages/cliproxyapi/lib/providers.nix` lowers each into CPA's credential
family; the settings list joins these blocks with hand-written blocks. A route
can select `api`; omitting it selects a credential's sole API, and a multi-API
credential requires it. OAuth routes omit `api`. Unknown credentials and
unserved APIs fail evaluation. Generated API-key rules use the selected API's
provider, `kind = "apikey"`, and exact `base-urls`.

`apis.<api>.models` replaces `models` for that API's block, so one key can serve
a different catalog per API; every served API needs one of the two, or
evaluation fails.

CPA trims base URLs with Go's `strings.TrimSpace`, which Nix cannot reproduce
for every Unicode space. Provider URLs are printable ASCII, hand-written URLs in
their family must have printable edges, and blocks in that family cannot share
the provider's URL. These checks make CPA's exact match agree with Nix's.
API-key credential names use letters, digits, `.`, `_` and `-`, starting with a
letter or digit, so Go and Nix normalize their compatibility-provider identities
alike.

`normalized.settings.inference.credentials` is `[{name; models;}]` in client
route order, each with the models of the route's resolved API. Claude turns
declared API-key models into `/model` picker rows; Codex discovers CPA's catalog
without per-credential `-p` profiles
(`dev/fragments/ai-inference/ai-inference-runtimes.md`). Route list order is
preserved in generated rules and picker rows; it does not define CPA priority or
fallback. `apiKey.priority` is an optional integer, omitted from CPA config when
unset; CPA defaults it to 0. Higher values win among available credentials for
the requested model; credentials in cooldown are skipped. For an overlapping
subscription login and API key, allow both in the client's routes and set
`credentials.claude-api-personal.apiKey.priority = -1` to prefer the
default-priority OAuth login and use the API key when that login is unavailable.
If both priorities are 0, CPA selects within that tier using `routing.strategy`.
OAuth priority lives in CPA's login file metadata, so `oauth.priority` is not a
Nix option; this declaration never edits login files. For Codex and xAI
WebSocket requests, CPA can prefer a WebSocket-capable credential even at a
lower priority than an HTTP-only credential. Existing session affinity can keep
using a bound credential after a higher-priority one recovers. Per-client
routing order/fallback and account prefixes are deferred.

Built-in `vendor = "z-ai"` defaults
`apiKey.toolAliases = {ToolSearch = "ToolSearch_";}` for Anthropic and
`apiKey.codexShellArgCleanup = true` for chat-to-Responses shell calls,
repairing measured tool-name and empty-justification failures. Explicit
`toolAliases = {};` and `codexShellArgCleanup = false;` disable those defaults;
other vendors omit both settings unless requested. `vendor = "opencode-go"`
places each OpenCode Go model on its native API and refuses `claude-*`, `glm-*`
and `gpt-*` models (`cliproxyapi-settings.md`, Instances). Its blocks send
`x-opencode-session = "$CPA-SESSION-ID"`, which Go requires and CPA expands to
its session identifier; the header type is secret, so the literal reaches the
config through a store command reference.

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
        account = secret "chatgpt-personal-email";
        vendor = "codex";
      };
      chatgpt-oauth-work.oauth = {
        account = secret "chatgpt-work-email";
        vendor = "codex";
      };
      claude-api-personal.apiKey = {
        apis.anthropic.base-url = "https://api.anthropic.com";
        key = secret "claude-api-personal";
        models = ["claude-sonnet-4-6"];
      };
      claude-oauth-personal.oauth = {
        account = secret "claude-personal-email";
        vendor = "claude";
      };
      claude-oauth-work.oauth = {
        account = secret "claude-work-email";
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
    settings.inference = {instance = "main"; clientKey = "claude-personal";};
  };
  ai.codex = {
    enable = true;
    settings.inference = {instance = "main"; clientKey = "codex-personal";};
  };
}
```

For devenv, `redact.file "/run/user/<uid>/secrets/<name>"` can read a secret
sops-nix already decrypted through Home Manager. Substitute your UID and secret
name. The service launcher resolves upstream keys at start; the shared
`lib/ai/inference/key-helper.nix` resolves the selected client key when a
harness asks. Values remain outside generated store files and evaluation output.
