# CLIProxyAPI typed settings

> **Last verified:** 2026-10-23 — 928 config nodes, including the patched
> `access.key-allowlist`, give the settings type through
> `lib/extracted/options.nix`, with refinements and module assertions on the
> allowlist; the clean render passes native v8 validation and loads through CPA
> 8.0.40's `LoadConfig` in `cliproxyapi-settings`; `ai.cliproxyapi.instances`
> renders it at start, defaults its listener to loopback, turns off the
> unprompted fetches the pinned CPA has a switch for, types `server.tls.key` as
> a secret file, and derives named client keys' `access.api-keys` and
> `access.key-allowlist` entries from named upstream routes. Built-in
> `vendor = "z-ai"` defaults upstream API-key models and APIs from pinned
> official documentation, chat to z.ai's Coding Plan endpoint. Named API-key
> credentials accept an optional integer priority, omitted when unset.

`lib/default.nix` exports
`cliproxyapi.{settingsType, render, report, refinements, sample}`. The type is
generated from `config`'s reconciled entries (`extract/rules.nix`), so a path
the extraction adds or drops moves the type with the next regeneration; the
shared rules are in `dev/fragments/extracted/typed-settings.md`.

## Instances

`ai.cliproxyapi.instances.<name>` (`modules/instances.nix`, through
`packages/ai-module/lib/instances.nix`) runs CLIProxyAPI as the service
`cliproxyapi-<name>` on both backends. `port` (8317) fixes `server.port`;
`settings.server.host` defaults to `127.0.0.1` through `mkDefault`, so a
consumer can explicitly override the bind address. `stateDir`
(`<state root>/cliproxyapi/<name>`) fixes `oauth.auth-dir` to `<stateDir>/auth`,
where CLIProxyAPI writes its OAuth logins. The launcher renders the settings to
`config.json` at each start and the run script, inside `stateDir` so the `.env`
and `logs/` CLIProxyAPI resolves against its working directory are its own,
execs `cliproxyapi --config "$CPA_CONFIG"`. CLIProxyAPI's rewrites of its config
reach only that copy and are lost at restart. `ai.proxy.instance` points the
harnesses at an instance by name.

`credentials` and `clientKeys` declare upstream credentials and client access
once on the Instance. Harnesses select
`proxy = {instance = "main"; clientKey = "claude-personal";}`. Shape, a
four-client example, required OAuth vendor/account selection and devenv secret
references and the overlapping subscription/API-key recipe using
`apiKey.priority = -1` are in `dev/fragments/ai-proxy/ai-proxy.md`. Priority
applies to every API served by the credential; OAuth priority belongs to CPA's
login file metadata and cannot be set through `oauth`.

For the built-in z.ai vendor, the upstream credential needs only its secret:

```nix
ai.cliproxyapi.instances.main.credentials.zai-api-personal = {
  vendor = "z-ai";
  apiKey.key = redact.file "/run/secrets/zai-api-key";
};
```

`apiKey.apis` defaults chat to z.ai's Coding Plan endpoint
(`https://api.z.ai/api/coding/paas/v4`) and Anthropic to the Anthropic endpoint
(`https://api.z.ai/api/anthropic`), and `apiKey.models` to z.ai's published
general API chat catalog. Override either endpoint's `base-url`, set an API to
`null`, or replace `models` with the subset your upstream credential permits,
such as pointing chat at the general API endpoint:

```nix
apiKey.apis.chat.base-url = "https://api.z.ai/api/paas/v4";
```

