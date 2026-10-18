# CPA Manager Plus typed settings

> **Last verified:** 2026-10-18 — 27 config.json keys and 32 environment
> variables give the settings type through `lib/extracted/options.nix`; the
> render loads through Manager Plus 1.14.7's `LoadWithoutCreatingDefault`.

`lib/default.nix` exports
`cpa-manager-plus.{settingsType, render, report, exclusions, sample}`. One
generated tree holds both surfaces: `config` is config.json and `environment`
the variables Manager Plus reads, from `extract/rules.nix`'s reconciled entries.
The shared rules are in `dev/fragments/extracted/typed-settings.md`. No module
option uses it yet.

## Secrets live in the environment

config.json names key files, never keys, so its render lifts nothing. The keys
are the three annotated variables `CPA_MANAGEMENT_KEY`, `CPA_MANAGER_ADMIN_KEY`
and `CPA_MANAGER_DATA_KEY`, typed as redact references. Every other variable is
a string, as Manager Plus reads it; `readBy` and `configKeys` are prose the type
does not carry (`unread`).

`render settings` gives `{ content; secrets; environment; }`: config.json as
JSON text, and the set variables, nulls dropped, ready for an option of type
`redact.types.environment`. `CPA_MANAGER_CONFIG` is excluded: the launcher
points it at the rendered config.json.

## Check

`cpa-manager-plus-settings` evaluates `sample` through `settingsType`, passes
the rendered environment through `redact.types.environment`, and runs
`checks/settings_test.go` in `internal/config`. It decodes the config into
`fileConfig` with unknown keys refused (the loader ignores them), sets the
environment with a dummy for each reference, and calls
`LoadWithoutCreatingDefault`; `CPA_MANAGEMENT_KEY` must reach the loaded config.
The one override, `USAGE_ARCHIVE_RETENTION_DAYS = "30"`, is a variable the
loader parses as an integer and refuses otherwise.
