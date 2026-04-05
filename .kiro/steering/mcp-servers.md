---
description: Instructions for the mcp-servers package
fileMatchPattern: "modules/mcp-servers/**,packages/mcp-servers/**"
inclusion: fileMatch
name: mcp-servers
---

## Coding Standards

### Bash

All shell scripts must use full strict mode:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
```

### Ordering

Keep entries sorted alphabetically within categorical groups. Use section
headers for readability, sort entries within each group.

### DRY Principle

Never duplicate logic, configuration, or patterns. When the same thing appears
twice, extract it. Skills reference shared docs in `references/` rather than
duplicating content.

## Commit Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:** `feat`, `fix`, `refactor`, `docs`, `chore`, `build`, `ci`, `style`,
`perf`, `test`

**Scopes** (optional but encouraged): package or module name (e.g.,
`context7-mcp`, `copilot-cli`, `fragments`), directory name (`overlay`,
`module`, `lib`, `devshell`), or `flake` for root changes.

Keep descriptions lowercase, imperative mood, no trailing period.

## External Tooling

When accessing external services, prefer the highest-fidelity integration
available:

1. **MCP server** — richest context, structured responses, stays in-conversation
2. **CLI tool** (e.g., `gh`, `curl`) — scriptable, good for batch operations
3. **Direct web access** — last resort, use only when MCP and CLI are unavailable

For GitHub specifically: prefer the `github-mcp` server over `gh` CLI over
raw API calls or web fetches.

### Formatting

After editing any file — regardless of how it was modified (Edit, Write,
Bash, sed, etc.) — run `dprint fmt <file>` on the changed file. dprint
handles markdown, JSON, TOML, Nix (via alejandra), and shell (via shfmt).
The PostToolUse hook auto-formats after Edit/Write, but Bash edits bypass
hooks. Always format explicitly after Bash-based file modifications.

### Validation

After creating or modifying any SKILL.md, AGENTS.md, CLAUDE.md, `.mcp.json`,
or `.agnix.toml`, validate with agnix before committing. The pre-commit hook
runs `agnix --strict .` automatically on staged config files, but proactive
validation catches issues earlier.

Do not install packages globally — use tools available in the devShell. If
something is missing, ask the user or use `npx`/`uvx`/`nix run` instead.

If the Skill tool invocation fails, read the SKILL.md file directly and
execute its instructions step by step. The routing table is MANDATORY —
skills must be used even when the tool mechanism is unavailable.