Billing depends on the key type; check the key classification and entitlements
in z.ai's
[API Key Management Guide](https://docs.z.ai/devpack/notice/api-key-management).
The defaults describe the Coding Plan endpoint, not a guarantee of account
access. Client keys still choose this credential and its API through `routes`;
selecting `api = "chat"` lets CPA translate a Codex CLI Responses request to
chat.

The measured Claude Code tier mapping and timeout remain extraction data. The
existing per-client-key model list carries model IDs for picker rows, without
vendor or tier intent; it cannot safely supply Claude Code environment defaults.

## Unprompted network calls

The pinned CPA starts four background fetchers that need no request and no
credential, each at start and every 3 hours after. The instance module turns off
the ones CPA has a switch for:

| Call                                                                                    | Switch                                                         | Instance default                           |
| --------------------------------------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------ |
| Model catalogs (general, Codex, Devin): raw.githubusercontent.com, models.router-for.me | `--local-model` flag; no setting selects the embedded catalogs | off: the run script passes `--local-model` |
| Management panel: api.github.com and a router-for.me fallback                           | `management.disable-auto-update-panel`                         | off: `mkDefault true`                      |
| Antigravity client version: antigravity-hub-auto-updater Cloud Run manifest             | none                                                           | still on                                   |
| Grok CLI version: registry.npmjs.org                                                    | none                                                           | still on                                   |

To turn one back on, set
`ai.cliproxyapi.instances.<name>.fetchModelCatalogs = true` (the run script
drops `--local-model`) or
`settings.management.disable-auto-update-panel = false`. An explicit
`settings.models.{catalog,codex-catalog,devin-catalog}` source wins over
`--local-model` and is read from its URL or file at the same cadence.

Three more calls happen only on demand and stay: the management panel download
when `/management.html` is requested and the file is missing (any request
triggers it; the download may send a GitHub token from `server.github-token` or
the service environment; `management.disable-control-panel = true` closes it),
the management API's `latest-version` and plugin-store routes, and the public-IP
lookup during an interactive OAuth login. Provider traffic for logins a consumer
added (token refresh, entitlements) is not an unprompted call.

The two calls without a switch send no credential and no request content, only a
GET for a version string, and fail soft to a pinned fallback. Silencing them
takes a patch to CPA, not a setting; that is an open decision.

## Secrets

Every path an `extract/annotations.json` row marks takes a redact reference
only: `access.api-keys[]`, `access.key-allowlist[].api-key`,
`access.key-allowlist[].credentials[].accounts[]`, `management.secret-key`,
`server.github-token`, `requests.proxy-url`, the ICE server `credential`, and
per upstream family the group and key `proxy-url`, `headers.<name>` and
`api-key`. A proxy URL or a header that holds no credential still takes a
reference (`redact.file` or `redact.command`), since the type cannot tell which
values carry one.

`server.tls.key`, the TLS private key file, is a `secretFile` node: it takes a
reference, which the service launcher writes to a 0600 file that the rendered
config names (`dev/fragments/redact/redact.md`, Secret files). `server.tls.cert`
stays a plain path.

`render settings` gives `{ content; secrets; }`: config.yaml as JSON text with
each secret a `{$CLIPROXYAPI_<PATH>}` placeholder, list positions included
(`{$CLIPROXYAPI_API_KEYS_CLAUDE_0_KEYS_0_API_KEY}`). CLIProxyAPI rewrites its
config file at load: it replaces a plaintext `management.secret-key` with its
bcrypt hash and drops conflicting legacy keys. The rendered file must therefore
be a writable copy, never the store path.

## Refinements

Each narrows a measured type using a native constraint in `internal/config/`, or
in the allowlist patch:

- `access.key-allowlist[].credentials[].accounts`: account elements are secret
  references. A module assertion refuses empty lists and null elements because
  dropping them could lift the account restriction. Named OAuth credentials
  require an account reference and use the same rendered service file as keys.
- `access.key-allowlist[].credentials[].{base-urls,ids}`:
  `nonEmptyListOf elementType`, the generated string type. The patch reads an
  empty or absent list as no restriction on that dimension, and the renderer
  drops null elements, so an empty list, or `[null]`, would widen the rule to
  every credential of its provider and kind. The type checks definitions, so
  `[(mkIf false "x")]` passes it and merges to `[]`; a module assertion
  (`modules/instances.nix`) refuses any merged empty list. Leave the option
  unset to leave a dimension open.
- `access.key-allowlist[].credentials[].kind`: `enum ["apikey" "oauth"]`; the
  patch matches a rule only when its kind normalizes to a credential kind
  (`normalizeAuthKind`), so any other value would silently allow nothing.
- `client.codex.web-search-result-cache.ttl`: measured `string`, typed as a Go
  duration, because `Validate` in `sdk_config.go` refuses a TTL that is neither
  a duration nor integer seconds; the type admits the duration form only.
- `config-version`: `enum [8]` (`config_v8.go`, "unsupported config-version
  (expected 8)").
- `credentials.in-flight.{snapshot-interval,stale-after,staging-retention}`:
  measured `string`, typed as a Go duration, because `Durations` in
  `credential_in_flight.go` refuses the config when `time.ParseDuration` fails.

The duration refinement checks grammar only; positivity, numeric bounds and
overflow remain native validation. `multimedia.disable-image-generation` keeps
the extracted `any` type, including native string aliases such as `"off"`.

`access.key-allowlist` itself has no refinement. Its elements hold the secret
`api-key`, and the generator refuses a refinement row on a node with a secret
descendant. A module assertion on the merged value (`modules/instances.nix`)
refuses any null entry instead: the renderer drops nulls, so a list of only
nulls, or `[null]`, would render as `[]`, which the patch reads as no allowlist,
and enforcement would be off for every key. An explicit `[]` stays valid.

Cross-field rules stay outside the type: `stale-after` at least three snapshot
intervals, in-flight byte bounds, live media relay port ranges, trusted proxies
as IPs or CIDRs, catalogs as http(s) URLs or absolute paths.

## Check

`cliproxyapi-settings` evaluates `sample` through `settingsType`, with valid
overrides for raw JSON payload params, the Claude client-request-id mode and
cross-field rules. It renders and substitutes dummy secrets, including a proxy
URL with quotes, backslash, colon, hash, brackets, newline and a literal
placeholder. `checks/settings_test.go` validates the clean v8 sample with native
`ValidateV8Config` and rejects an unknown-key control, then injects a
conflicting legacy proxy key and calls `LoadConfig` twice on a writable copy. It
checks both raw payload rules survive, the rewritten file persists the bcrypt
hash and removes the legacy key, every other document value stays equal after
JSON normalization, and the hash and secret remain unchanged on reload.

`module-service-instances-real-daemons` starts the packaged CPA and Manager Plus
through their evaluated Home Manager instance units with runtime dummy secret
files, polls both health endpoints, and checks both listeners are on loopback.
It exists only on Linux. The stand-in instance check separately pins argv,
working directory and state-directory modes.
