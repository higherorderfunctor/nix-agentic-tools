## ai.proxy: local proxies for AI harnesses

> **Last verified:** 2026-10-28 — proxy owners (CLIProxyAPI with named clients,
> Airlock clientless) register instances in `ai.internal.proxyInstances`; root
> fields copy down by priority and drop for a runtime selecting the other form;
> the selected instance's backend picks the one lowering a runtime runs. OAuth
> upstream credentials require vendor and a secret account email; named API-key
> credentials can select the built-in z.ai vendor defaults and a priority.

`ai.proxy` points a harness at a local proxy. A CLIProxyAPI instance holds the
logins, so the harness holds only the proxy's client key, never an upstream
credential. An Airlock instance is an HTTPS CONNECT proxy; the harness keeps its
own credentials. `ai.mcpServers.<name>.proxy` (lib/ai/mcpProxy.nix) is an
unrelated MCP credential proxy.

### Shape

- Library: `lib/ai/proxy/default.nix`. Options, the registry, validation,
  `resolve` and the lowering dispatch `lower` live there; it names no proxy
  owner except that an external `url` lowers as `cliproxyapi`.
- `sharedOptions.nix` registers the root option and `ai.internal.proxyInstances`
  and asserts the root selection.
- `proxy` is a key of `sharedSurfaceOptions`, so it is a delivery-policy surface
  and every enabled runtime whose `surfaceSupport` omits `proxy` gets the
  standard decomposition warning. Claude and Codex declare support; the other
  runtimes warn rather than dropping a selection silently.
- `mkBackendTransform.nix`, for a record whose `surfaceSupport` declares
  `proxy`, declares `ai.<runtime>.proxy` with the root's selection options and
  `ai.<runtime>.normalized.proxy`. The callbacks get it as `normalized.proxy`
  and `resolvedProxy`. Harness selection publishes no keys, rules or claims;
  these belong to the selected instance's named entries.

### Registry

A proxy owner adds each instance to `ai.internal.proxyInstances.<name>` by
ordinary module merge: `{backend; enable; url; clients; trust;}`. `backend` is
the owner's name (`ai.<backend>`). `clients.<clientKey> = {...}` holds the
attributes that backend's lowering reads for each named client; an owner whose
instances have no clients leaves `clients` null, and its instances are selected
by name alone. The owner also claims each name in `ai.claims.proxy-instance`
(`ai.<owner>.claims.proxy-instance`), so two owners registering one name fail
evaluation through the claims registry. CLIProxyAPI registers every
`ai.cliproxyapi.instances` entry (`packages/cliproxyapi/modules/instances.nix`)
at `http://127.0.0.1:<port>`, each client key carrying `{key; credentials;}`.
Airlock registers every `ai.airlock.instances` entry
(`packages/airlock/modules/instances.nix`) at the same loopback origin with no
clients. `trust`, null by default, is an executable printing the CA bundle a
client must trust; Airlock sets it for an intercepting instance, and `resolve`
passes it to the lowering when set. The registry is internal: a root option
would count as a consumer surface and fan out.

### Selection and the resolved endpoint

A selection is `url` + `key` for a CPA configured by hand, or `instance` for a
registered instance; `url` and `instance` are mutually exclusive. An instance
that declares clients needs `clientKey` naming one of them; a clientless
instance refuses one. Unregistered or disabled instances, unknown or unwanted
client keys, and incomplete selections fail as assertions at either scope,
outside the runtime enable gate. An external selection without a key is rejected
because the harness would send its own login token, if any, to the proxy.

Each root field copies down to `ai.<runtime>.proxy` at `mkDefault`, so a runtime
value wins field by field: root `instance = "a"` with
`ai.claude.proxy.instance = "b"` gives Claude `b` with the root's `clientKey`. A
runtime opts out of an inherited selection with `instance = null` (or
`url = null` for an external one); the fields it leaves behind are ignored,
since an unselected runtime is checked only on the fields it changed. A runtime
selection equal to the root's is asserted once, at `ai.proxy`. A runtime that
selects the other form (`instance` under a root `url`, or `url` under a root
`instance`) inherits none of the root's fields of that form, so switching forms
clears nothing by hand; within one form the per-field override still applies.
`copyDown` keeps that test inside each copied value, which reads the runtime's
other selector only while the root's is null, so no copy reads itself back.

The resolved value is null or `{backend; url;}` plus the selected client's
attributes when the instance declares clients; an external selection resolves to
`{backend = "cliproxyapi"; key; url; credentials = [];}`. `url` is the origin
only: each runtime appends its own protocol path, so a path would be doubled.
Each runtime's proxy library keeps `lowerings.<backend>` and calls
`lower <runtime> lowerings resolved`, so only the selected backend's lowering
runs, and a backend the runtime has no lowering for fails evaluation.

