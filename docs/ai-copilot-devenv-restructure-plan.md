# `ai.copilot` devenv project-scope restructure

> **Status:** plan only; proceeding autonomously. User will review
> journal post-execution.
>
> **Goal:** devenv output for `ai.copilot` should target Copilot's
> real project-scope file layout (`.github/copilot-instructions.md`,
> `.github/instructions/`, `.github/agents/`, `.github/skills/`) for
> files Copilot actually reads at project scope. Non-project-scope
> artifacts (mcp-config.json, lsp-config.json, settings.json) that
> have no Copilot-defined project-scope location stay at
> `configDir` — they exist to be pointed at by the wrapper, not
> to be auto-read.

## Why

Today devenv writes everything into `<root>/.config/github-copilot/*`,
same as HM (a legacy of the config consolidation). That's wrong for
project-scope files. Copilot CLI + cloud Copilot both read
project-scope content from `.github/*` and root `AGENTS.md`; nothing
reads `<root>/.config/github-copilot/*` except through explicit CLI
flags we set on our wrapper.

Net effect today: devenv users adding `ai.copilot.context = "…"`
produce a file at `<root>/.config/github-copilot/copilot-instructions.md`
that nothing reads.

## Scope split

**Project-scope (Copilot-read, move to `.github/*`):**

- `copilot-instructions.md` (from `cfg.context`)
- `instructions/*.instructions.md` (from rules) — ALREADY at `.github/` today
- `agents/<name>.agent.md` (from agents option) — note Copilot CLI
  convention is `.agent.md` suffix, not plain `.md`
- `skills/<name>/*` (from mergedSkills)

**Wrapper-dir (no Copilot project-scope reader; keep at `configDir`):**

- `mcp-config.json` — pointed at by `--additional-mcp-config` wrapper flag
- `lsp-config.json` — Copilot has no project-scope LSP config reader
- `settings.json` — Copilot settings are personal-scope only;
  devenv writing it is a misconception but harmless and non-breaking
  to keep for now

## Option reshape

Keep `configDir` as the dir for wrapper-dir files. Add
`projectDir` (new option, default `.github`) for project-scope
files. Same per-backend-declaration pattern as the configDir work
in commit `164b541` — HM declares it, devenv declares it, different
defaults/semantics per backend.

HM: personal-scope only; `projectDir` not needed (no equivalent
user-dir for project content). Declare only in `devenv.options`.

```nix
devenv = {
  options = {
    configDir = lib.mkOption {
      type = lib.types.str;
      default = ".config/github-copilot";
      description = "Wrapper-pointed config dir (mcp-config, lsp-config, settings).";
    };
    projectDir = lib.mkOption {
      type = lib.types.str;
      default = ".github";
      description = "Project-scope dir Copilot reads (instructions, agents, skills, copilot-instructions).";
    };
  };
  …
};
```

## File layout changes (devenv)

| Old                                                     | New                                      |
| ------------------------------------------------------- | ---------------------------------------- |
| `<root>/.config/github-copilot/copilot-instructions.md` | `<root>/.github/copilot-instructions.md` |
| `<root>/.config/github-copilot/agents/<name>.md`        | `<root>/.github/agents/<name>.agent.md`  |
| `<root>/.config/github-copilot/skills/<skill>/*`        | `<root>/.github/skills/<skill>/*`        |
| `<root>/.github/instructions/<name>.instructions.md`    | unchanged                                |
| `<root>/.config/github-copilot/lsp-config.json`         | unchanged                                |
| `<root>/.config/github-copilot/mcp-config.json`         | unchanged                                |
| `<root>/.config/github-copilot/settings.json`           | unchanged                                |

Note the `.agent.md` suffix addition for agent files — Copilot CLI
convention.

## HM untouched

HM is personal-scope. `~/.copilot/*` is correct (after commit
`164b541`). HM files stay in `~/.copilot/*`.

The `.github/instructions/*.instructions.md` paths in mkCopilot's
HM code today are arguably wrong for HM (that path only makes sense
relative to a project root, not HOME). But that's a separate
question; HM instructions are a minor surface today and out of scope
here. Noted as a follow-up.

## Out of scope

- HM `.github/instructions/` oddity. Separate.
- Whether devenv should write lsp-config / mcp-config / settings at
  all (they're wrapper-aimed, not Copilot-read). Kept as-is; pruning
  them is a separate decision.
- Typed LSP migration. Separate plan.

## Plan

### 1. Add `projectDir` option to `mkCopilot.nix` `devenv.options`

Follows the `configDir` per-backend-declaration pattern from
`164b541`. HM devenv block is unchanged (no `projectDir` for HM).

### 2. Rewrite devenv file writes

In the `devenv.config` callback, change file paths:

- Context write: `files."${cfg.configDir}/${cfg.contextFilename}"`
  → `files."${cfg.projectDir}/${cfg.contextFilename}"`.
- Agents inline: `files."${cfg.configDir}/agents/${name}.md"` →
  `files."${cfg.projectDir}/agents/${name}.agent.md"`.
- Agents dir walker: same relocation + rename.
- Skills helper: `mkDevenvSkillEntries` writes to
  `${cfg.configDir}/skills/…` today; redirect to
  `${cfg.projectDir}/skills/…`.
- Instructions/rules already at `.github/instructions/`; unchanged.
- lsp-config, mcp-config, settings: unchanged (stay at configDir).

### 3. Symlink wrapper path unchanged

The HM wrapper injects `--additional-mcp-config $HOME/${configDir}/mcp-config.json`.
Devenv has no wrapper today (env flows through native devenv `env`
attrset; `--additional-mcp-config` isn't injected in devenv — yet).
Nothing to adjust in the wrapper.

### 4. Module-eval test updates

Find tests asserting paths under `.config/github-copilot/` for
devenv Copilot and update the expected paths:

- Copilot devenv agent files: `.config/github-copilot/agents/reviewer.md`
  → `.github/agents/reviewer.agent.md`
- Copilot devenv copilot-instructions.md test: `.config/github-copilot/`
  → `.github/`.
- Skills test similar.
- Keep unchanged: devenv LSP/MCP config JSON path assertions (those
  stay at configDir).

### 5. Plan.md bullet close-out

Mark the backlog bullet as SHIPPED with commit SHA reference.

### 6. Commit

Single commit: `feat(copilot): devenv project-scope restructure —
project files to .github, wrapper-dir unchanged`. Breaking for any
consumer reading the old paths; consistent with repo policy on
breaking changes (user is sole consumer, confirmed 2026-04-21).

## Size estimate

~30 lines factory rewrite + ~3–4 test path updates + 1 plan.md edit.

## Review checklist

- [ ] `projectDir` declared in `devenv.options` only (not HM).
- [ ] Context, agents, skills emission paths use `projectDir`.
- [ ] Agent filenames use `.agent.md` suffix.
- [ ] lsp-config / mcp-config / settings paths unchanged.
- [ ] HM block untouched.
- [ ] Tests updated for relocated paths; unchanged paths still pass.
- [ ] Plan.md backlog bullet closed.
- [ ] Commit message marks breaking change explicitly.
