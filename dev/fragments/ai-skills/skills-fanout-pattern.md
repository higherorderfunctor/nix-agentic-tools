## ai.skills Fanout Delegation Pattern

> **Last verified:** 2026-09-22 — Kimchi's Layout B directory is
> backend-specific: Home Manager uses the user harness, while devenv uses
> Kimchi's native project root.
>
> Full lineage:
> `git show 25ec0738:dev/fragments/ai-skills/skills-fanout-pattern.md`.

When an ecosystem has a native `programs.<cli>.skills` option, `ai.skills`
fanout MUST delegate through it. Otherwise its factory uses a shared helper
directly. Claude, Copilot, Kimchi, and Kiro preserve Layout B: a real skill
directory containing per-file store symlinks. Codex is the measured exception:
its scanner discovers Layout A, where the skill directory itself is a symlink.

### Backend pattern

| Branch  | HM route                             | Native directories                           | Layout |
| ------- | ------------------------------------ | -------------------------------------------- | ------ |
| Claude  | `programs.claude-code.skills`        | `.claude/skills`                             | B      |
| Codex   | `mkSkillFiles` (`recursive = false`) | `.agents/skills`                             | A      |
| Copilot | `mkSkillFiles`                       | `.copilot/skills`                            | B      |
| Kimchi  | `mkSkillFiles`                       | HM `harness/skills`; devenv `.kimchi/skills` | B      |
| Kiro    | `mkSkillFiles`                       | `.kiro/skills`                               | B      |

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
  `helpers.mkSkillFiles`, which writes DELIVERY entries into
  `ai.<runtime>.files` for both backends: `recursive = true` is Layout B, and
  `recursive = false` with a directory source is Codex's Layout A.
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

`devenv.files.*.source` is structurally incapable of recursive walks, so the
DELIVERY ROUTER walks a `recursive` entry at evaluation time and emits one
devenv entry per leaf, preserving nested relative paths. That walk is shared: it
replaced the per-backend skill helpers and kiro's inline agents-directory copy
of the same recursion, so a factory declares the tree once and both backends
expand it. Codex instead relies on devenv's identity behavior: one directory
source creates the exact Layout A link its scanner requires at project-root
`.agents/skills/<name>`.

Kimchi gives the recursive entry a `.kimchi/skills/<name>` project path on
devenv and a `<configDir>/harness/skills/<name>` user path on Home Manager.

A skill entry states `executable = null`, which reaches the sink as an absent
attribute and leaves every file's mode alone. Stating a mode there would clear
the executable bit on a script a skill ships.

### Skill-package program gating

`lib/ai/mkSkillPackageModule.nix` uses `lib.ai.program.mkProgram` for package
enablement. Its portable option is `ai.programs.<name>.enable`; generated
`ai.<runtime>.programs.<name>.enable` leaves use B4 null-as-inherit semantics. A
resolved false runtime receives no package skills or router rule, while siblings
continue to inherit the portable value.

The factory passes `config`, `lib`, `pkgs` and `runtime` to both `skills` and
`rules` callbacks. Import it once with the full supported runtime set; render
per-runtime content inside the callbacks. Existing callbacks that ignore
`runtime`, such as stacked-workflows, keep the same behavior.

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