An external `key` or an instance client entry's `key` requires
`redact.types.redacted`: `redact.file`, `redact.command` or `redact.concat` with
a reference. It authenticates access to the proxy's upstream subscriptions, so
cleartext has no harmless use here. Root and per-runtime options use the same
type as the normalized endpoint.

References remain unresolved during evaluation. A consuming runtime must use
`redact.assign` when its launcher or credential helper starts and escape the
resolved value for its destination format. A key's contents cannot be
charset-checked at evaluation; never substitute the runtime value unescaped into
JSON, TOML or shell source. The `url` pattern validates only the proxy origin.

### Runtime keys and the allowlist

An instance declares `clientKeys.<name> = {key; routes;}`. Each route names an
upstream `credential`; the instance adds the key to `access.api-keys` and maps
its routes to its `access.key-allowlist` entry. The launcher presents the same
key through `normalized.proxy`; CPA fails closed for each listed key (see
`cliproxyapi-key-allowlist.md`). Runtime `proxy.allow` and `proxy.providers` are
removed: selecting a client key selects its declared routes.

A harness must not define the instance: that would make a misspelled name look
valid, and checking existence from the definition would recurse. Multiple
harnesses can select the same named client key. A client key decides upstream
access; separate local harness state requires `CLAUDE_CONFIG_DIR` or
`CODEX_HOME`.

### Providers

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

CPA trims base URLs with Go's `strings.TrimSpace`, which Nix cannot reproduce
for every Unicode space. Provider URLs are printable ASCII, hand-written URLs in
their family must have printable edges, and blocks in that family cannot share
the provider's URL. These checks make CPA's exact match agree with Nix's.
API-key credential names use letters, digits, `.`, `_` and `-`, starting with a
letter or digit, so Go and Nix normalize their compatibility-provider identities
alike.

`normalized.proxy.credentials` is `[{name; models;}]` in client route order.
Claude turns declared API-key models into `/model` picker rows; Codex discovers
CPA's catalog without per-credential `-p` profiles (`ai-proxy-runtimes.md`).
Route list order is preserved in generated rules and picker rows; it does not
define CPA priority or fallback. `apiKey.priority` is an optional integer,
omitted from CPA config when unset; CPA defaults it to 0. Higher values win
among available credentials for the requested model; credentials in cooldown are
skipped. For an overlapping subscription login and API key, allow both in the
client's routes and set `credentials.claude-api-personal.apiKey.priority = -1`
to prefer the default-priority OAuth login and use the API key when that login
is unavailable. If both priorities are 0, CPA selects within that tier using
`routing.strategy`. OAuth priority lives in CPA's login file metadata, so
`oauth.priority` is not a Nix option; this declaration never edits login files.
For Codex and xAI WebSocket requests, CPA can prefer a WebSocket-capable
credential even at a lower priority than an HTTP-only credential. Existing
session affinity can keep using a bound credential after a higher-priority one
recovers. Per-client routing order/fallback and account prefixes are deferred.

Built-in `vendor = "z-ai"` defaults
`apiKey.toolAliases = {ToolSearch = "ToolSearch_";}` for Anthropic and
`apiKey.codexShellArgCleanup = true` for chat-to-Responses shell calls,
repairing measured tool-name and empty-justification failures. Explicit
`toolAliases = {};` and `codexShellArgCleanup = false;` disable those defaults;
other vendors omit both settings unless requested.

A named client key also listed by hand in `access.api-keys`, or given a
hand-written `access.key-allowlist` entry, is refused: a second owner could
widen or contradict its routes. Evaluation compares references, not secret
values; distinct references resolving to the same key are rejected by CPA at
startup or leave the old config on reload.

An external `url` selection adds no instance keys or rules. A hand-written key
of another client stays allowed, but once named client keys set the allowlist,
that key needs its own hand-written entry.

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
    proxy = {instance = "main"; clientKey = "claude-personal";};
  };
  ai.codex = {
    enable = true;
    proxy = {instance = "main"; clientKey = "codex-personal";};
  };
}
```

For devenv, `redact.file "/run/user/<uid>/secrets/<name>"` can read a secret
sops-nix already decrypted through Home Manager. Substitute your UID and secret
name. The service launcher resolves upstream keys at start; the shared
`lib/ai/proxy/key-helper.nix` resolves the selected client key when a harness
asks. Values remain outside generated store files and evaluation output.

### Checks

`module-ai-proxy-instance-clients` checks generated blocks, named routes, exact
OAuth account placeholders, rules and refusals on both backends. The native
allowlist check covers account matching and hot-added logins.
`module-ai-proxy-z-ai-credential` checks vendor defaults and overrides on both
backends, including client routing and the preserved model list.
`module-service-instances-runtime-providers` sends Anthropic and Responses
requests through the packaged CPA, including a Codex CLI client key routed to a
chat-only upstream credential and an unauthorized-model negative control.
`airlock-instances` covers Airlock's registration and what selecting it gives
Claude and Codex. The other proxy checks cover selection, key references and
runtime delivery.
