## Copilot config delivery — github.com Copilot

> **Last verified:** 2026-10-14 — `ai.copilot` is github.com Copilot: pools
> under `ai.copilot.github`, devenv-only delivery, `ai.copilot.cli` reserved for
> a launcher the module does not ship.
>
> **Settled — do not relitigate.**
>
> - **One record per product, not backend as product, and no
>   `.github/copilot-instructions.md`.** `ai.copilot` used to be copilot-cli
>   under Home Manager and github.com under devenv, chosen by backend, and the
>   context went to `.github/copilot-instructions.md`. The operator dropped the
>   CLI arm on 2026-10-14. github.com loads that file and the root AGENTS.md
>   additively (no dedupe outside the CLI), so a context copy in both doubled
>   every review prompt; the context now joins the shared AGENTS.md, which the
>   cloud agent and code review both read. Chat on github.com reads only
>   `copilot-instructions.md` and loses the always-on context, accepted. The CLI
>   arm, its measured discovery and the rejected `COPILOT_HOME` route:
>   `git show 6a45d50c:dev/fragments/ai-clis/copilot-config-delivery.md`.

### What github.com reads, and what this module writes

`packages/copilot-cli/lib/mkCopilot.nix` is the record. It has no package, so
the builder declares no launcher options and installs nothing;
`ai.copilot.enable` is the switch. Its pools live at `ai.copilot.github.*`
through `optionNamespaces.pools = ["github"]`. Only devenv writes:

| pool    | file                                            | github.com readers                     |
| ------- | ----------------------------------------------- | -------------------------------------- |
| context | root `AGENTS.md`, through the shared owner      | cloud agent, code review (root only)   |
| rules   | `<projectDir>/instructions/<n>.instructions.md` | cloud agent, code review, by `applyTo` |
| agents  | `<projectDir>/agents/<n>.md`                    | cloud agent (default branch)           |
| skills  | `<projectDir>/skills/<n>/SKILL.md`              | cloud agent, code review, on match     |

`projectDir` is `ai.copilot.github.projectDir` (default `.github`). Code review
reads the PR's head branch, so a PR that regenerates these files is reviewed
with its own copies.

- **Context** contributes `{key = "AGENTS.md";}` to `sharedAgentsMd`, with Codex
  and Kiro; contributions to one key must agree byte for byte.
- **Rules**: the matcher becomes the comma-joined `applyTo` and `null` becomes
  `"**"` (`lib/ai/transformers/copilot.nix`). Code review loads every file whose
  globs match a changed file, so a `**` rule rides on every review.
- **Agents**: a normalized record renders `name`, `description` and `tools`
  (comma string) frontmatter. github.com also reads `model` and `mcp-servers`;
  only a raw native file at `ai.copilot.github.agents.<n>` carries those.
  github.com caps a profile's prompt at 30,000 characters.
- Instruction files and agent profiles are read-only COPIES written by
  `ai:copilot:materialize-instructions`, one directory ledger each
  (`copilot-github-instructions.manifest`, `copilot-github-agents.manifest`):
  github.com reads the committed tree, where a store symlink dangles. A ledger
  claims only files its writer wrote, and the writer runs while Copilot is
  disabled, so N→0 and a disable retract the copies. Skills keep the shared
  skill writer's store links; this repository gitignores `.github/skills/`.

### What it refuses, and why

Every other shared surface is declared `backends = []` with GitHub's reason and
a docs.github.com link, so the shared registry warns at the path a consumer set:

| surface              | why github.com cannot take it from this module                           |
| -------------------- | ------------------------------------------------------------------------ |
| environmentVariables | the cloud agent's environment is `copilot-setup-steps.yml` and secrets   |
| hooks                | code review runs none; the cloud agent reads `.github/hooks/*.json` only |
| mcpServers           | a repository setting on github.com, not a file                           |
| settings             | no settings file; model and review options are repository settings       |
| shell                | GitHub's cloud environment, set by `copilot-setup-steps.yml`             |

Permissions has no shared option; its policy rows carry the same kind of reason.
Home Manager has no repository, so the four delivered pools warn there too. The
module stays registered on Home Manager for exactly that: a value set there
warns instead of vanishing. Package rule and skill contributors
(`mkSkillPackageModule.nix`) skip Copilot on Home Manager.

The hooks reason names a real reader this module does not serve: the cloud agent
loads `.github/hooks/*.json` from the default branch (bash entries only, `ask`
treated as `deny`). A hooks writer would be a new surface, not a fix.

### The CLI slot

`optionNamespaces.launcher = ["cli"]` reserves `ai.copilot.cli` for the Copilot
CLI. A record without `defaults.package` has no launcher, so nothing is declared
there yet. When the CLI returns it brings its package, and its launcher switch
then lives at `ai.copilot.cli.enable`, Kiro's shape. The CLI reads the same
repository files (`AGENTS.md`, `.github/instructions/`, `.github/agents/`,
`.github/skills/`) plus `~/.copilot`. `packages/copilot-cli/lib/wrapPackage.nix`
is its launcher, kept with `checks/copilot-wrapper-argv.nix` and installed by
nothing today.
