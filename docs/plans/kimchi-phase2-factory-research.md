# Kimchi Phase 2 — `ai.*` factory integration research

> Status: **RESEARCH ONLY** (2026-06-22). No implementation this session.
> Prereq: the Kimchi binary package (Phase 1) is committed
> (`619ee43`/`b7d5be4`/`f592c8a`). This doc scopes the declarative-config (HM +
> devenv module) follow-up. See [docs/plans/kimchi-packaging.md].
>
> **Provenance:** facts tagged `[src]` come from reading the `getkimchi/kimchi`
> source (TypeScript), `[docs]` from docs.kimchi.dev, `[bin]` from probing the
> built `kimchi` binary (`--help`, `strings`). Where sources disagree,
> source/binary win over docs (docs lag a rebrand).

## 1. What Kimchi is, architecturally

Kimchi wraps **`@earendil-works/pi-coding-agent`** ("pi") and bun-compiles it.
`[src]` Many conventions are pi-inherited (skill discovery, `*_CODING_AGENT_DIR`
env, package/extension manager). It is both:

- **(a) an agent itself** — `kimchi` launches a TUI coding harness. ← Phase 2
  targets this.
- **(b) a configurator of OTHER tools** —
  `kimchi claude|cursor|opencode|openclaw|gsd2` point those tools at Cast AI. ←
  NOT our concern.

Provider is **Cast AI**'s OpenAI/Anthropic-compatible gateway. Endpoint default
is **disputed**: `https://llm.cast.ai/openai/v1` `[src]` vs
`https://llm.kimchi.dev` `[docs]` — verify against a live install before relying
on either. Overridable via `config.json.llmEndpoint` or
`KIMCHI_DEFAULT_ENDPOINT`.

## 2. Config lives in TWO trees (the load-bearing fact)

| Tree                           | Holds                                                                                                                                                                                | Override env              |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------- |
| `~/.config/kimchi/config.json` | account/CLI: `apiKey`, `llmEndpoint`, `telemetry`, `skillPaths`, `gitTokens`, `preferences`, `mcpSearch` (mode 600)                                                                  | `KIMCHI_CONFIG_PATH`      |
| `~/.config/kimchi/harness/`    | agent runtime: `settings.json` (`modelRoles`/`modelMetadata`/`resources`), `mcp.json`, `permissions.json`, `agents/*.md`, `skills/`, `hooks/bash/*.sh`, `AGENTS.md`, `agent-memory/` | `KIMCHI_CODING_AGENT_DIR` |
| `<cwd>/.kimchi/`               | project-local mirror: `config.json`, `mcp.json`, `permissions{,.local}.json`, `agents/`, `skills/`, `hooks/`, `plans/`, `ferments/`                                                  | —                         |

`harness` subpath declared in `package.json` →
`piConfig.configDir = ".config/kimchi/harness"`. `[src]` Binary strings confirm
`.kimchi/mcp.json`, `.kimchi/agents/`, `.kimchi/plans/`, `.kimchi/ferments/`,
`KIMCHI_CODING_AGENT_DIR`, `KIMCHI_CONFIG_PATH`. `[bin]`

A module **must manage both trees** — `config.json` for the key/endpoint,
`harness/` for everything the agent surfaces use. `KIMCHI_CODING_AGENT_DIR` can
relocate the harness tree wholesale (useful for pointing at a nix-managed dir,
but see §5 mutable-state hazard).

## 3. Surface → factory mapping

The repo's `ai.*` module fans out a unified config to Claude/Copilot/Kiro with
per-ecosystem translation. Adding Kimchi = a `lib.ai.apps.mkKimchi`
contribution + `packages/kimchi/modules/{homeManager,devenv}` translating each
surface to Kimchi's files. Good news: **Kimchi's formats are mostly
Claude-shaped**, so most translators are reusable with path remap.

