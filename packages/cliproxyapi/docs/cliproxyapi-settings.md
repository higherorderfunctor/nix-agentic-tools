# CLIProxyAPI typed settings

> **Last verified:** 2026-10-22 — 926 config nodes, including the patched
> `access.key-allowlist`, give the settings type through
> `lib/extracted/options.nix`, with eight refinements and one module assertion
> on the allowlist; the clean render passes native v8 validation and loads
> through CPA 8.0.38's `LoadConfig` in `cliproxyapi-settings`;
> `ai.cliproxyapi.instances` renders it at start, defaults its listener to
> loopback, turns off the unprompted fetches the pinned CPA has a switch for,
> types `server.tls.key` as a secret file, and derives named client keys'
> `access.api-keys` and `access.key-allowlist` entries from named upstream
> routes. `exactModels` applies native model exclusions and disables model
> rewrites.

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
four-client example, OAuth filename selection and devenv secret references are
in `dev/fragments/ai-proxy/ai-proxy.md`.

## Exact upstream models

`instances.<name>.exactModels = true` opts into exact upstream model names. It
defaults to false; unset and explicit false preserve the rendered config byte
for byte. This mode does not enable cpa-gate and is not a security boundary: a
harness sharing CPA's uid can read or change its credentials.

For each named OAuth upstream credential, set `credentials.<name>.models` XOR
`credentials.<name>.excludedModels`. Names must exist in the pinned embedded
vendor catalog: Claude's catalog or the union of Codex's four tiers. A Codex
tier may still lack a union member; this is a registration filter, not a promise
of account entitlement. For API-key upstream credentials, `apiKey.models`
remains the catalog; optional `credentials.<name>.excludedModels` must be a
subset. Every selected set and every supplied list must be nonempty. Names are
compared byte for byte; `auto`, parentheses, `/`, `*`, the `claude-fable-5-dd-`
prefix, spaces and non-ASCII names are refused.

OAuth exclusions lower to CPA's vendor-wide `oauth.excluded-models`; generated
API-key model lists lower after subtraction. Exact mode owns the final OAuth
exclusion map and API-key blocks; conflicting raw exclusions and hand-written
API-key blocks are refused. Claude and Codex API-key families collapse
case-distinct IDs, so their final selected lists must have no case-fold
collision. Excluding one of two colliding catalog names is valid; accepted
spelling and order are preserved. The vendor-wide exclusion map requires two
named OAuth logins of one vendor to select the same effective set, even when one
uses `models` and another its complement in `excludedModels`. OAuth vendors
other than `claude` and `codex`, and API-key families other than Claude, Codex
and generated OpenAI compatibility, are refused.

The mode requires embedded catalogs (`--local-model`) and refuses
`fetchModelCatalogs`, explicit `models.{catalog,codex-catalog,devin-catalog}`,
management secrets, payload rules, OAuth aliases, and API-key `prefix`, `alias`
or `cloak` settings. Home settings are already outside the typed settings
surface. The launcher owns argv and supplies no `-password`. Normal-priority
definitions turn off model prefixing, Claude cloaking and cloaked listings,
image injection, plugins, multi-agent optimization and Antigravity credit
fallback; conflicting settings fail evaluation.

Before every start the launcher scans auth JSON (case-insensitive `.json`
suffix, as CPA does) and refuses model aliases, prefixes, exclusions, cloak
metadata, malformed or duplicate JSON names, and unaudited vendors. It refuses
`MANAGEMENT_PASSWORD` in the environment and any state-directory `.env` file,
because CPA loads dotenv after the scan and it could enable management. Refusals
print no filenames, keys or model names. This scan does not police writes while
CPA runs: restart after changing login files; same-uid isolation still requires
a VM or separate uid.

The module checks cover both backends and each forced switch. CPA's package
check phase runs two capture-transport Go tests against the lowered config:
Claude OAuth adds no fallback model and Codex Responses adds no image tool. Each
turns its switch back on as a control that must observe the injection.

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
`management.secret-key`, `server.github-token`, `requests.proxy-url`, the ICE
server `credential`, and per upstream family the group and key `proxy-url`,
`headers.<name>` and `api-key`. A proxy URL or a header that holds no credential
still takes a reference (`redact.file` or `redact.command`), since the type
cannot tell which values carry one.

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
