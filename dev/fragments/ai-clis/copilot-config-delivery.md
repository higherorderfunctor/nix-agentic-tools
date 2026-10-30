## Copilot config delivery — github.com Copilot

> **Last verified:** 2026-10-29 — `ai.copilot.github` writes its own context to
> `<projectDir>/<context.filename>` (default `.github/copilot-instructions.md`)
> and each named rule to its native instructions file, independently of the
> shared AGENTS.md composer. Home Manager retains explicit unsupported warnings.
>
> **Settled — do not relitigate.**
>
> - **One record per product.** The operator dropped the backend-dependent CLI
>   arm on 2026-10-14. `ai.copilot` serves github.com; the reserved CLI
>   namespace declares no launcher. The old CLI discovery and rejected
>   `COPILOT_HOME` route:
>   `git show 6a45d50c:dev/fragments/ai-clis/copilot-config-delivery.md`.
> - **No agents writer.** The operator dropped it on 2026-10-15: this arm serves
>   github.com code review, which never reads `.github/agents`. The writer:
>   `git show 650695d9:packages/copilot-cli/lib/mkCopilot.nix`.

### What github.com reads, and what this module writes

`packages/copilot-cli/lib/mkCopilot.nix` is the record. It has no package, so
the builder declares no launcher options and installs nothing;
`ai.copilot.enable` is the switch. Its pools live at `ai.copilot.github.*`
through `optionNamespaces.pools = ["github"]`. Only devenv writes:

| pool    | file                                            | github.com readers                     |
| ------- | ----------------------------------------------- | -------------------------------------- |
| context | `<projectDir>/<context.filename>`               | chat, cloud agent, code review         |
| rules   | `<projectDir>/instructions/<n>.instructions.md` | cloud agent, code review, by `applyTo` |
| skills  | `<projectDir>/skills/<n>/`                      | cloud agent                            |

`projectDir` is `ai.copilot.github.projectDir` (default `.github`). Code review
reads the PR's head branch, so a PR that regenerates these files is reviewed
with its own copies.

- **Context** composes the unnamed shared `ai.context` and
  `ai.copilot.github.context` into its own file using the generic text/source
  conversion and generated-tree writer. `context.filename` defaults to
  `copilot-instructions.md` beneath `projectDir`. Copilot contributes nothing to
  the shared AGENTS.md composer or its cross-runtime deduplication. GitHub
  products may additionally read a committed AGENTS.md; the library does not
  route Copilot context through that file.
- **Rules**: the matcher becomes the comma-joined `applyTo` and `null` becomes
  `"**"` (`lib/ai/transformers/copilot.nix`). Code review loads every file whose
  globs match a changed file, so a `**` rule rides on every review. Named
  always-on rules stay separate files just like scoped rules; a runtime-local
  `enable = false` suppresses an inherited rule at the same key.
- **Skills** use `helpers.mkSkillFiles`, the same builder as every runtime, with
  `configDir = projectDir` and `method = "ro"`. The engine expands each source
  directory into owned real files, preserving nested references, assets and
  executable bits. File symlinks become regular copies; directory symlinks fail
  evaluation rather than leaving committed links or missing subtrees.
  Single-file skills become `<projectDir>/skills/<name>/SKILL.md`. Root skills,
  runtime replacements and null suppression follow the shared pool merge.
- Instructions and skills are staged in `ai.copilot._generatedFiles` as
  read-only COPIES (`method = "ro"`) that the ai-module files engine writes:
  github.com reads the committed tree, where a store symlink dangles. The engine
  owns each copy by path, so a hand-written sibling survives and N→0 or a
  disable retracts the copies. The old writer's directory ledgers
  (`copilot-instructions.manifest`, `copilot-github-agents.manifest`) stay
  declared in `ai.copilot.legacyLedgers` while Copilot is disabled too, so the
  copies they recorded are imported once and then follow the plan; the agents
  ledger thereby retires the profiles the old writer left.

### What it refuses, and why

Every other shared surface is declared `backends = []` with GitHub's reason and
a docs.github.com link, so the shared registry warns at the path a consumer set:

| surface              | why github.com cannot take it from this module                           |
| -------------------- | ------------------------------------------------------------------------ |
| agents               | code review never reads `.github/agents`                                 |
| environmentVariables | the cloud agent's environment is `copilot-setup-steps.yml` and secrets   |
| hooks                | code review runs none; the cloud agent reads `.github/hooks/*.json` only |
| mcpServers           | a repository setting on github.com, not a file                           |
| settings             | no settings file; model and review options are repository settings       |
| shell                | GitHub's cloud environment, set by `copilot-setup-steps.yml`             |

Permissions has no shared option; its policy rows carry the same kind of reason.
Home Manager has no repository, so the three delivered pools warn there too. The
module stays registered on Home Manager for exactly that: a value set there
warns instead of vanishing. Package rule and skill contributors
(`mkSkillPackageModule.nix`) skip Copilot on Home Manager.

The repository's `dev/ai.nix` enables only Copilot and null-suppresses its root
skills for Copilot because they operate local sessions. Contributors opt into
Claude, Codex, Kimchi, Kiro CLI, peer communication and Semble in ignored
`devenv.local.nix`; repository runtime and program settings remain in
`dev/ai.nix`. Package runtime disables remain authoritative, including peer
communication's explicit Copilot disable. `.github/skills` is committable when a
consumer selects skills.

The hooks reason names a real reader this module does not serve: the cloud agent
loads `.github/hooks/*.json` from the default branch (bash entries only, `ask`
treated as `deny`). A hooks writer would be a new surface, not a fix.

### The CLI slot

`optionNamespaces.launcher = ["cli"]` reserves `ai.copilot.cli` for the Copilot
CLI. A record without `defaults.package` has no launcher, so nothing is declared
there yet. When the CLI returns it brings its package, and its launcher switch
then lives at `ai.copilot.cli.enable`, Kiro's shape. The CLI reads the same
repository files (`AGENTS.md`, `.github/instructions/`, `.github/agents/`,
`.github/skills/`) plus `~/.copilot`.