| `ai.*` surface            | Kimchi target                                                                                                                                                        | Format compatibility                                                                                                                                                       |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **skills**                | `harness/skills/<name>/SKILL.md` (+ reads `~/.claude/skills` natively, and `.kimchi/skills`) `[src][docs]`                                                           | **SKILL.md identical to Claude** — reuse claude skills translator, remap path                                                                                              |
| **instructions/steering** | `harness/AGENTS.md` (global) + project `AGENTS.md`/`CLAUDE.md`                                                                                                       | **orientation-only**, flat always-injected. NO path-scoped/`fileMatch` steering `[src]` → use the AGENTS.md/Codex transform, NOT the scoped Claude-rules/Kiro-steering one |
| **MCP servers**           | `harness/mcp.json` + `.kimchi/mcp.json`, root key `mcpServers` `[src][docs]`                                                                                         | **Claude-compatible** base shape; Kimchi adds extras (`auth`, `lifecycle`, `directTools`, `excludeTools`, `imports`) — superset, so reuse + optionally expose extras       |
| **settings**              | split: `config.json` (telemetry, skillPaths, preferences) + `harness/settings.json` (`modelRoles`, `modelMetadata`, `resources`) `[src][docs]`                       | bespoke; new typed translator                                                                                                                                              |
| **hooks**                 | `harness/hooks/bash/*.sh` (global, enabled) + `.kimchi/hooks/bash/` (project, disabled-by-default) `[src][docs]`                                                     | bash-hook files + stdin-JSON contract; also a Claude-hook adapter (opt-in resource)                                                                                        |
| **agents/subagents**      | `harness/agents/<name>.md` + `.kimchi/agents/*.md`, MD + YAML frontmatter (`description, models, thinking, tools, disallowed_tools, skills, isolation, ...`) `[src]` | Claude-subagent-like; new translator (docs claimed "not user-definable" — **wrong**, source has the loader)                                                                |
| **permissions**           | `harness/permissions.json` + `.kimchi/permissions{,.local}.json`, `{defaultMode, allow[], deny[], classifierTimeoutMs}` `[src]`                                      | allow/deny rule lists like Claude/Kiro; new translator (docs claimed "none" — **wrong**)                                                                                   |
| **env vars**              | session env / `KIMCHI_*`                                                                                                                                             | direct                                                                                                                                                                     |
| **model selection**       | `harness/settings.json.modelRoles` (`orchestrator/planner/builder/reviewer/explorer/researcher/judge` → `provider/model-id`) `[src][docs]`                           | ties into the repo's typed-model work; model catalog is dynamic — don't hardcode                                                                                           |

### Permissions detail `[src]`

Schema
`{ defaultMode: default|plan|auto|yolo, allow: string[], deny: string[], classifierTimeoutMs }`.
Rule syntax `tool` or `tool(content)` (bash wildcards, file globs). Precedence
`session > cli > local > project > user > builtin`; built-in deny list covers
`rm -rf /*`, `sudo *`, `write/edit(.env*)`. Closely parallels Claude/Kiro
permissions → the repo's existing permissions typing is a strong fit.

### Resource toggles `[src][docs]`

`harness/settings.json.resources` (and `kimchi resources enable/disable`) gate
whole categories: `hooks.bash`, `hooks.rtk-rewrite`, `tools.web_search`,
`tools.web_fetch`, `extensions.agents`, `extensions.ferment`,
`extensions.claude-code-hook-adapter` (off), `extensions.claude-code-skills`
(off), `plugins.*`. Declaratively pre-seeding these means owning
`settings.json`, which Kimchi also mutates at runtime (see §5).

## 4. Env vars worth wiring (from `[bin]` + `[src]`)

