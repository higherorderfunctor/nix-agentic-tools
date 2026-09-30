## Stacked Workflows Development

> **Last verified:** 2026-09-29 — owner checks include sequential scenario tests
> of the published skill and reference recipes; `gitPreset` remains `mkDefault`
> sugar over `git.*`, declared once in `modules/options.nix`.
>
> Full lineage:
> `git show 89dce4c4:packages/stacked-workflows/docs/development.md`.

### Package Structure

Stacked workflow content lives in `packages/stacked-workflows/` as a published
content package with per-backend modules:

- `packages/stacked-workflows/skills/<name>/SKILL.md` — consumer-facing skill
  definitions
- `packages/stacked-workflows/references/*.md` — tool reference docs shared by
  all skills (bundled as REAL files inside each skill dir at build time; see
  `packages/stacked-workflows/packages/stacked-workflows-content/package.nix`)
- `packages/stacked-workflows/router.nix` — the keyed skill-routing rule, shared
  by both backend modules
- `packages/stacked-workflows/lib/git-config*.nix`, `lib/git-presets.nix` —
  shared Git preset data (git-key shaped)
- `packages/stacked-workflows/modules/options.nix` — `gitPreset`, declared once
  and imported by both backends
- `packages/stacked-workflows/modules/homeManager/` — user-global module
  (skills + skill-routing rule)
- `packages/stacked-workflows/modules/devenv/` — project-local module (skills +
  skill-routing rule)
- `packages/stacked-workflows/docs/development.md` — this package-owned
  development guide
- `packages/git-absorb/`, `packages/git-branchless/`, `packages/git-revise/` —
  the three git tools, each now its own owner facet with its recipe at
  `packages/<name>/packages/ai/gitTools/<name>/package.nix`

### Git Config Presets

`stacked-workflows.gitPreset` (`"none"`, `"minimal"`, `"full"`) is declared once
in `modules/options.nix` and is pure sugar over the `git.*` options that
packages/git and the three git tool owners declare. It applies only while
`ai.programs.stacked-workflows.enable` is true, and sets everything at
`mkDefault`:

- a tool's section of the preset data (`absorb`, `branchless`, `revise`) → that
  tool's typed `git.<section>.settings`, whole option values. A key that is not
  a typed option fails evaluation;
- every other key → `git.settings`, per leaf;
- `scopedSync = true` (full only) → `git.branchless.scopedSync`;
- `git.{absorb,branchless,revise}.enable`, which installs the three tools on
  both backends and runs `git branchless init` on devenv.

Delivery, precedence and init are the git layer's (packages/git/docs/git.md):
Home Manager writes `programs.git.settings`, devenv a repository-local include
kept last. The package installs are new with this sugar: before it, Home Manager
installed nothing and devenv installed git-branchless.

Value changes against the data before this design, and nothing else (checked by
`module-sws-presets-approved-diff` against a fixture frozen at `cd934bb4`):

- `branchless.core.mainBranch = "main"` is gone from both presets. Init writes
  the detected main branch into every repository, so a user-global value is dead
  there and a repository-local one forced `main` onto `master` repositories.
  `init.defaultBranch = "main"` still steers detection.
- `fetch.pruneTags` is gone from full: it deletes local tags without a remote
  counterpart from every worktree on any fetch, including pre-rebase backups.
- full adds `alias.sync = "branchless sync 'stack()'"` (scopedSync).

The `pull.ff` assertion (`pull.ff = "only"` beats `pull.rebase` since Git 2.34)
is shared as well: it reads the merged `git.settings`, which on Home Manager is
`programs.git.settings`, so devenv now has it too.

### Skills + Skill-Routing Rule

`ai.programs.stacked-workflows.enable = true` fans the (unprefixed) `stack-*`
skills into the PER-RUNTIME `ai.<runtime>.skills` pool of every supported
runtime present in the evaluation. The `stacked-workflows-router` rule also fans
into each runtime that exposes an `ai.<runtime>.rules` pool; Kimchi has no rules
capability and receives only the skills. Each enabled AI CLI installs its
contribution at its native path.
`ai.<runtime>.programs.stacked-workflows.enable = false` disables that runtime's
contribution only. Both backend modules delegate to the shared
`lib/ai/mkSkillPackageModule` factory; those pools are per-`evalModules`, so the
HM (user-global) and devenv (project-local) contributions are independent.

It writes the per-runtime pools rather than root `ai.skills` because a root pool
belongs to consumers as a portable default surface — the provenance guard in
`checks/module-provenance/module-eval.nix` enforces that. **The practical
consequence for a consumer: override or suppress a package skill at
`ai.<runtime>.skills.<name>` and, on rule-capable runtimes, the router at
`ai.<runtime>.rules.stacked-workflows-router`.** Package values use `mkDefault`,
so an explicit value or null wins at that runtime scope. A same-key root entry
is replaced by the package's per-runtime value rather than colliding.

### Building and Testing

```bash
nix build .#git-absorb          # Build git-absorb overlay
nix build .#git-branchless      # Build git-branchless overlay
nix build .#git-revise          # Build git-revise overlay
nix flake check                 # Run module eval checks
```

### Scenario tests

`checks.stacked-workflows-scenarios` runs the published shell examples against
isolated Git repositories using this flake's Git tools. Its runner lives in
`checks/scenario-tests/` and supports both a checkout and an immutable source
directory without Git history. Cases execute sequentially, without Nix or
network access, and fail on any assertion or execution error.

Run `nix build .#checks.x86_64-linux.stacked-workflows-scenarios -L` for the
same check CI runs. To exercise working-tree edits with tools already on PATH,
run `bash packages/stacked-workflows/checks/scenario-tests/run.sh`. The adjacent
README documents targeted cases and retained failure artifacts. When changing a
recipe, update its stable block IDs and add a behavioral case; verify that
reverting the recipe in a scratch source copy makes that case fail.
