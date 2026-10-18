# CLIProxyAPI typed settings

> **Last verified:** 2026-10-18 — 905 config nodes give the settings type
> through `lib/extracted/options.nix`, with four refinements; the render loads
> through CPA 8.0.33's `LoadConfig` in `cliproxyapi-settings`.

`lib/default.nix` exports
`cliproxyapi.{settingsType, render, report, refinements, sample}`. The type is
generated from `config`'s reconciled entries (`extract/rules.nix`), so a path
the extraction adds or drops moves the type with the next regeneration; the
shared rules are in `dev/fragments/extracted/typed-settings.md`. No module
option uses it yet: a service instance renders it at start.

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

Each narrows a measured type to what the loader accepts, citing the refusal in
`internal/config/`:

- `config-version`: `enum [8]` (`config_v8.go`, "unsupported config-version
  (expected 8)").
- `credentials.in-flight.{snapshot-interval,stale-after,staging-retention}`:
  measured `string`, typed as a Go duration, because `Durations` in
  `credential_in_flight.go` refuses the config when `time.ParseDuration` fails.
- `multimedia.disable-image-generation`: measured `any` (its custom decoder),
  typed `bool` or `"chat"`/`"passthrough"` (`disable_image_generation_mode.go`).

Cross-field rules stay outside the type: `stale-after` at least three snapshot
intervals, in-flight byte bounds, live media relay port ranges, trusted proxies
as IPs or CIDRs, catalogs as http(s) URLs or absolute paths.

## Check

`cliproxyapi-settings` evaluates `sample` through `settingsType` with overrides
for those cross-field rules, renders it, fills each placeholder with a dummy
holding `"`, `'` and `\`, and runs `checks/settings_test.go` in
`internal/config`: `LoadConfig` twice (the second load reads the first one's
rewrite, as a restart does), and `requests.proxy-url` must read back verbatim.