| Var                          | Use in module                                                                                                          |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `KIMCHI_API_KEY`             | inject the key via env instead of writing plaintext to `config.json` (pairs with the repo's SOPS/cred-wrapper pattern) |
| `KIMCHI_CODING_AGENT_DIR`    | relocate the harness tree (if managing it out-of-`$HOME`)                                                              |
| `KIMCHI_NO_UPDATE_CHECK`     | disable the background self-update probe (set in the wrapper)                                                          |
| `KIMCHI_TELEMETRY_ENABLED=0` | disable telemetry declaratively                                                                                        |
| `KIMCHI_RTK_AUTO_INSTALL=0`  | suppress RTK auto-install network side-effect                                                                          |
| `KIMCHI_TAGS`                | static per-request tags                                                                                                |

## 5. Gotchas / risks for Phase 2

1. **Split config trees** — two roots (`config.json` + `harness/`) plus a
   project mirror. The module surface is wider than Kiro's.
2. **Plaintext secrets** `[src]` — `apiKey` and `gitTokens.<host>` are stored
   plaintext in `config.json`, mode 600, no keychain. **Prefer injecting
   `KIMCHI_API_KEY` via env** (the repo's MCP cred-wrapper / SOPS-rotation
   pattern) over writing the key into a nix-managed file.
3. **Mutable-state vs symlink conflict** — Kimchi _writes_
   `harness/settings.json` at runtime (`/multi-model` persists `modelRoles`;
   `kimchi resources` persists toggles) and _downloads_ into `harness/`
   (superpowers skills → `vendor/superpowers/`, RTK). HM `home.file`
   symlinks-to-store will fight this exactly like the claude/kiro mutable-state
   reconciliation already solved in this repo. Likely need activation-time merge
   / writable copy, not a raw symlink. See [[project_claude_effort_pin_state]]
   and [[project_devenv_files_internals]] (devenv `files.*.source` can't
   recurse, silent no-op on dir-vs-symlink).
4. **Network side-effects on first launch** — superpowers skill download + RTK
   install + update probe. Wrapper should set `KIMCHI_NO_UPDATE_CHECK=1` and
   consider `KIMCHI_RTK_AUTO_INSTALL=0`; vendor download still happens unless
   pre-seeded.
5. **No path-scoped steering** — Kimchi takes only flat always-injected
   AGENTS.md. The repo's scoped fragments (Claude `rules/`, Kiro `steering/`) do
   NOT translate; Kimchi gets orientation-only, same tier as AGENTS.md/Codex.
6. **pi base drift** `[src]` — some discovery (`~/.pi/agent/skills`, `PI_*`)
   comes from upstream pi, not the kimchi repo; schema may move with pi bumps.
7. **`kimchi mcp|skills|agents|hooks` are NOT subcommands** `[bin]` — they fall
   through to the pi extension manager (install/remove/list). The real config is
   the JSON/MD files above, not those subcommands.
8. **Config Parity rule** — any surface added in HM must also land in devenv
   (and vice versa). The factory's shared `mkApp` record is how the other CLIs
   satisfy this; `mkKimchi` must do the same.

## 6. Discrepancies the agents surfaced (verify on a live install)

- **LLM endpoint**: `llm.cast.ai/openai/v1` `[src]` vs `llm.kimchi.dev`
  `[docs]`.
- **apiKey casing**: `apiKey` (camel, writers) vs legacy `api_key` (also read)
  `[src]`.
- **Permissions / agents existence**: docs say "none / not user-definable";
  **source has both** (`permissions.json`, `agents/*.md`). Trust source.
- **Model names** drift between doc pages; catalog is dynamic
  (`/v1/llm/providers`) — never hardcode model ids.
- **`resources` location**: `harness/settings.json` is authoritative (docs also
  mention `config.json.resources`).

## 7. Proposed `mkKimchi` shape (NON-binding sketch, not implemented)

```
packages/kimchi/
  default.nix              # barrel: docs, fragments, lib.ai.apps.mkKimchi, modules
  lib/mkKimchi.nix         # mkApp record contribution (hm + devenv transforms)
  models.json              # if typed-model config wires modelRoles
  modules/{homeManager,devenv}/default.nix
```

`mkKimchi` translates the unified `ai.*` config to:

- `~/.config/kimchi/config.json` ← settings subset (NOT the key — env-inject)
- `~/.config/kimchi/harness/settings.json` ← `modelRoles`/`resources`
- `~/.config/kimchi/harness/mcp.json` ← reuse claude MCP translator + path remap
- `~/.config/kimchi/harness/permissions.json` ← reuse permissions typing
- `~/.config/kimchi/harness/AGENTS.md` ← orientation transform (Codex-tier)
- `~/.config/kimchi/harness/skills/` ← reuse claude skills translator
- `~/.config/kimchi/harness/agents/` ← new agents translator
- `~/.config/kimchi/harness/hooks/bash/`← hooks translator
- wrapper env: `KIMCHI_API_KEY`, `KIMCHI_NO_UPDATE_CHECK=1`, telemetry off

Effort: comparable to the kiro-cli factory work (multi-day), dominated by the
mutable-state reconciliation (§5.3) and the new agents/permissions/settings
translators. Reuse from Claude keeps skills/MCP/instructions cheap.

## 8. Open questions before implementing

1. Resolve the endpoint + apiKey-casing discrepancies on a live `kimchi setup`.
2. Decide the mutable-state strategy for `harness/` (activation merge vs
   writable copy vs `KIMCHI_CODING_AGENT_DIR` → managed dir) — this is the crux
   and should mirror the existing claude/kiro reconciliation.
3. Confirm `harness/settings.json` full schema (beyond `modelRoles`/
   `modelMetadata`/`resources`) against a real install.
4. Decide whether to expose Kimchi's MCP extras (`auth`/`lifecycle`/
   `directTools`) as typed options or pass through.
5. Confirm whether `agents`/`hooks`/`permissions` should be HELD as untyped
   passthrough initially (as kiro v3 did) or typed from the start.
6. Confirm the `vendor/superpowers` + RTK download behavior is acceptable or
   must be pre-seeded/disabled for a hermetic install.

```

```
