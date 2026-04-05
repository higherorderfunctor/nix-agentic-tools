# AGENTS.md

Project instructions for AI coding assistants working in this repository.
Read by Claude Code, Kiro, GitHub Copilot, Codex, and other tools that
support the [AGENTS.md standard](https://agents.md).

## Coding Standards

### Ordering

Keep entries sorted alphabetically within categorical groups. Use section
headers for readability, sort entries within each group.

### DRY Principle

Never duplicate logic, configuration, or patterns. When the same thing appears
twice, extract it.

## Commit Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:** `feat`, `fix`, `refactor`, `docs`, `chore`, `build`, `ci`, `style`,
`perf`, `test`

**Scopes** (optional but encouraged): package or module name, directory
name, or `flake` for root changes.

Keep descriptions lowercase, imperative mood, no trailing period.

## External Tooling

When accessing external services, prefer the highest-fidelity integration
available:

1. **MCP server** — richest context, structured responses, stays in-conversation
2. **CLI tool** (e.g., `gh`, `curl`) — scriptable, good for batch operations
3. **Direct web access** — last resort, use only when MCP and CLI are unavailable

### Formatting

After editing any file — regardless of how it was modified (Edit, Write,
Bash, sed, etc.) — run `dprint fmt <file>` on the changed file. dprint
handles Nix (via alejandra) and markdown.

## Project Overview

agentic-tools is a Nix flake monorepo for AI coding CLI tools. Built with
a fragment pipeline that generates ecosystem-specific instruction files
for Claude Code, Kiro, and GitHub Copilot from shared sources.
