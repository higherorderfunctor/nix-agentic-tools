# CLIProxyAPI typed settings

> **Last verified:** 2026-10-21 — 909 config nodes give the settings type
> through `lib/extracted/options.nix`, with five refinements; the clean render
> passes native v8 validation and loads through CPA's `LoadConfig` in
> `cliproxyapi-settings`; `ai.cliproxyapi.instances` renders it at start,
> defaults its listener to loopback, and turns off the unprompted fetches the
> pinned CPA has a switch for.

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
only: `access.api-keys[]`, `management.secret-key`, `server.github-token`,
`requests.proxy-url`, the ICE server `credential`, and per upstream family the
group and key `proxy-url`, `headers.<name>` and `api-key`. A proxy URL or a
header that holds no credential still takes a reference (`redact.file` or
`redact.command`), since the type cannot tell which values carry one.

`render settings` gives `{ content; secrets; }`: config.yaml as JSON text with
each secret a `{$CLIPROXYAPI_<PATH>}` placeholder, list positions included
(`{$CLIPROXYAPI_API_KEYS_CLAUDE_0_KEYS_0_API_KEY}`). CLIProxyAPI rewrites its
config file at load: it replaces a plaintext `management.secret-key` with its
bcrypt hash and drops conflicting legacy keys. The rendered file must therefore
be a writable copy, never the store path.

## Refinements

Each narrows a measured type using a native constraint in `internal/config/`:

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
