# Typed LSP migration — `ai.lspServers` and per-CLI

> **Status:** plan only; proceeding autonomously.
>
> **Goal:** migrate `ai.lspServers` + `ai.<cli>.lspServers` from
> freeform `attrsOf (attrsOf anything)` to typed `lspServerModule`.
> Per-CLI factories invoke ecosystem-specific translators
> (`mkLspConfig` / `mkCopilotLspConfig` / new `mkClaudeLspConfig`)
> on emission. Removes DRY loss when declaring the same LSP for
> multiple CLIs; activates the typed module that's existed unused
> since factory rollout.

## Why

Today three LSP writes differ:

- **Kiro** writes `{command, args, ?initializationOptions}` to
  `<configDir>/settings/lsp.json` — direct freeform.
- **Copilot** writes `{command, args, ?fileExtensions, ?initializationOptions}`
  to `<configDir>/lsp-config.json` — `fileExtensions` is a Copilot-
  specific attrset mapping `.ext` → language name.
- **Claude** routes to upstream `programs.claude-code.lspServers`
  which writes `{command, args, ?extensionToLanguage}` into
  settings.json — `extensionToLanguage` is Claude-specific.

Consumer today can declare the SAME server three times with three
slightly-different shapes (`fileExtensions` for Copilot,
`extensionToLanguage` for Claude, nothing for Kiro). Typed schema
captures the common fields once; translators produce each
ecosystem's native shape from the single declaration.

## Existing but unused infrastructure

`lib/ai/ai-common.nix` already declares:

- `lspServerModule` submodule (args, binary, extensions,
  initializationOptions, package).
- `mkLspConfig` — Kiro/base shape renderer.
- `mkCopilotLspConfig` — Copilot shape (adds fileExtensions).

Missing: `mkClaudeLspConfig` (extensionToLanguage shape).

## Schema relaxations

Current `lspServerModule`:

- `package` is required (no default).
- `extensions` is required (no default).

Both constraints break common cases:

- Not every LSP has a nix package (e.g., user relies on PATH in a
  devenv shell, or uses an external binary).
- Not every LSP needs extensions declared (e.g., a server only
  invoked via CLI editor protocol without Copilot/Claude
  extension→language mapping).

Relaxations:

- `package`: `nullOr package`, default `null`. When set, command
  renders as `${package}/bin/${binary}`.
- `command`: NEW, `nullOr str`, default `null`. When set, used
  directly. Alternative to `package` + `binary`.
- `extensions`: `listOf str`, default `[]`. Skipped in translators
  when empty.
- At least one of `package` or `command` must be set; assertion
  enforces this.

## Per-ecosystem translators

### `mkLspConfig` (Kiro base)

```nix
mkLspConfig = _name: server: let
  cmd = resolveCommand server;
in
  { command = cmd; inherit (server) args; }
  // lib.optionalAttrs (server.initializationOptions != {}) {
    inherit (server) initializationOptions;
  };
```

`resolveCommand` shared helper: `server.command or "${server.package}/bin/${server.binary}"`.

### `mkCopilotLspConfig`

Kiro base + `fileExtensions` (Copilot shape):

```nix
// lib.optionalAttrs (server.extensions != []) {
  fileExtensions = mapExtensions server.extensions name;
}
```

where `mapExtensions` produces `{ ".ext" = name; }`.

### `mkClaudeLspConfig` (NEW)

Kiro base + `extensionToLanguage` (Claude shape):

```nix
// lib.optionalAttrs (server.extensions != []) {
  extensionToLanguage = mapExtensions server.extensions name;
}
```

(Same mapping structure as Copilot's `fileExtensions`, different
key name. Claude and Copilot both say `".ext" → language-name`.)

## Per-CLI factory wiring

All three factories currently write `mergedLspServers` as-is. After
migration:

- **Kiro HM + devenv:** `builtins.toJSON (mapAttrs mkLspConfig mergedLspServers)`
- **Copilot HM + devenv:** `builtins.toJSON (mapAttrs mkCopilotLspConfig mergedLspServers)`
- **Claude HM:** `programs.claude-code.lspServers = mapAttrs mkClaudeLspConfig mergedLspServers`

## Option type changes

- `ai.lspServers` in `sharedOptions.nix`: `attrsOf (attrsOf anything)`
  → `attrsOf lspServerModule`.
- `ai.kiro.lspServers` in `mkKiro.nix`: same.
- `ai.copilot.lspServers` in `mkCopilot.nix`: same.
- `ai.claude.lspServers` in `mkClaude.nix`: same.

Freeform → typed is the breaking change.

## Test updates

Existing LSP tests declare `{ command = "x"; args = [...]; }` —
these values are still valid typed shape (command field now exists
natively, args has default we'd override, no package/extensions).

Tests asserting native output still work — the translator produces
`{command, args}` when that's all the user specified.

New test additions:

- Verify `mkCopilotLspConfig` emits `fileExtensions` when extensions
  set.
- Verify `mkClaudeLspConfig` emits `extensionToLanguage` when
  extensions set.
- Verify package-based declaration renders `${package}/bin/${binary}`.

## Plan

### 1. Extend `lspServerModule` with relaxations + `command`

### 2. Add `mkClaudeLspConfig` + shared `resolveCommand` helper

### 3. Update `mkLspConfig` and `mkCopilotLspConfig` to use

`resolveCommand` and handle null package

### 4. Change option types to `attrsOf lspServerModule` in

`sharedOptions.nix` and all three per-CLI factories

### 5. Wire translator calls in per-CLI factories

### 6. Update existing tests + add new ones

### 7. Close backlog

The earlier `ai.lspServers` bullet close-out from `f9d6730` covered
the freeform fanout shipping. Add a follow-up note marking the
typed migration as shipped.

### 8. Commit

Single commit: `feat(ai): migrate ai.lspServers to typed schema +
per-ecosystem translators`. Breaking change for freeform callers;
existing `{command, args}` shape remains valid.

## Out of scope

- Per-CLI option renames (e.g., `ai.claude.lspServers` →
  `ai.claude.languageServers` for clarity). Naming is fine.
- Making `lspServerModule` fully opinionated with enum types for
  known languages. Freeform `extensions` list is enough.
- Consumer migration (different repo).

## Size estimate

~60 lines ai-common changes + ~20 lines factory wiring + test
adjustments + 1 commit.

## Review checklist

- [ ] `lspServerModule`: `package` nullable, `command` added,
      `extensions` defaults to `[]`, assertion requires one of
      `package` / `command`.
- [ ] Three translators live in ai-common, all use shared
      `resolveCommand`.
- [ ] All per-CLI factories + top-level use `attrsOf lspServerModule`.
- [ ] Factories invoke their translator on `mergedLspServers`.
- [ ] All existing LSP tests still pass.
- [ ] New tests cover fileExtensions + extensionToLanguage paths.
- [ ] Commit message flags breaking change.
