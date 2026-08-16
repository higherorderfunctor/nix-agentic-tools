## ai.skills Fanout Delegation Pattern

> **Last verified:** 2026-08-16 (commit pending — stacked-workflows and
> living-workflow now use `ai.programs.<name>.enable` plus nullable per-runtime
> B4 overrides to gate their existing per-runtime skill contributions; the
> backend inventory now reflects Claude's upstream delegation plus the direct
> Copilot and Kimchi helpers). Prior: 2026-08-01 (commit pending — Codex joins
> skills fanout at the native user-global and repository-local `.agents/skills`
> locations). Prior: 2026-04-08 (commit 97ac174 — refactor(devenv): ai.skills
> branches delegate through ecosystem options). If you touch any of the five CLI
> skills fanouts, `lib/ai/hm-helpers.nix:mkSkillEntries`, the skill-package
> factory, or upstream `programs.<cli>.skills` references, and this fragment
> isn't updated in the same commit, stop and fix it.

When an ecosystem has a native `programs.<cli>.skills` option, `ai.skills`
fanout MUST delegate through it. Otherwise its factory uses the shared recursive
helper directly. Both routes must preserve Layout B: a real skill directory
containing per-file store symlinks.

### Uniform pattern

| Branch  | HM route                      | Native directory  |
| ------- | ----------------------------- | ----------------- |
| Claude  | `programs.claude-code.skills` | `.claude/skills`  |
| Codex   | `mkSkillEntries` directly     | `.agents/skills`  |
| Copilot | `mkSkillEntries` directly     | `.copilot/skills` |
| Kimchi  | `mkSkillEntries` directly     | `harness/skills`  |
| Kiro    | `programs.kiro-cli.skills`    | `.kiro/skills`    |

On-disk layout is identical across all five: a real native `skills/<name>/`
directory with per-file store symlinks inside, via `recursive = true` in each
helper.

### Why this matters

The uniform layout lets root and per-runtime skill pools compose through one
backend writer. A second writer for the same native path would collide at module
evaluation, while a wholesale directory symlink would prevent another module
from contributing sibling files. Claude and Kiro therefore use their upstream
recursive options; Codex, Copilot, and Kimchi use the equivalent shared helper
because they have no upstream option to delegate through.

Consumers migrating from the former direct Claude `home.file` writer can have a
real `.claude/skills/<name>/` directory left on disk. If activation reports that
the path would be clobbered, run `home-manager switch -b backup` once;
subsequent activations use the uniform layout.

### How to apply

- Use an upstream recursive skills option where one exists; otherwise call
  `mkSkillEntries` for Home Manager and `mkDevenvSkillEntries` for devenv.
- Do not add a second writer for a native skills path or replace Layout B with a
  wholesale directory symlink.
- Keep module-eval coverage for both root and per-runtime skill contributions.

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

### Skill-package program gating

`lib/ai/mkSkillPackageModule.nix` uses `lib.ai.program.mkProgram` for package
enablement. Its portable option is `ai.programs.<name>.enable`; generated
`ai.<runtime>.programs.<name>.enable` leaves use B4 null-as-inherit semantics. A
resolved false runtime receives no package skills or router rule, while siblings
continue to inherit the portable value.

This controls whether the package writes its existing
`ai.<runtime>.{skills,rules}` entries; it does not move those entries to the
root pools. Both the stacked-workflows and living-workflow HM/devenv facets
import their own helper instance because the two backend evaluations do not
share pool values.

### Related

- `dev/fragments/devenv/files-internals.md` — devenv constraints
  - walker workaround
- `memory/project_ai_skills_layout.md` — original design decision and context
- `memory/project_ai_claude_passthrough.md` — Tasks 2/2b in the passthrough plan
  that operationalize this
