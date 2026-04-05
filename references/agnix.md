# agnix Quick Reference

agnix is a cross-platform linter and LSP for AI coding assistant config
files. It validates SKILL.md, CLAUDE.md, AGENTS.md, Kiro steering files,
Copilot instructions, MCP configs, and more.

- **Repo**: https://github.com/agent-sh/agnix
- **Version in devShell**: tracking latest GitHub release via nvfetcher

## CLI

```bash
agnix .                  # lint current directory
agnix --strict .         # strict mode (CI — warnings become errors)
agnix --fix .            # auto-fix safe issues
agnix --fix-safe .       # same as --fix (conservative fixes only)
agnix --fix-unsafe .     # also apply risky fixes
agnix --dry-run --show-fixes .  # preview fixes without applying
agnix --target claude-code .    # lint only Claude Code files
agnix --target kiro .           # lint only Kiro files
```

### Output formats

```bash
agnix .                         # default diagnostic output
agnix --output sarif .          # SARIF for GitHub Code Scanning
agnix --output json .           # machine-readable JSON
```

## Configuration (`.agnix.toml`)

This repo's config:

```toml
[targets]
claude-code = true
copilot = true
kiro = true

[rules]
disabled_rules = ["XML-001", "AS-014", "XP-003", "CC-MEM-008", "PE-001", "CDX-AG-005", "CC-HK-009"]
```

### Suppressed rules in this repo

<!-- dprint-ignore -->
| Rule       | Why suppressed                                                  |
| ---------- | --------------------------------------------------------------- |
| XML-001    | Angle brackets in git placeholder syntax (`<hash>`, `<commit>`) |
| AS-014     | Shell quoting in code blocks mistaken for Windows paths         |
| XP-003     | Hard-coded paths are intentional in install/reference docs      |
| CC-MEM-008 | MANDATORY keyword placement is deliberate                       |
| PE-001     | Critical keyword position warnings — placement is intentional   |
| CDX-AG-005 | agnix bug — rule message not interpolated (empty warning)       |
| CC-HK-009  | `|| true` on dprint format hook is intentional (best-effort)    |

## Rule Categories

Rules are prefixed by category:

<!-- dprint-ignore -->
| Prefix | Scope                                    |
| ------ | ---------------------------------------- |
| AS-*   | Agent Skills spec (SKILL.md)             |
| CC-*   | Claude Code (CLAUDE.md, hooks, settings) |
| GH-*   | GitHub Copilot (instructions, skills)    |
| KR-*   | Kiro (steering, agents, powers)          |
| MCP-*  | MCP configuration                        |
| PE-*   | General prose/encoding                   |
| XP-*   | Cross-platform consistency               |
| XML-*  | XML/markup detection                     |

## Severity Levels

- **error** — spec violation, will break agent behavior
- **warning** — best practice violation, may cause issues
- **info** — informational, no action required

In `--strict` mode, warnings are promoted to errors.

## IDE Integration

agnix ships an LSP server (`agnix-lsp`) with extensions for:

- VS Code (marketplace: `avifenesh.agnix`)
- JetBrains
- Neovim
- Zed

## CI Usage

This repo runs agnix in CI:

```yaml
- name: Lint agent configs
  run: nix develop --command agnix --strict .
```

SARIF output can be uploaded to GitHub Code Scanning for inline
annotations on PRs.

## Adding/Suppressing Rules

To suppress a rule, add it to `disabled_rules` in `.agnix.toml`:

```toml
[rules]
disabled_rules = ["RULE-ID"]
```

Document WHY each rule is suppressed (as comments in `.agnix.toml`).
When upgrading agnix, review suppressed rules — false positives may
be fixed in newer versions.
