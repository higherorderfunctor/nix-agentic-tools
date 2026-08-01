# Codex 0.146.0 configuration probes

> Last verified: 2026-08-01 against `pkgs.ai.chatgpt-codex` 0.146.0 and the
> current official OpenAI Codex manual.

## Purpose

This is the evidence boundary for CX-001 and the extraction-feasibility part of
CX-002. It records which Codex artifacts Nix may own, which ones Codex mutates,
and which pinned-binary seams can support a drift-checked sidecar. It does not
define the eventual module API.

All binary probes used a fresh `HOME` and an existing, empty `CODEX_HOME` under
`/tmp`. They did not reuse credentials or contact a model provider.

## Reproduce

```bash
nix eval --raw .#chatgpt-codex.version
codex_out=$(nix build --no-link --print-out-paths .#chatgpt-codex)
probe_root=$(mktemp -d /tmp/codex-config-probe.XXXXXX)
mkdir -p "$probe_root/home" "$probe_root/codex-home"

env HOME="$probe_root/home" CODEX_HOME="$probe_root/codex-home" \
  "$codex_out/bin/codex" --help
env HOME="$probe_root/home" CODEX_HOME="$probe_root/codex-home" \
  "$codex_out/bin/codex" features list
env HOME="$probe_root/home" CODEX_HOME="$probe_root/codex-home" \
  "$codex_out/bin/codex" mcp add --help
env HOME="$probe_root/home" CODEX_HOME="$probe_root/codex-home" \
  "$codex_out/bin/codex" app-server --help
find "$probe_root" -maxdepth 4 -printf '%P %y %s\n' | sort
```

The temporary `CODEX_HOME` must exist before launch. Codex warns and refuses to
create PATH aliases when it is below `/tmp`; that warning is expected and does
not invalidate read-only help or feature probes.

## Artifact ownership

| Artifact                                                       | Scope        | Observed or documented behavior                                                                                                                                                                              | Classification                                         | Initial delivery decision                                                                                                                               |
| -------------------------------------------------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `$CODEX_HOME/config.toml`                                      | User         | Durable base config. `codex mcp add/remove` edits MCP configuration; `/experimental` can persist feature toggles. A probe preserved comments and unknown tables, appended the MCP table, and left mode 0600. | Mixed when CLI editors are used; otherwise declarative | Start with static Nix ownership and document that native editors are unavailable; add reconciliation only if the module promises coexistence with them. |
| `$CODEX_HOME/<name>.config.toml`                               | User         | `--profile` overlays this file above base config. Since 0.134.0, legacy `[profiles]` and top-level `profile` are unsupported.                                                                                | Declarative                                            | Static Nix-managed files.                                                                                                                               |
| `<repo>/.codex/config.toml`                                    | Project      | Trusted-only layers load from project root down to cwd; nearer values win. Machine-local/provider keys are ignored with a warning.                                                                           | Declarative                                            | Static project files; reject keys that Codex ignores at project scope.                                                                                  |
| Adjacent `hooks.json`                                          | User/project | Loaded alongside inline `[hooks]`; both are additive and produce a warning when colocated. Project hooks require trust.                                                                                      | Declarative                                            | Prefer one representation per generated layer.                                                                                                          |
| Adjacent `rules/*.rules`                                       | User/project | Starlark exec policy. TUI allow-list actions write the user `rules/default.rules`. Project rules require trust.                                                                                              | Mixed at user scope; declarative at project scope      | Never lower Markdown `ai.rules` here. Use per-entry files and reserve `default.rules` from static ownership if native writes must coexist.              |
| `$CODEX_HOME/AGENTS.md`                                        | User         | `AGENTS.override.md` suppresses it; only the first non-empty global file loads.                                                                                                                              | Declarative                                            | Static Nix-managed Markdown.                                                                                                                            |
| `AGENTS.md` tree                                               | Project      | One file per directory, root-to-cwd; override, base, then configured fallback precedence. Combined default cap is 32 KiB.                                                                                    | Declarative/shared                                     | Tree-placement concern, separate from a flat rules directory.                                                                                           |
| `$HOME/.agents/skills` and `<repo>/.agents/skills`             | User/project | Documented personal and team skill discovery locations.                                                                                                                                                      | Declarative/shared                                     | Materialize per skill in the shared convention. Do not use `.codex/skills` as the primary destination.                                                  |
| `$CODEX_HOME/agents/*.toml` and project `.codex/agents/*.toml` | User/project | Standalone custom-agent config; project roles require trust.                                                                                                                                                 | Declarative                                            | Static per-agent files.                                                                                                                                 |
| `$CODEX_HOME/auth.json` or OS credential store                 | User         | Authentication material.                                                                                                                                                                                     | Secret mutable state                                   | Never generate.                                                                                                                                         |
| SQLite databases, sessions, history, logs, caches              | User         | Startup created `goals_1.sqlite`, `logs_2.sqlite`, `memories_1.sqlite`, and `state_5.sqlite` plus WAL/SHM files during an accidentally interactive probe.                                                    | Mutable state                                          | Leave Codex-owned. This also proves that an isolated `CODEX_HOME`, not only an isolated `HOME`, is required for safe probes.                            |

