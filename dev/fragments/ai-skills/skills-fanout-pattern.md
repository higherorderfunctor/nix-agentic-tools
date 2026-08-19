## ai.skills Fanout Delegation Pattern

> **Last verified:** 2026-08-19 (commit pending — the retired generated-skill
> exception is removed; Stacked Workflows remains the sole skill-package program
> consumer). Prior: 2026-08-17 (commit pending — Codex now receives symlinked
> skill directories because 0.147.0 ignores the otherwise-uniform real directory
> containing symlinked leaves; migration validates ownership and moves the
> legacy directory intact to a state backup). Prior: 2026-08-16 (commit pending
> — stacked-workflows now uses `ai.programs.<name>.enable` plus nullable
> per-runtime B4 overrides to gate its per-runtime skill contributions; the
> backend inventory now reflects Claude's upstream delegation plus the direct
> Copilot and Kimchi helpers). Prior: 2026-08-01 (commit pending — Codex joins
> skills fanout at the native user-global and repository-local `.agents/skills`
> locations). Prior: 2026-04-08 (commit 97ac174 — refactor(devenv): ai.skills
> branches delegate through ecosystem options). If you touch any of the five CLI
> skills fanouts, `lib/ai/hm-helpers.nix:mkSkillEntries`, the skill-package
> factory, or upstream `programs.<cli>.skills` references, and this fragment
> isn't updated in the same commit, stop and fix it.

When an ecosystem has a native `programs.<cli>.skills` option, `ai.skills`
fanout MUST delegate through it. Otherwise its factory uses a shared helper
directly. Claude, Copilot, Kimchi, and Kiro preserve Layout B: a real skill
directory containing per-file store symlinks. Codex is the measured exception:
its scanner discovers Layout A, where the skill directory itself is a symlink.

### Backend pattern

| Branch  | HM route                           | Native directory  | Layout |
| ------- | ---------------------------------- | ----------------- | ------ |
| Claude  | `programs.claude-code.skills`      | `.claude/skills`  | B      |
| Codex   | `mkSkillDirectoryEntries` directly | `.agents/skills`  | A      |
| Copilot | `mkSkillEntries` directly          | `.copilot/skills` | B      |
| Kimchi  | `mkSkillEntries` directly          | `harness/skills`  | B      |
| Kiro    | `programs.kiro-cli.skills`         | `.kiro/skills`    | B      |

Codex 0.147.0 was probed with both shapes: a whole-directory symlink appeared in
`skills/list`, while a real directory whose `SKILL.md` was a symlink did not.
The official
[Codex skill documentation](https://developers.openai.com/codex/skills/)
explicitly supports symlinked skill folders, so both Home Manager and devenv
emit one `.agents/skills/<name>` link.

### Why this matters

Root and per-runtime skill pools still compose through one backend writer before
materialization. A second writer for the same native path would collide at
module evaluation. Claude and Kiro use their upstream recursive options; Copilot
and Kimchi use the equivalent shared helper. Codex uses the distinct
whole-directory helper because scanner compatibility outweighs the ability for
another module to contribute files inside one already-owned skill.

Consumers migrating from the former direct Claude `home.file` writer can have a
real `.claude/skills/<name>/` directory left on disk. If activation reports that
the path would be clobbered, run `home-manager switch -b backup` once;
subsequent activations use the uniform layout.

Codex's migration runs before Home Manager's `checkLinkTargets` and between
devenv's file cleanup and creation tasks. It validates every current skill
target before changing any: top-level and nested links must point under
`/nix/store`, legacy trees may otherwise contain only directories, and skill
names must be safe single path components. Symlinked `.agents` or `skills`
parents, a regular file, a non-store link, or another unexpected entry aborts
migration. After a clean preflight, the legacy directory moves intact under the
backend's state directory, preserving even empty directories for recovery;
existing store-backed top-level links are unlinked so the native writer can
replace them without following the old link.

### How to apply

- Use an upstream recursive skills option where one exists. Otherwise call
  `mkSkillEntries` for Layout B and `mkSkillDirectoryEntries` for Codex's Layout
  A.
- Do not add a second writer for a native skills path.
- Keep module-eval coverage for both root and per-runtime skill contributions.

### Codex destinations

Current official Codex documentation defines `$HOME/.agents/skills` as the user
scope and `<repo>/.agents/skills` as repository scope. Codex scans repo
locations from the current working directory up to the repository root and
supports symlinked skill folders. Therefore HM emits `.agents/skills`, while
devenv emits project-root `.agents/skills`; neither destination is derived from
`ai.codex.configDir`.

### Devenv counterpart

`devenv.files.*.source` is structurally incapable of recursive walks. Factories
that require Layout B use `mkDevenvSkillEntries`, which enumerates each leaf at
evaluation time and preserves nested relative paths. Codex instead relies on
devenv's identity behavior: one directory source creates the exact Layout A link
its scanner requires at project-root `.agents/skills/<name>`.

### Skill-package program gating

`lib/ai/mkSkillPackageModule.nix` uses `lib.ai.program.mkProgram` for package
enablement. Its portable option is `ai.programs.<name>.enable`; generated
`ai.<runtime>.programs.<name>.enable` leaves use B4 null-as-inherit semantics. A
resolved false runtime receives no package skills or router rule, while siblings
continue to inherit the portable value.

This controls whether the package writes its existing
`ai.<runtime>.{skills,rules}` entries; it does not move those entries to the
root pools. Both stacked-workflows facets import their own helper instance
because the two backend evaluations do not share pool values.

### Related

- `dev/fragments/devenv/files-internals.md` — devenv constraints
  - walker workaround
- `memory/project_ai_skills_layout.md` — original design decision and context
- `memory/project_ai_claude_passthrough.md` — Tasks 2/2b in the passthrough plan
  that operationalize this
