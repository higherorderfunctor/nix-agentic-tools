# nix-agentic-tools

Stacked commit workflows, MCP servers, and declarative configuration for AI
coding CLIs (Claude Code, Codex, Copilot, Kiro). Works without Nix; Nix unlocks
overlays, home-manager modules, and devenv modules.

## Quick Start

<details>
<summary><strong>Non-Nix (copy skills into your project)</strong></summary>

Prerequisites: [git-branchless](https://github.com/arxanas/git-branchless),
[git-absorb](https://github.com/tummychow/git-absorb),
[git-revise](https://github.com/mystor/git-revise).

```bash
# Claude Code
cp -r packages/stacked-workflows/skills/stack-* .claude/skills/

# OpenAI Codex
cp -r packages/stacked-workflows/skills/stack-* .agents/skills/

# GitHub Copilot
cp -r packages/stacked-workflows/skills/stack-* .github/skills/

# Kiro
cp -r packages/stacked-workflows/skills/stack-* .kiro/skills/
```

Each skill is self-contained with a `SKILL.md` and bundled reference docs.

</details>

<details>
<summary><strong>Home-Manager (system-level declarative config)</strong></summary>

```nix
# flake.nix
inputs.nix-agentic-tools = {
  url = "github:higherorderfunctor/nix-agentic-tools";
};

# Optional: `pkgs.ai.*` for your own use. The modules install this flake's
# builds without it.
nixpkgs.overlays = [inputs.nix-agentic-tools.overlays.default];

# Unfree: claude-code, copilot-cli, kimchi-docs, kiro-cli and kiro-cli-workflows.
# Allow them in the nixpkgs.config your pkgs comes from (NixOS's when
# useGlobalPkgs is set).

# Home-manager config
imports = [inputs.nix-agentic-tools.homeManagerModules.default];

ai = {
  claude.enable = true;
  codex = {
    enable = true;
    settings.model = "gpt-5.6-sol";
  };
  copilot.enable = true;
  kiro.enable = true;
  programs.delegate-routing.enable = true;
  programs.stacked-workflows.enable = true;
  settings.reasoningEffort = "high";
};

# Git companion: mkDefault values on the git.* options, which Home Manager
# applies user-global and devenv at repository scope.
stacked-workflows.gitPreset = "full";

services.mcp-servers.servers.github-mcp = {
  enable = true;
  settings.credentials.file = "/run/secrets/github-token";
};
```

> **Static runtime files:** every runtime exposes
> `ai.<runtime>.files."<relative-path>" = { text = "…"; };`. An entry can
> instead set `source = ./file`. Generated context/rule outputs use the same
> final map at default priority, so an ordinary whole entry replaces them and
> `null` suppresses them. Paths are relative to HOME here and to the project
> under devenv.

</details>

<details open>
<summary><strong>DevEnv (per-project dev shell)</strong></summary>

```yaml
# devenv.yaml
# Unfree: claude-code, copilot-cli, kimchi-docs, kiro-cli and kiro-cli-workflows.
# Opt in as for nixpkgs.
allowUnfree: true
inputs:
  nix-agentic-tools:
    url: github:higherorderfunctor/nix-agentic-tools
```

```nix
# devenv.nix
{inputs, ...}: {
  imports = [inputs.nix-agentic-tools.devenvModules.nix-agentic-tools];

  # Optional: the modules install this flake's builds without it. Apply it
  # to use or override `pkgs.ai.*` yourself; the modules then install your
  # `pkgs.ai.*`. `package = null` configures a runtime without installing one.
  overlays = [inputs.nix-agentic-tools.overlays.default];

  ai = {
    claude.enable = true;
    codex.enable = true;

    mcpServers.github-mcp = {
      type = "stdio";
      command = "github-mcp-server";
      args = ["--stdio"];
    };
  };
}
```

</details>

### Binary cache

CI builds every package here with this flake's own nixpkgs and pushes the
results to `nix-agentic-tools.cachix.org`. The overlay and the module package
defaults hand you those same builds, so they come from the cache whatever
nixpkgs you use.

Add the cache to your own Nix configuration. This flake's `nixConfig` lists it,
but Nix ignores a flake's substituters unless you are a trusted user.

```nix
# NixOS (or nix-darwin)
nix.settings = {
  extra-substituters = ["https://nix-agentic-tools.cachix.org"];
  extra-trusted-public-keys = ["nix-agentic-tools.cachix.org-1:0jFprh5fkDez9mk6prYisYxzalr0hn78kyywGPXvOn0="];
};
```

```ini
# nix.conf
extra-substituters = https://nix-agentic-tools.cachix.org
extra-trusted-public-keys = nix-agentic-tools.cachix.org-1:0jFprh5fkDez9mk6prYisYxzalr0hn78kyywGPXvOn0=
```

The packages bring this flake's runtime base (glibc, bash, and so on, about 100
MB) next to your own, from `cache.nixos.org`, shared by every package here.
Module defaults also evaluate a second nixpkgs, like any flake whose modules
default to its own packages.

### Package sets, unfree, and opting out

- **One nixpkgs builds everything.** This flake's `nixpkgs` input builds the
  overlay, the module defaults, `packages` and `legacyPackages`. Your own
  overlays on shared dependencies do not reach these packages, and security
  fixes arrive when this flake bumps nixpkgs (the update sweep runs four times a
  day). Go and Rust compilers come from this flake's locked toolchain inputs.
- **Unfree is your opt-in, decided by your own nixpkgs.** Each package's own
  license and platform are checked by your nixpkgs with your config
  (`allowUnfree`, `allowUnfreePredicate`, ...), with nixpkgs' own error when it
  refuses, and `meta.available` reports that verdict. The package set itself,
  dependencies included, is built once with this flake's nixpkgs. The check
  never changes a store path, so it costs no cache hits, and there is nothing to
  keep in sync. Set them where you set them for nixpkgs (`nixpkgs.config`, or
  devenv.yaml `allowUnfree`). A `checkMeta = true` config on a nixpkgs older
  than this flake's may reject newer meta keys; `checkMeta` is a nixpkgs-CI
  setting, default false.
- **`packages.<system>` is free packages only.** `legacyPackages.<system>` has
  every package plus the nested `ai` tree. `nix run` on an unfree package
  resolves there and needs your opt-in, as in nixpkgs:
  `NIXPKGS_ALLOW_UNFREE=1 nix run --impure github:higherorderfunctor/nix-agentic-tools#claude-code`.
- **Swap a dependency with `.override`.** Overriding a package's bun, pnpm, Go
  or Rust works and costs a rebuild of that package.
- **`follows` is the opt-out.** Setting
  `inputs.nix-agentic-tools.inputs.nixpkgs.follows = "nixpkgs"` rebuilds every
  package on your nixpkgs, with no cache. You then own breakage where a recipe
  borrows nixpkgs' recipe text, patches or fetchers: tsgolint's patch list,
  kiro-cli's install step, the pnpm fetcher versions, Go `vendorHash`.
- **Other systems build locally.** On systems this flake does not build
  (anything but `aarch64-darwin` and `x86_64-linux`), cross builds, and musl or
  static package sets, the overlay builds on your package set.

## Skills

Delegate routing for models and effort, plus stacked commit workflows using
git-branchless, git-absorb, and git-revise.

<!-- prettier-ignore -->
| Skill | Description |
|-------|-------------|
| `/delegate-routing` | Size model and effort before calling subagents or building workflows |
| `/kimchi-docs` | Search the pinned Kimchi docs snapshot and independently pinned workflows source, docs and examples; enable via ai.programs.kimchi-docs.enable |
| `/stack-fix` | Absorb fixes into correct stack commits |
| `/stack-plan` | Plan and build a commit stack from description or existing commits |
| `/stack-split` | Split a large commit into reviewable atomic commits |
| `/stack-submit` | Sync, validate, push stack, and create stacked PRs |
| `/stack-summary` | Analyze stack quality, flag violations, produce planner-ready summary |
| `/stack-test` | Run tests or formatters across commits in a stack |

## Packages

<details>
<summary><strong>MCP Servers</strong> (16 servers)</summary>

<!-- prettier-ignore -->
| Server | Description | Credentials |
|--------|-------------|-------------|
| `aihubmix-mcp` | AIHubMix image and video generation | Required |
| `context7-mcp` | Library documentation lookup | None |
| `effect-mcp` | Effect-TS documentation | None |
| `fetch-mcp` | HTTP fetch + HTML-to-markdown | None |
| `git-intel-mcp` | Git repository analytics | None |
| `git-mcp` | Git operations | None |
| `github-mcp` | GitHub platform integration | Required |
| `gitlab-mcp` | GitLab platform integration | Required |
| `kagi-mcp` | Kagi search and summarization | Required |
| `mcp-language-server` | LSP-to-MCP bridge | None |
| `mcp-proxy` | stdio-to-HTTP bridge proxy | None |
| `nixos-mcp` | NixOS and Nix documentation | None |
| `semble-mcp` | Local semantic and lexical code search | None |
| `sequential-thinking-mcp` | Step-by-step reasoning | None |
| `serena-mcp` | Codebase-aware semantic tools | Optional |
| `sympy-mcp` | Symbolic mathematics | None |

```bash
nix build .#github-mcp
```

</details>

<details>
<summary><strong>Git Tools</strong></summary>

<!-- prettier-ignore -->
| Package | Description |
|---------|-------------|
| `agnix` | Linter, LSP, and MCP for AI config files |
| `git-absorb` | Automatic fixup commit routing |
| `git-branchless` | Anonymous branching, in-memory rebases |
| `git-revise` | In-memory commit rewriting |

```bash
nix build .#git-absorb
```

The same `git.*` options exist on Home Manager and devenv. Each tool's settings
are typed from a census of its source and mirror the git key; `enable` installs
the tool:

```nix
git = {
  absorb = {
    enable = true;
    settings.maxStack = 50; # absorb.maxStack
  };
  branchless = {
    enable = true; # devenv also runs `git branchless init` on entry
    scopedSync = true; # bare `git sync` moves the current stack only
    settings.test.strategy = "worktree"; # branchless.test.strategy
  };
  settings.merge.conflictStyle = "zdiff3"; # any other git key
};
```

Home Manager delivers them through `programs.git.settings` (`git.settings` is an
alias of it). devenv writes a repository-local include kept after every other
repository setting, so its values win key by key over user-global ones and hand
edits, while keys it does not set fall through.

</details>

<details>
<summary><strong>Dev Tools</strong></summary>

Agent-adjacent development utilities exposed as `pkgs.ai.devTools.*`.

<!-- prettier-ignore -->
| Package | Description |
|---------|-------------|
| `beads` | Graph-based issue tracker for AI coding agents |
| `gh` | GitHub CLI |
| `glab` | GitLab CLI |
| `markdownlint-cli2` | Configuration-based markdown linter (markdownlint) |
| `microvm` | The microvm.nix CLI for managing declared MicroVMs |
| `oxlint` | Fast JS/TS linter with type-aware (tsgo) linting and JS plugins |
| `rumdl` | Fast Rust markdown linter (markdownlint-compatible rules) |
| `tsgolint` | Type-aware linting backend for oxlint (typescript-go) |

```bash
nix build .#oxlint
```

</details>

<details>
<summary><strong>Generic Packages</strong></summary>

Temporarily unclassified supporting packages live in the split-ready
`packages/<owner>/packages/ai/generic/` trees and are exposed as
`pkgs.ai.generic.*`.

<!-- prettier-ignore -->
| Package | Description |
|---------|-------------|
| `arkenfox` | Hardened Firefox user.js preference set |
| `bruno` | Open-source IDE for exploring and testing APIs |
| `btop` | Resource monitor for processes, CPU, memory, disks and network |
| `bun` | JavaScript runtime, bundler, transpiler and package manager |
| `catppuccin-btop` | Catppuccin theme files for btop |
| `dns-root-hints` | IANA DNS root name server hints (named.root) |
| `fblog` | Command-line JSON log viewer |
| `gluetun` | VPN client for multiple providers (Linux only) |
| `oh-my-posh` | Prompt theme engine for any shell |
| `otel-tui` | Terminal OpenTelemetry viewer |
| `pipelock` | Agent egress firewall: forward proxy with hostname, SSRF and DLP checks |
| `pnpm_10` | Fast, disk-space-efficient JavaScript package manager (10.x) |
| `pnpm_11` | Fast, disk-space-efficient JavaScript package manager (11.x) |
| `pnpm_12` | Fast, disk-space-efficient JavaScript package manager (12.x) |

```bash
nix build .#dns-root-hints
```

</details>

<details>
<summary><strong>AI CLIs</strong></summary>

<!-- prettier-ignore -->
| Package | Description |
|---------|-------------|
| `chatgpt-codex` | OpenAI Codex CLI |
| `claude-code` | Claude Code CLI |
| `copilot-cli` | GitHub Copilot CLI |
| `kimchi` | Kimchi CLI with optional external source-built workflows (ai.kimchi.extensions.workflows) |
| `kiro-cli` | Kiro CLI |
| `kiro-gateway` | Python proxy API for Kiro |
| `semble` | Local semantic and lexical code-search CLI |

</details>

<details>
<summary><strong>Content Packages</strong></summary>

<!-- prettier-ignore -->
| Package | Description |
|---------|-------------|
| `coding-standards` | Reusable coding standard fragments (DRY, conventional commits, etc.) |
| `delegate-routing-content` | Per-runtime model/effort sizing skills and a short routing rule |
| `stacked-workflows-content` | Skills, references, and skill-routing fragment |

Content packages are derivations with `passthru.fragments` for composable
instruction building.

</details>

## Feature Matrix

<!-- prettier-ignore -->
| Feature | Without Nix | Home-Manager | DevEnv |
|---------|-------------|--------------|--------|
| Delegate routing | Copy a generated runtime skill | `ai.programs.delegate-routing.enable` (Claude + Codex + Kimchi + Kiro) | Same; project-native paths |
| Stacked workflow skills | Copy skills/ | `ai.programs.stacked-workflows.enable` | `ai.programs.stacked-workflows.enable` |
| MCP server packages | Install manually | `nix build .#<server>` | `nix build .#<server>` |
| Unified MCP config | Manual native config | `ai.mcpServers.*` (all five CLIs) | `ai.mcpServers.*` (all five CLIs) |
| Typed MCP settings | N/A | Shared schema + native extensions | Shared schema + native extensions |
| MCP credentials | Manual env vars | `plain`, `file`, or `helper` | `plain`, `file`, or `helper` |
| Semble search integrations | Manual install | `ai.programs.semble` (Claude + Codex + Kiro) | Same; project-native paths |
| Git tool packages | Install manually | Overlay + `nix build` | Overlay + `nix build` |
| Git configuration | `git config` | `git.settings` + typed `git.{branchless,absorb,revise}.settings` → `programs.git.settings` | Same options; a repository-local include that wins key by key |
| GitLab CLI config | `glab config set` | `glab.*` | `glab.*` |
| GitLab CLI credentials | Manual env vars | `plain`, `file` or `helper` | `plain`, `file` or `helper` |
| Context and rules | Copy native files | `ai.{context,rules}` (runtime capability-gated) | Same; project-native paths. Files a repository commits (AGENTS.md, `.github/` instructions) and Kiro steering are read-only copies, not store links |
| Generated files | N/A | `ai.formatter`, `ai.guards.<name>`, and `ai.checks` (Nix-owned build-time files; formatters exclude supplied skill trees, checks include their generated entries; runtime-rendered files excluded) | Same; project-native static files included |
| Skills | Copy native directories | `ai.skills.*` (all five CLIs) | Same; project-native paths |
| Portable reasoning effort | Per-CLI config | `ai.settings.reasoningEffort` (Claude + Codex + Copilot + Kimchi) | Same; Copilot's lands in `.github/copilot/settings.json`, which only its interactive session reads, Kimchi's in its project harness settings (see below). Kiro has only per-model native effort |
| Semantic agents | Per-CLI config | `ai.agents.*` (Claude + Codex + Copilot + Kimchi + Kiro) | Same; project-native paths |
| Portable lifecycle hooks | Per-CLI config | `ai.hooks.*` (Claude + Codex) | Same, plus Kimchi's project `.kimchi/hooks.json` |
| LSP server config | Per-CLI config | `ai.lspServers.*` (Claude + Copilot + Kiro) | Copilot + Kiro; Claude has no project LSP route (warns); Codex has no native LSP registry |
| CLI process environment | Shell config | `ai.environmentVariables` (Codex + Copilot + Kimchi + Kiro) | Same; baked into each launcher wrapper, never the shell. Claude uses `ai.claude.native.settings.env` |
| Command shell | Per-CLI config or `$SHELL` | `ai.shell` / `ai.<cli>.shell` (Claude + Codex + Kiro) | Same; takes a package. Copilot and Kimchi are explicit exclusions |
| Fragment composition | N/A | `lib.ai.compose` | `lib.ai.compose` |

### Kimchi project delivery

| Pool                     | devenv delivery                        | Boundary                                                                                                                                                                                                                                                    |
| ------------------------ | -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Context                  | root `AGENTS.md`                       | Available without project trust; reader walks ancestors, but the wrapper remains root-only                                                                                                                                                                  |
| MCP servers              | `.kimchi/mcp.json`                     | Requires project trust and launch from the devenv root                                                                                                                                                                                                      |
| Kimchi settings          | `.kimchi/config.json`                  | Requires project trust and launch from the devenv root; an owner-only copy. `region` and `telemetry.enabled` reach Kimchi through the launcher environment instead                                                                                          |
| Skills                   | `.kimchi/skills`                       | Requires project trust; nearest ancestor wins, but the wrapper remains root-only                                                                                                                                                                            |
| Project harness settings | `.config/kimchi/harness/settings.json` | Requires project trust and launch from the devenv root; user-scope-only keys are rejected during evaluation. `ai.settings.reasoningEffort` lands here as `defaultThinkingLevel`, so setting it alone creates the file                                       |
| Agents                   | `.kimchi/agents/<name>.md`             | Requires project trust and launch from the devenv root; Kimchi's /agents commands cannot edit a declared agent                                                                                                                                              |
| Permissions              | `.kimchi/permissions.json`             | Requires project trust and launch from the devenv root                                                                                                                                                                                                      |
| Hooks                    | `.kimchi/hooks.json`                   | Requires project trust and launch from the devenv root; PermissionRequest is not a Kimchi event and is left out. Home Manager has no user-scope hook file it can own, so shared `ai.hooks` do not reach Kimchi there (silently) and `ai.kimchi.hooks` warns |

devenv rejects Kimchi's user-scope-only harness settings: `defaultProjectTrust`,
`fermentV2`, `hidePhaseChanges`, `httpProxy`, `lastTerminalWarnings`,
`modelMetadata`, `modelRoles`, `multiModel`, `resources`,
`shellProfileApiKeyMigrationDismissed`, `statusLine`. Set those with Home
Manager or through Kimchi itself. Every project file is a read-only copy,
written only when something is declared; an in-app change Kimchi renames over
one is backed up and replaced at the next shell entry.

Kimchi's user-global files live under `~/.config/kimchi`, which devenv never
writes. Who manages each setting there depends on whether you use Home Manager:

| User-global setting                                    | Home Manager                                                                                                                                                                         | devenv only                                                     |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| Harness `settings.json`                                | Nix owns the keys it declares inside Kimchi's own file; `/model` and other in-app writes persist                                                                                     | Kimchi                                                          |
| `mcp.json`, `permissions.json`                         | Nix, as read-only copies; in-app changes are reset at the next activation                                                                                                            | Kimchi                                                          |
| Project trust (`harness/trust.json`)                   | Nix (`ai.kimchi.projectTrust`); `defaultProjectTrust = "never"`, and `/trust` cannot persist (it may exit)                                                                           | Kimchi's trust prompt                                           |
| `telemetry.enabled`, `region`                          | Nix; telemetry defaults off, region must be declared, and Kimchi reads both from global `config.json`                                                                                | Kimchi, unless declared: then the launcher passes the Nix value |
| `skillPaths`                                           | Nix; default skill paths include the ai.* directory                                                                                                                                  | Kimchi                                                          |
| API key                                                | Nix when `ai.kimchi.apiKey` is set (read from its secret at launch, so an in-app login has no effect); otherwise `/login`, which persists in `config.json` beside the Nix-owned keys | Same as Home Manager                                            |
| Git tokens                                             | Nix for each host in `ai.kimchi.gitTokens` (read from secrets at activation), which makes `config.json` a read-only copy again, so `/login` stops persisting; Kimchi for the rest    | Kimchi                                                          |
| `config.json` migration, onboarding and survey markers | Kimchi; they persist beside the Nix-owned keys                                                                                                                                       | Kimchi                                                          |
| Device id                                              | Kimchi; none is written while telemetry is off                                                                                                                                       | Kimchi                                                          |

Project settings, MCP servers, harness settings, permissions, agents, and hooks
resolve under the exact working directory. The devenv wrapper rejects descendant
launches instead of silently missing them. Context and skills walk ancestors, so
a devenv that declares none of the exact-cwd files leaves the launch directory
unrestricted. `skillPaths` defaults to unset: Kimchi reads the project list in
place of the user's global one, so only an explicit list, empty included,
replaces it.

Trust gates every project-scope reader except root `AGENTS.md`. On a Home
Manager machine, declare the root or a parent in `ai.kimchi.projectTrust` before
a devenv project's Kimchi config is read. Without Home Manager, grant trust at
Kimchi's prompt; `--approve` is a run-scoped CLI/TUI override, while ACP
resolves trust separately.

### Copilot user-global settings

Copilot's user-global files live under `~/.copilot`, which devenv never writes.
Who manages each one depends on whether you use Home Manager:

| User-global setting                                                            | Home Manager                                                                                                                                                         | devenv only            |
| ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| `settings.json`, `mcp-config.json`, `lsp-config.json`                          | Nix, as read-only copies (empty when nothing is declared); in-app changes such as `/model` or `copilot mcp add` are reset at the next activation                     | Copilot                |
| Trusted folders (`trustedFolders` in `config.json`)                            | Nix (`ai.copilot.trustedFolders`, absolute paths; a folder covers its subfolders); a folder trusted at Copilot's prompt stays trusted only until the next activation | Copilot's trust prompt |
| Sign-in, tokens, session and acknowledgement state (the rest of `config.json`) | Copilot                                                                                                                                                              | Copilot                |

devenv writes the repository `.github/copilot/settings.json` as a read-only copy
only when `ai.copilot.native.settings` declares something, and rejects
`ai.copilot.trustedFolders`. Copilot reads that repository file only in a
trusted folder: with Home Manager, add the clone (or a parent folder) to
`ai.copilot.trustedFolders`; without it, trust the project at Copilot's prompt.

## Configuration

<details>
<summary><strong>Unified ai.* Module</strong></summary>

Single source of truth for shared config across Claude, Codex, Copilot, Kimchi,
and Kiro. Only semantics a runtime can preserve fan out; the feature matrix
above names deliberate exclusions. Scalar defaults use `mkDefault` priority, so
per-CLI overrides always win.

```nix
ai = {
  claude.enable = true;
  codex.enable = true;
  copilot.enable = true;
  kimchi.enable = true;
  kiro.enable = true;

  skills.my-skill = ./skills/my-skill;

  rules.standards = {
    text = "Use strict mode everywhere";
    matcher = ["src/**"];
    description = "Project standards";
  };

  lspServers.nixd = {
    package = pkgs.nixd;
    extensions = ["nix"];
  };

  settings.reasoningEffort = "high";

  # Runtime-native escape hatch: model identifiers are not portable.
  codex.native.settings.model = "gpt-5.6-sol";
};
```

A scoped rule can also name the documents that hold its text in `references`.
Runtimes with path scoping ignore them; Codex, which reads one flat `AGENTS.md`,
lists such a rule in a compact path-scoped index (globs plus links) instead of
inlining its body into every turn.

Enabling any harness also installs a sandbox-safe Git SSH default. It preserves
Home Manager's `~/.ssh/config` host/key routing when a Linux user-namespace
sandbox remaps the Nix-store target's owner; devenv exports the same wrapper as
`GIT_SSH_COMMAND`, so ordinary dev-shell Git and harness-launched Git behave the
same. OpenSSH batch mode makes missing credentials fail instead of opening a
password dialog. Set `ai.gitSshConfigWorkaround = false` to manage this
yourself.

Codex supports either the legacy `sandbox_mode` model or named permissions
through `ai.codex.native.settings.default_permissions` and
`ai.codex.native.settings.permissions`. Do not mix those models in any loaded
config layer. Same-named permission tables merge across user and project files.
The distinct `ai.codex.profiles` option, which would have materialized whole
extra files selected with `codex --profile`, was removed as unreachable;
per-agent visibility belongs to the sandbox-stack work instead.

With legacy `workspace-write`, the module automatically adds the Nix cache and,
under devenv, the current repository's `.git`. With a selected custom permission
profile, integration-owned roots become direct filesystem writes in that
profile. Integration modules add their own state only when enabled: Semble adds
its cache and glab adds its effective `configDir`. Explicit rules in the same
emitted layer win at identical paths. A parent containing multiple worktrees
remains an explicit consumer root.

> **Kiro steering-copy upgrade:** when upgrading from a release that
> materialized steering as real copies, keep the previous `ai.kiro.configDir`
> for one Home Manager activation or devenv shell entry. The manifest-guarded
> retirement runs even when `ai.kiro.enable = false`. If a custom `configDir`
> must change or be removed, perform that retirement generation first, then
> change the directory; the legacy manifest records owned filenames and hashes,
> but not an invertible target path, so a later generation cannot safely infer
> the old custom directory.

</details>

<details>
<summary><strong>Generated-file formatting</strong></summary>

Every live, Nix-owned whole file whose bytes exist at build time is built into
one store tree per delivery-router invocation. The flake's exported
`treefmtModules.default` is always the base; the consumer's `ai.formatter`
treefmt-nix module is layered on top. One treefmt run formats every composed
file, including Markdown headers. Each formatted path must use the conventional
extension for its declared format (`.json`, `.md`, `.toml`, `.yaml`, or `.yml`).
An unmatched composed file fails the build and names its target-relative path.
Raw files and recursive directory sources are copied byte-identically and never
passed to treefmt. A failed formatter or check fails the build.

On devenv, every delivered path is automatically excluded from the repository's
own treefmt run. Other module consumers can use the read-only
`ai.deliveredPaths` list for the same purpose.

Generated-file checks form a three-tier default chain, all with `types.lines`:
`ai.checks.all`, `ai.checks.<surface>`, then `ai.<runtime>.checks.<surface>`.
The seven surfaces are `agents`, `context`, `hooks`, `mcpServers`, `rules`,
`settings`, and `skills`. Only the resolved runtime-and-surface leaf runs;
shared internal documents run the root surface tier with `AI_RUNTIME=internal`.
Defining a lower tier replaces its inherited default; splice
`${config.ai.checks.all}` or the surface tier into a lower definition when
composition is wanted. There is no per-runtime `all` tier.

A non-empty snippet runs once for each surface represented in the built runtime
tree, with the tree root as its working directory, that surface's
target-relative paths in `"$@"`, and `AI_RUNTIME` exported to the runtime name.
Empty snippets and surfaces with no files do not run. Checks see only build-time
whole files. Generated raw skill entries participate even though formatters skip
their bytes; runtime-rendered files, shared reconciled documents, and unstamped
raw `ai.<runtime>.files` entries do not. Checks run in the Nix build sandbox, so
only store-provided tools are available and network access is unavailable.

```nix
ai.checks = {
  all = "test -n \"$AI_RUNTIME\"";
  rules = config.ai.checks.all + "\n${pkgs.ai.devTools.markdownlint-cli2}/bin/markdownlint-cli2 \"$@\"";
};
```

Supply a treefmt-nix module to customize generated-file formatting:

```nix
ai.formatter = ./treefmt.nix;
```

Generated context, rules, AGENTS.md and agent Markdown participate on both Home
Manager and devenv, including Claude's direct Home Manager files. Static JSON,
TOML and YAML entries participate when their file entry names the corresponding
`format`; raw files and supplied directory trees participate without a
formatter. Switch-time overlays and private documents rendered by `content.run`
are excluded because their final bytes do not exist at build time. Shared
document entries are excluded because they own reconciled leaves rather than a
whole file.

| Runtime | Static JSON/TOML/YAML in scope                                                                                  | Outside the build tree                             |
| ------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Claude  | `settings.json` on both backends; devenv `.mcp.json`; Home Manager plugin `.mcp.json`, `.lsp.json` and manifest | `.claude.json` shared mutable state                |
| Codex   | Agent TOML files, `hooks.json`, both `config.toml` locations, Home Manager daemon settings                      | Runtime-rendered files                             |
| Copilot | Home Manager `lsp-config.json`; devenv `.github/lsp.json`; `mcp-config.json`; both `settings.json` locations    | Home Manager `config.json` shared trust and state  |
| Kimchi  | Static config, harness settings, MCP, permissions and devenv hooks                                              | `trust.json` and credential-rendered `config.json` |
| Kiro    | `cli.json`, `lsp.json`, Home Manager `permissions.yaml`, agent and hook JSON files                              | Runtime-rendered `mcp.json`                        |

A single file can opt out of formatting and guards with
`ai.<runtime>.files."<path>".format = "raw"`; it remains in the store tree. Byte
limits still apply to opted-out paths. A `content.run` replacement of a
generated entry requires `format = "raw"`; replacing an entire AGENTS.md entry
may state `format = "markdown"` to retain formatting.

`mkAgenticShell` generates no files in this delivery router, so it has no
corresponding option.

</details>

### `ai.guards`

Guards check semantic and structural properties independently of the selected
formatter and of `ai.checks`. They use this flake's pinned tools. Each guard can
be disabled by name. `splitCodeSpans` and `tableCells` default to enabled only
when the mounted `ai.formatter` enables Prettier; the other guards default to
enabled.

| Guard                 | What it catches                                                                                          | Disable                                  |
| --------------------- | -------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| `kiroFrontmatterFlow` | Multi-line YAML flow sequences in Markdown frontmatter after formatting; Kiro only                       | `ai.guards.kiroFrontmatterFlow = false;` |
| `parseCompare`        | Invalid or changed JSON, TOML or YAML data; changed parsed Markdown frontmatter values, after formatting | `ai.guards.parseCompare = false;`        |
| `splitCodeSpans`      | A newline inside a Markdown inline code span in the input, before formatting                             | `ai.guards.splitCodeSpans = false;`      |
| `tableCells`          | Inconsistent input Markdown table cells before formatting; rumdl and markdownlint catch different forms  | `ai.guards.tableCells = false;`          |

The builder formats whole Markdown files, including their YAML headers.
`parseCompare` compares parsed frontmatter values, allowing presentation changes
such as re-quoting while rejecting changed data. Files without frontmatter
compare as `null`. JSON, TOML and YAML also compare parsed values.

For example, these formatter outcomes differ:

| Example                                                   | Guard result | Reason                                                       |
| --------------------------------------------------------- | ------------ | ------------------------------------------------------------ |
| Default Biome JSON and Taplo TOML                         | Good         | They change presentation while preserving parsed values      |
| Default Prettier Markdown and YAML                        | Good         | Whole files are formatted while parsed values stay unchanged |
| A formatter that changes JSON `true` to `false`           | Bad          | `parseCompare` detects changed data                          |
| Input with an unescaped pipe inside a Markdown table cell | Bad          | `tableCells` detects an extra input cell                     |

A format guard error names what failed and why, then gives three choices: fix
the input or formatter; disable that named guard if its invariant is unsuitable;
or set the specific file's `format = "raw"` to opt out explicitly. The Kiro
shape guard offers only fix or disable because a runtime still reads a raw file.

#### Using the guards on your own files

The same guards are exported as `lib.ai.guards pkgs` for files you author.
`pkgs` must include this flake's overlay for rumdl and markdownlint-cli2.
`tableCells` reports MD056 only. Configuration files in the checked tree cannot
change it; inline lint suppression comments still apply.

| Attribute             | Program                                                                                                                                       | Arguments                                                                 |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `kiroFrontmatterFlow` | `ai-guard-kiro-frontmatter-flow`                                                                                                              | Markdown file paths                                                       |
| `parseCompare`        | `ai-guard-parse-compare`                                                                                                                      | `TYPE BEFORE AFTER`, where `TYPE` is `json`, `markdown`, `toml` or `yaml` |
| `splitCodeSpans`      | `ai-guard-split-code-spans`                                                                                                                   | Markdown file paths                                                       |
| `tableCells`          | `ai-guard-table-cells`                                                                                                                        | Markdown file paths                                                       |
| `check`               | Markdown shape guards in one derivation; `kiroFrontmatterFlow` is on by default for files under `<kiroDir>/steering/` and `<kiroDir>/agents/` | `{ src; guards ? {}; kiroDir ? ".kiro"; }`                                |

`check` is a build-time gate for `nix flake check` or CI. It returns a
derivation that runs `splitCodeSpans` and `tableCells` over every `*.md` under
`src` and fails the build on a finding. `kiroFrontmatterFlow` is on by default
for Markdown in `<kiroDir>/steering/` recursively and directly in
`<kiroDir>/agents/`, wherever that layout occurs under `src`. `kiroDir` defaults
to `.kiro`; an empty Kiro selection passes. It checks the store copy of `src`,
not the files you staged, so it is not a pre-commit hook:

```nix
checks.${system}.markdown-guards =
  (inputs.nix-agentic-tools.lib.ai.guards pkgs).check {
    src = ./docs;
    # kiroDir = "custom"; # select a custom Kiro layout
    # guards.tableCells = false; # disable a guard by name
  };
```

For a pre-commit hook, add the programs to your shell's packages and call them
on the staged paths:

```bash
git diff --cached --name-only -z --diff-filter=d -- '*.md' \
  | xargs -0 -r sh -c 'ai-guard-kiro-frontmatter-flow "$@" && ai-guard-split-code-spans "$@" && ai-guard-table-cells "$@"' _
```

`check` does not run `parseCompare`, because it needs two versions of the same
file and a source tree holds one. Call it in a hook after your formatter
rewrites a file: pass the staged version and the formatted result. JSON, TOML
and YAML compare parsed values. Markdown compares parsed YAML frontmatter
values, allowing the formatter to re-present the header. A file without
frontmatter has the value `null`. Fenced frontmatter must close and hold valid
YAML between the fences. If BEFORE does not parse, nothing is compared and the
program exits 2. If AFTER does not parse, that is a finding. In a bash hook, a
process substitution passes the staged version:

```bash
ai-guard-parse-compare yaml <(git show :config.yaml) config.yaml
```

A finding exits 1 and names what failed and why. The format guards offer three
options, worded for your files: fix the file or formatter; disable the guard by
name in `check`, or stop running its program; or leave the file out of the
guarded set. `kiroFrontmatterFlow` offers only fix or disable because Kiro still
reads a raw file. Exit 2 means nothing was checked, for example an unreadable
file.

<details>
<summary><strong>Semble code search</strong></summary>

Semble never enables AI runtimes implicitly. The program switch enables its
package and MCP server; CLI guidance and the `semble-search` subagent are
independent opt-ins. Separately enable whichever runtimes should consume the
generated configuration:

```nix
ai.programs.semble.enable = true;

ai.claude.enable = true;
ai.codex.enable = true;
ai.kiro.enable = true;
```

Portable defaults live at `ai.programs.semble`. Each supported runtime has the
same nullable option tree under `ai.<runtime>.programs.semble`: null inherits
the root value and a non-null value wins. Program-level enable overrides replace
runtime lists:

```nix
ai = {
  programs.semble = {
    enable = true;
    cli.instructions.enable = true;
    defaultContent = ["code" "docs"];
    subagent = {
      enable = true;
      interface = "mcp";
    };
  };

  claude.programs.semble.enable = false;
  codex.programs.semble.subagent.enable = true;
  kiro.programs.semble.mcp.enable = false;
};
```

Claude writes the guidance as the always-on rule file `.claude/rules/semble.md`,
and Codex inlines it in `AGENTS.md`. Kiro writes it to
`.kiro/steering/semble.md` under Home Manager and, under devenv, where it shares
the repository `AGENTS.md`, inlines it there.
`ai.programs.semble.install = false` keeps every rule but skips installing the
package, for a shell that must not carry it.

`models` routes searches across embedding models by content: a search uses the
entry whose content set equals its `--content` (or `defaultContent`) exactly,
and `defaultModel` otherwise. The CLI and the MCP server route the same way, and
the generated guidance tells agents which content has which model. Each model is
a pinned package such as a `lib.packaging.fetchHuggingFaceModel` output:

```nix
ai.programs.semble = {
  models = [
    {
      model = let
        files = ["config.json" "model.safetensors" "modules.json" "tokenizer.json"];
      in
        inputs.nix-agentic-tools.lib.packaging.fetchHuggingFaceModel {
          inherit pkgs files;
          repoId = "minishlab/potion-base-32M";
          rev = "1e5a03f8eeb2c98b928fbbd846f22f816360919f";
          hash = "sha256-d9bGAm1XdYCwF63uODq5eD5Ow7utLaoxaxCYtVrqMTU=";
          license = lib.licenses.mit;
          # Lets evaluation check the files against model2vec's layouts.
          passthru = {inherit files;};
        };
      content = "docs";
      description = "Prose: READMEs, design notes, architecture docs.";
    }
  ];
  # Files Semble cannot place by suffix. The first matching entry wins.
  pathMappings = [
    {
      language = "json";
      content = "docs";
      patterns = ["docs/*.json"];
    }
    {
      language = "json";
      content = "config";
      patterns = ["*.json" "flake.lock"];
    }
  ];
};
```

With `mcp.enable = false` and an MCP-backed subagent, Kiro keeps the Semble
server inside the agent file and out of the root MCP pool. Claude and Codex
cannot scope a server to one agent, so they fail evaluation instead of silently
exposing it.

Home Manager fixes the cache at its owned XDG location. A devenv integration
relocates it to a project-local state directory and tells Semble where by baking
`SEMBLE_CACHE_LOCATION` into the launcher wrapper — never into the project
shell's environment. The relocation is unconditional on devenv; only the Codex
writable-root grant is conditional, on a selected feature targeting Codex in
`workspace-write` mode. The module does not select the sandbox mode itself.

Direct configuration remains available when the convenience feature is disabled:

```nix
ai.codex = {
  mcpServers.semble =
    inputs.nix-agentic-tools.lib.ai.mcpServers.mkSemble {
      inherit lib pkgs;
    } {
      content = "docs";
    };
  agents.semble-search =
    inputs.nix-agentic-tools.lib.ai.semble.semanticAgent;
  rules.semble = inputs.nix-agentic-tools.lib.ai.semble.rule;
};

ai.kiro = {
  native.agents.semble-search =
    inputs.nix-agentic-tools.lib.ai.semble.kiroAgent;
  rules.semble = inputs.nix-agentic-tools.lib.ai.semble.rule;
};
```

Semble does not declare `ai.copilot.programs.semble`; configure Copilot directly
through `ai.copilot.*` with the same exported helpers when desired.

</details>

<details>
<summary><strong>Codex config ownership</strong></summary>

Settings are Nix's alone. Both backends deliver `config.toml` as a read-only
store symlink: Home Manager always owns the user file under
`ai.codex.configDir`, and devenv writes the trusted project's
`.codex/config.toml` when something is declared. Codex refuses to save an in-app
change into it (`/model`, `/experimental` and `codex mcp add` fail with "failed
to persist config"), so declare those settings under `ai.codex.native.settings`.

Project trust lives in that file too. With Home Manager, declare each clone you
trust:

```nix
ai.codex.native.settings.projects."/home/me/src/my-repo".trust_level = "trusted";
```

Codex matches the working directory or its repository root exactly, and resolves
a linked worktree to its main checkout, so one entry covers a clone and its
worktrees. In a directory with no entry the trust prompt cannot save its answer,
so the interactive session can only quit there; `codex exec` is unaffected.
Devenv rejects `projects` because project config cannot grant the trust required
to load itself.

Codex runs a hook only once its current hash is trusted, and `/hooks` cannot
record trust into a Nix-owned file. Nix declares the trust of every hook it
generates: Home Manager in user `config.toml`, devenv through its launcher.
Declare trust for any other hook, such as a plugin's, in
`ai.codex.native.settings.hooks.state` with Home Manager.

Codex's user-global files live under `~/.codex`, which devenv never writes. Who
manages each setting there depends on whether you use Home Manager:

| User-global setting                                               | Home Manager                                                                                                  | devenv only                                                                                |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `config.toml`: model, features, MCP servers, preferences          | Nix, as a read-only store symlink; in-app saves fail                                                          | Codex                                                                                      |
| Project trust (`projects` in `config.toml`)                       | Nix (`ai.codex.native.settings.projects`)                                                                     | Codex's trust prompt                                                                       |
| Hook trust (`hooks.state` in `config.toml`)                       | Nix for the hooks it generates; `ai.codex.native.settings.hooks.state` for others                             | Codex's `/hooks`, except for the project hooks devenv generates, which its launcher trusts |
| Daemon settings (`app-server-daemon/settings.json`)               | Nix (`ai.codex.native.daemonSettings`), as a read-only copy; an in-app change is reset at the next activation | Codex; devenv runs Codex without the daemon                                                |
| Daemon package selection                                          | Nix (`ai.codex.pinDaemonToPackage`)                                                                           | Codex's own updater                                                                        |
| Saved command approvals (`rules/default.rules`), sign-in, history | Codex                                                                                                         | Codex                                                                                      |

Upgrading from a release that reconciled `config.toml`: before the first switch,
move the real `~/.codex/config.toml` aside, along with any `config.toml.hm-bak`
beside it, and declare your trusted clones. Home Manager refuses to replace a
real file with its link, and with `backupFileExtension` set an existing backup
blocks it too.

Native-only settings remain under `ai.codex.native.settings`. Normalized
settings live under `ai.codex.settings` and narrow `ai.settings` field by field.
The named whole-file `ai.codex.profiles` layer was removed as unreachable — see
the sandbox section above for why. Native Starlark command policy uses
`ai.codex.execpolicyRules` rather than Markdown `ai.rules`.

Codex 0.157+ runs tool calls in a shared background daemon, which runs whatever
package `~/.codex/packages/app-server-daemon/current` selects and otherwise
updates itself from GitHub every hour. Home Manager points that selection at
`ai.codex.package`, turns the updater off, and stops the daemon after a switch
that changes the package; `ai.codex.pinDaemonToPackage = false` hands it back to
upstream. Upstream's copy of this package carries patched voice and zsh
resources that point into store paths no GC root holds, so they break after
garbage collection until its updater replaces the copy. Home Manager also
defaults `features.daemon_auto_start` to false, because a daemon keeps the
environment of whichever session started it. Devenv runs Codex with
`--no-daemon`, so project sessions use the project shell and the project's Codex
version. `ai.codex.pinDaemonToPackage` is Home Manager-only and has no devenv
counterpart at all; devenv rejects `features.daemon_auto_start = true`, which
would do nothing there.

</details>

<details>
<summary><strong>Claude Delegation-Clamp Mitigation (off by default)</strong></summary>

Claude Code injects a system-prompt section telling the model not to use
subagents, workflows, or deep research "unless the user requested it". It is
gated on a **model capability**, not on your configuration — on for Opus 5 — and
no setting, flag, or environment variable turns it off. It never appears in the
transcript, so a session with delegation silently suppressed looks identical to
a normal one. It also directly contradicts `ai.claude.ultracodeOnLaunch`, which
asks for the opposite.

Opting in installs a mitigation that patches nothing: a `UserPromptSubmit` hook
supplies the request that the clamp's own escape clause is asking for, as
user-side context. It is injected once per session and re-armed by a
`PreCompact` hook, so the cost is roughly 75 tokens per session rather than per
turn.

```nix
ai.claude.delegationClampMitigation = {
  enable = true;          # off by default; set true to enable
  text = "…";             # the standing request — wording is load-bearing
};
```

Upstream:
[anthropics/claude-code#80988](https://github.com/anthropics/claude-code/issues/80988).
A dated CI step re-surfaces this roughly every 90 days, once
`config/heron-brook-tripwire.json`'s `reviewBy` passes, so the mitigation does
not outlive its cause. See `packages/claude-code/docs/heron-brook-clamp.md`.

</details>

<details>
<summary><strong>Claude Memory-Collision Guard (off by default)</strong></summary>

Concurrent Claude Code sessions share one agent-memory directory and neither
sees the other's writes — no locking, no notification. A session reads the
memory index once at start, then writes into a directory that may have moved
underneath it. The failure is silent: a duplicate saved under a _different_
filename raises no conflict, it just stops being findable, because the wikilink
graph resolves by name.

A `PreToolUse` hook on `Write|Edit`, scoped to memory directories, pauses the
first write to each file per session and hands the model that directory's
recently-modified neighbours — filename, mtime, and `description:` frontmatter,
with anything written in the last few minutes flagged as a live concurrent
session. The model decides whether to extend an existing file or proceed;
re-issuing the same write goes through.

```nix
ai.claude.memoryCollisionGuard = {
  enable = true;          # default false
  windowMinutes = 10;     # mtime window counted as "a session is active now"
  listCount = 10;         # neighbours to show, most recent first
  extraDirectories = [];  # stores outside <claude config>/projects/*/memory/
};
```

Off by default because it **blocks a tool call** and its cadence is an untuned
judgement call, not a measured one. The alternative instrumentation — allow the
write and inject the listing as `additionalContext`, reactive rather than
blocking — is documented alongside the chosen one in
`packages/claude-code/lib/memory-collision-guard.sh`, so revisiting the
trade-off does not mean re-deriving it.

</details>

<details>
<summary><strong>MCP Servers (Home-Manager)</strong></summary>

```nix
services.mcp-servers.servers = {
  github-mcp = {
    enable = true;
    settings.credentials.file = config.sops.secrets.github-token.path;
  };
  nixos-mcp.enable = true;
  context7-mcp.enable = true;
};
```

</details>

<details>
<summary><strong>Delegate Routing</strong></summary>

```nix
ai.programs.delegate-routing.enable = true;
ai.claude.programs.delegate-routing = {
  extraRuntimes = ["codex"];
  manualExternalDelegates = ["kiro"];
  roles.default = {effort = "medium"; use = "strong";};
};
```

Portable `families.<vendor>.<family>` records describe tiers, task and effort
guidance, and live-model patterns. Override any field or add a family. Each
runtime's `models` is a list of selectors over `vendors`, `tiers` and
`families`: selectors are alternatives, and every non-empty field in one
selector must match. Selector enums come from configured families; tier
selectors accept only tiers used by those families. Claude defaults to Anthropic
and Codex to OpenAI. Kimchi and Kiro require an explicit selection when their
runtime and delegate-routing program are enabled. The package ships no families
for Kimchi-served vendors; declare them under `families` before selecting them.

Enable each auto-selectable external runtime with `ai.<runtime>.enable`.
Manual-only entries require an explicit user request and do not require runtime
enable. If Kiro is enabled only for manual delegation, disable its own
delegate-routing program with
`ai.kiro.programs.delegate-routing.enable = false`. Copilot is excluded because
its delegation controls are unestablished.

Runtime `roles.default`, `roles.writer` and `roles.reviewer` optionally select a
tier or a family, with effort `low`, `medium`, `high`, `xhigh` or `max`. All
roles default to null. `use` takes a static tier or a family that this runtime
or an automatic extra selects. Family names must be unique across vendors and
cannot equal tiers. The default role sets the starting tier. The default role's
tier is the ceiling; a family resolves to its own tier. Writer and reviewer
effort inherits the default when unset. Explicit writer and reviewer choices may
exceed that default ceiling. Manual-only families are ineligible.

Runtime `techniques` describe workflows, subagents, external launches, model
introspection and usage. Override a node's fields or disable it with
`enable = false`. Pick the highest-version model matching a family's pattern
from the live runtime list, using its own spelling. Portable `rules` and
`procedure` accept replacement `text` or `source`, or `enable = false`. Both
Home Manager and devenv expose the same options.

</details>

<details>
<summary><strong>Stacked Workflows</strong></summary>

```nix
ai.programs.stacked-workflows.enable = true;

# mkDefault values on the git.* options (see Git Tools): Home Manager
# applies them user-global, devenv repository-local.
stacked-workflows.gitPreset = "full"; # or "minimal" or "none"

# Optional runtime override: null inherits, false disables one runtime.
ai.codex.programs.stacked-workflows.enable = false;
```

See the `stacked-workflows` package for git presets and skill details.

</details>

## License

Released under the [Unlicense](LICENSE).