The manual says `CODEX_HOME` is the root for config, auth, logs, sessions,
skills, and standalone package metadata. A project-specific wrapper that changes
`CODEX_HOME` therefore also changes credentials and state; devenv must prefer
trusted project `.codex/config.toml` over a private home unless that tradeoff is
explicitly designed.

## Precedence contract

For 0.146.0 the documented effective order is base user config, selected
`$CODEX_HOME/<profile>.config.toml`, trusted project layers from root to cwd,
then CLI overrides. Dedicated flags are preferred over `-c`; dotted `-c` keys
parse TOML values and fall back to literal strings. Project config cannot set
provider/auth redirection, notification/telemetry commands, or profiles.

Instruction discovery is independent: global override or base first, followed by
at most one non-empty project instruction file per directory. The per-dir order
is `AGENTS.override.md`, `AGENTS.md`, then fallback filenames. Content is
concatenated root-to-cwd until `project_doc_max_bytes`, 32768 by default.

## Extraction seams

The preferred extraction stack is:

1. Recursively parse Clap help for the command tree, flags, aliases, conflicts,
   defaults, and displayed enums. The root help exposes closed sandbox and
   approval values directly.
2. Parse `codex features list`. It emits stable whitespace columns containing
   feature name, maturity, and default. The 0.146.0 probe returned 100 rows and
   includes stable, experimental, under-development, deprecated, and removed
   entries. Removed entries should remain provenance, not become options.
3. Use `codex debug models` for the packaged model catalog. Treat model IDs as
   hints/soft enums because account, provider, and rollout can add availability.
4. Generate app-server JSON Schema only for the app-server protocol. The
   `app-server generate-json-schema` command is not a `config.toml` schema and
   must not be mislabeled as one.
5. Use `--strict-config` plus isolated behavioral fixtures to validate public
   config keys and types that have no structured export.
6. Fall back to guarded packaged-resource or binary-string inspection only for
   vocabularies that none of the preceding seams expose.

`codex --help` also proves the current command tree includes `exec`, `review`,
`login`, `logout`, `mcp`, `plugin`, `mcp-server`, `app-server`,
`remote-control`, `completion`, `update`, `doctor`, `sandbox`, `debug`, `apply`,
`resume`, `archive`, `delete`, `unarchive`, `fork`, `cloud`, `exec-server`, and
`features`. Extraction must recurse rather than freezing this list.

## Proposed sidecar

Keep raw, derived, and classified facts separate so later option code does not
reinterpret scrape output:

```json
{
  "cli": {
    "commands": {},
    "globalFlags": []
  },
  "config": {
    "documentedKeys": [],
    "probeValidatedKeys": []
  },
  "features": [],
  "models": [],
  "provenance": {
    "codexVersion": "0.146.0",
    "extractorSchema": 1
  }
}
```

Each CLI command record should contain its path, aliases, flags, accepted
values, defaults, conflicts, and help when present. Each feature record should
contain `name`, `maturity`, and `default`. Sort object keys and categorical
arrays deterministically. The derivation must assert structural sentinels and
minimum shapes, including the root command, the three sandbox modes, the three
non-deprecated approval modes, and non-empty feature output.

Do not claim complete config-key extraction from the binary yet. The manual's
configuration reference is more complete than any discovered native schema,
while `--strict-config` is a validator rather than an enumerator. CX-002 should
commit only categories with honest deterministic provenance and carry a separate
documented-key coverage ledger.

## Decisions and remaining probes

- Static `config.toml` is the MVP. Native `mcp add/remove` and feature toggles
  are known writers, but consumers choosing declarative ownership can use Nix
  instead. A merge engine is deferred until a required mutable value is proven
  to share this file.
- `codex mcp add --env KEY=VALUE` writes the literal value into `config.toml`;
  the module must prefer native environment-name indirection where available and
  must not render secrets into a Nix store-backed file.
- Profiles are standalone files, not a nested settings attrset lowered into the
  base file.
- Devenv should use trusted project configuration and shared project skills;
  changing `CODEX_HOME` would unnecessarily fork auth and runtime state.
- Permission profiles and legacy sandbox settings are mutually exclusive and
  need an assertion in the later typed surface.
- Markdown instruction rules and Starlark exec-policy rules remain separate
  semantic concerns.

Still requiring a later credentialed or PTY-specific probe: exact TUI trust
state storage, whether acknowledgement/migration state shares a declarative
file, the exact file rewrite behavior and permissions of every mutating command,
hook trust persistence, and account-dependent model catalog behavior. None
blocks the extraction categories above or the package-only enable slice.

## Official sources

- [Configuration reference](https://developers.openai.com/codex/config-reference)
- [Advanced configuration](https://developers.openai.com/codex/config-advanced)
- [Custom instructions with AGENTS.md](https://developers.openai.com/codex/guides/agents-md)
- [Model Context Protocol](https://developers.openai.com/codex/mcp)
- [Rules](https://developers.openai.com/codex/rules)
- [Skills](https://developers.openai.com/codex/skills)
