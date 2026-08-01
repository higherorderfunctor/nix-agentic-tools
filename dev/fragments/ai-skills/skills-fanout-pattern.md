## ai.skills Fanout Delegation Pattern

> **Last verified:** 2026-08-01 (commit pending — Codex joins skills fanout at
> the native user-global and repository-local `.agents/skills` locations).
> Prior: 2026-04-08 (commit 97ac174 — refactor(devenv): ai.skills branches
> delegate through ecosystem options). If you touch the Claude/Codex/Copilot/
> Kiro skills fanout, `lib/ai/hm-helpers.nix:mkSkillEntries`, or upstream
> `programs.<cli>.skills` references, and this fragment isn't updated in the
> same commit, stop and fix it.

When an ecosystem has a `programs.<cli>.skills` option, `ai.skills` fanout MUST
delegate through it. Codex has no upstream Home Manager module, so its factory
uses the shared recursive helper directly. Both routes must preserve Layout B: a
real skill directory containing per-file store symlinks.

### Uniform pattern

| Branch  | HM route                      | Native directory  |
| ------- | ----------------------------- | ----------------- |
| Claude  | `programs.claude-code.skills` | `.claude/skills`  |
| Codex   | `mkSkillEntries` directly     | `.agents/skills`  |
| Copilot | `programs.copilot-cli.skills` | `.copilot/skills` |
| Kiro    | `programs.kiro-cli.skills`    | `.kiro/skills`    |

On-disk layout is identical across all four: a real native `skills/<name>/`
directory with per-file store symlinks inside, via `recursive = true` in each
helper.

### Why this matters

The Copilot and Kiro branches of `modules/ai/default.nix` already delegate via
their `programs.<cli>.skills` options. The Claude branch is currently the odd
one out — it writes `home.file.".claude/skills/<name>".source` directly. This
produces a single dir symlink (Layout A), while upstream
`programs.claude-code.skills` produces a real directory with per-file symlinks
(Layout B via `recursive = true`).

Two concrete problems:

1. **Per-Claude `ai.claude.skills` collision.** Once `ai.claude.skills` lands as
   part of the full passthrough work, it would collide with cross-ecosystem
   `ai.skills` on the same `home.file` path. Consumers can't compose both.

2. **Consumer migration clobber.** A consumer who migrated from
   `programs.claude-code.skills` to `ai.skills` while the old direct-`home.file`
   code was live ends up with a real `.claude/skills/<name>/` directory on disk
   (laid down by upstream previously). When the fix lands, the first activation
   errors with `Existing file '<path>' would be clobbered`. Remedy:
   `home-manager switch -b backup` once; subsequent activations succeed cleanly.
   Mention this in the fix commit message.

### How to apply

When working on the Claude skills fanout fix:

- Replace the `home.file.".claude/skills/<name>".source` block in the Claude
  branch of `modules/ai/default.nix` with
  `programs.claude-code.skills = lib.mapAttrs (_: mkDefault) cfg.skills;`
- Match the Copilot/Kiro pattern exactly — all three branches should look
  structurally identical
- Do NOT propose bypassing `programs.claude-code.skills` with direct `home.file`
  writes. The `recursive = true` behavior in upstream is the intended on-disk
  shape; mirror it, don't fight it.
- Add a `checks/module-eval.nix` test that asserts
  `aiSkillsFanout.config.programs.claude-code.skills ? <name>` when
  `ai.skills.<name>` is set.

### Codex destinations

Current official Codex documentation defines `$HOME/.agents/skills` as the user
scope and `<repo>/.agents/skills` as repository scope. Codex scans repo
locations from the current working directory up to the repository root and
supports symlinked skill folders. Therefore HM emits `.agents/skills`, while
devenv emits project-root `.agents/skills`; neither destination is derived from
`ai.codex.configDir`.

### Devenv counterpart

`devenv.files.*.source` is structurally incapable of recursive walks. Every
factory without a native recursive option uses `mkDevenvSkillEntries`, which
enumerates each leaf at evaluation time and preserves nested relative paths.
Codex calls it with `.agents`, producing project-root `.agents/skills` entries.

### Related

- `dev/fragments/devenv/files-internals.md` — devenv constraints
  - walker workaround
- `memory/project_ai_skills_layout.md` — original design decision and context
- `memory/project_ai_claude_passthrough.md` — Tasks 2/2b in the passthrough plan
  that operationalize this
