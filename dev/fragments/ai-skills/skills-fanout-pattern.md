## ai.skills Fanout Delegation Pattern

> **Last verified:** 2026-04-08 (commit 97ac174 — refactor(devenv): ai.skills branches delegate through ecosystem options). If you touch
> the Claude/Copilot/Kiro skills fanout in `modules/ai/default.nix`
> (or the devenv equivalent), `lib/hm-helpers.nix:mkSkillEntries`,
> or upstream `programs.<cli>.skills` references, and this
> fragment isn't updated in the same commit, stop and fix it.

The `ai.skills` fanout MUST go through each ecosystem's
respective `programs.<cli>.skills` option. **No branch writes
`home.file` directly.** Doing so produces a different on-disk
layout from the upstream module and creates collision bugs when
per-CLI `ai.<cli>.skills` lands.

### Uniform pattern

| Branch  | Delegates to                  | Helper                     |
| ------- | ----------------------------- | -------------------------- |
| Claude  | `programs.claude-code.skills` | upstream HM `mkSkillEntry` |
| Copilot | `programs.copilot-cli.skills` | our `lib/hm-helpers.nix`   |
| Kiro    | `programs.kiro-cli.skills`    | our `lib/hm-helpers.nix`   |

On-disk result is identical across all three: a real
`.claude/skills/<name>/` (or equivalent) directory with per-file
store symlinks inside, via `recursive = true` in each helper.

### Why this matters

The Copilot and Kiro branches of `modules/ai/default.nix` already
delegate via their `programs.<cli>.skills` options. The Claude
branch is currently the odd one out — it writes
`home.file.".claude/skills/<name>".source` directly. This
produces a single dir symlink (Layout A), while upstream
`programs.claude-code.skills` produces a real directory with
per-file symlinks (Layout B via `recursive = true`).

Two concrete problems:

1. **Per-Claude `ai.claude.skills` collision.** Once
   `ai.claude.skills` lands as part of the full passthrough work,
   it would collide with cross-ecosystem `ai.skills` on the same
   `home.file` path. Consumers can't compose both.

2. **Consumer migration clobber.** A consumer who migrated from
   `programs.claude-code.skills` to `ai.skills` while the old
   direct-`home.file` code was live ends up with a real
   `.claude/skills/<name>/` directory on disk (laid down by
   upstream previously). When the fix lands, the first activation
   errors with `Existing file '<path>' would be clobbered`.
   Remedy: `home-manager switch -b backup` once; subsequent
   activations succeed cleanly. Mention this in the fix commit
   message.

### How to apply

When working on the Claude skills fanout fix:

- Replace the `home.file.".claude/skills/<name>".source` block in
  the Claude branch of `modules/ai/default.nix` with
  `programs.claude-code.skills = lib.mapAttrs (_: mkDefault) cfg.skills;`
- Match the Copilot/Kiro pattern exactly — all three branches
  should look structurally identical
- Do NOT propose bypassing `programs.claude-code.skills` with
  direct `home.file` writes. The `recursive = true` behavior in
  upstream is the intended on-disk shape; mirror it, don't fight
  it.
- Add a `checks/module-eval.nix` test that asserts
  `aiSkillsFanout.config.programs.claude-code.skills ? <name>`
  when `ai.skills.<name>` is set.

### Devenv counterpart

devenv currently produces Layout A (single dir symlink) for all
three ecosystems because `devenv.files.*.source` is structurally
incapable of recursive walks. See the related
`devenv-files-internals` fragment under `dev/fragments/devenv/`
for the full constraints, and the `mkDevenvSkillEntries`
user-space walker that brings devenv to Layout B parity. Both
the HM Claude branch fix and the devenv parity fix are
prerequisites for full `ai.claude.*` passthrough.

### Related

- `dev/fragments/devenv/files-internals.md` — devenv constraints
  - walker workaround
- `memory/project_ai_skills_layout.md` — original design
  decision and context
- `memory/project_ai_claude_passthrough.md` — Tasks 2/2b in the
  passthrough plan that operationalize this
