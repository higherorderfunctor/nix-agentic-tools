# nix-agentic-tools

Stacked commit workflows, MCP servers, and declarative configuration for AI
coding CLIs (Claude Code, Codex, Copilot, Kiro). Works without Nix; Nix unlocks
overlays, home-manager modules, and devshell integration.

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
  # Do NOT add `inputs.nixpkgs.follows = "nixpkgs"` here. See the
  # warning below — it costs you the binary cache and can break builds.
};

# Apply overlay
nixpkgs.overlays = [inputs.nix-agentic-tools.overlays.default];

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
  programs.stacked-workflows.enable = true;
  settings.reasoningEffort = "high";
};

# Home Manager-only companion; the program enable above is shared with
# devenv and supports per-runtime overrides.
stacked-workflows.gitPreset = "full";

services.mcp-servers.servers.github-mcp = {
  enable = true;
  settings.credentials.file = "/run/secrets/github-token";
};
```

> **Static runtime files:** every runtime exposes
> `ai.<runtime>.files."<relative-path>" = { text = "…"; };` (or
> `source = ./file`). Generated context/rule outputs use the same final map at
> default priority, so an ordinary whole entry replaces them and `null`
> suppresses them. Paths are relative to HOME here and to the project under
> devenv.

</details>

<details open>
<summary><strong>DevEnv (per-project dev shell)</strong></summary>

```yaml
# devenv.yaml
inputs:
  nix-agentic-tools:
    url: github:higherorderfunctor/nix-agentic-tools
    # Do NOT add a `nixpkgs: follows: nixpkgs` block here. See the
    # warning below — it costs you the binary cache and can break builds.
```

```nix
# devenv.nix
{inputs, ...}: {
  imports = [inputs.nix-agentic-tools.devenvModules.nix-agentic-tools];

  ai = {
    claude.enable = true;
    codex.enable = true;
  };

  claude.code = {
    mcpServers.github-mcp = {
      type = "stdio";
      command = "github-mcp-server";
      args = ["--stdio"];
    };
  };
}
```

</details>

### Do not make this flake follow your nixpkgs

> **`inputs.nix-agentic-tools.inputs.nixpkgs.follows = "nixpkgs"` is not
> supported.** It is the one configuration that defeats everything below.

Every compiled package here instantiates its build inputs from **this repo's own
nixpkgs pin**, never from the consumer's package set. That is the only reason
`nix-agentic-tools.cachix.org` can serve you: CI builds against that pin, so the
store paths you ask for are the ones that were published.

A `follows` directive rewrites this flake's `nixpkgs` input at lock time, before
any of its code evaluates — so those build inputs silently become **yours**. Two
consequences, and the second is the one that surprises people:

1. **You lose the binary cache entirely.** Every package rebuilds from source on
   every consumer rebuild, because the paths you now request were never built by
   anyone.
2. **Builds can fail outright**, not merely rebuild, when a pin older than ours
   cannot satisfy what a package's upstream requires. This is not hypothetical:
   until the Go toolchain floor landed, a followed nixpkgs from April 2026 (Go
   1.26.2) could not build `glab` or `gh`, both of which need Go >= 1.26.5.
   Those two now select a newer toolchain and build — but that guarantee is
   per-mechanism, not general. Nothing makes the next dependency of that shape
   safe.

The cost of not following is two nixpkgs evaluations in your store. Most of the
closure dedupes via content-addressing, and cache hits are only reachable this
way. If you have already added the `follows`, remove it — that is the fix.

## Skills

Stacked commit workflow skills using git-branchless, git-absorb, and git-revise.

<!-- prettier-ignore -->
| Skill | Description |
|-------|-------------|
| `/stack-fix` | Absorb fixes into correct stack commits |
| `/stack-plan` | Plan and build a commit stack from description or existing commits |
| `/stack-split` | Split a large commit into reviewable atomic commits |
| `/stack-submit` | Sync, validate, push stack, and create stacked PRs |
| `/stack-summary` | Analyze stack quality, flag violations, produce planner-ready summary |
| `/stack-test` | Run tests or formatters across every commit in a stack |

## Packages

<details>
<summary><strong>MCP Servers</strong> (17 servers)</summary>

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
| `openmemory-mcp` | Persistent memory + vector search | None |
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
| `oxlint` | Fast JS/TS linter with type-aware (tsgo) linting and JS plugins |
| `tsgolint` | Type-aware linting backend for oxlint (typescript-go) |

```bash
nix build .#oxlint
```

</details>

<details>
<summary><strong>Generic Packages</strong></summary>

Temporarily unclassified supporting packages live in the split-ready
`overlays/generic/` subtree and are exposed as `pkgs.ai.generic.*`.

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
| `pnpm_10` | Fast, disk-space-efficient JavaScript package manager (10.x) |
| `pnpm_11` | Fast, disk-space-efficient JavaScript package manager (11.x) |

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
| `github-copilot-cli` | GitHub Copilot CLI |
| `kimchi` | Kimchi CLI |
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
| `stacked-workflows-content` | Skills, references, and skill-routing fragment |

Content packages are derivations with `passthru.fragments` for composable
instruction building.

</details>

## Feature Matrix

<!-- prettier-ignore -->
| Feature | Without Nix | Home-Manager | DevEnv |
|---------|-------------|--------------|--------|
| Stacked workflow skills | Copy skills/ | `ai.programs.stacked-workflows.enable` | `ai.programs.stacked-workflows.enable` |
| MCP server packages | Install manually | `nix build .#<server>` | `nix build .#<server>` |
| Unified MCP config | Manual native config | `ai.mcpServers.*` (all five CLIs) | `ai.mcpServers.*` (all five CLIs) |
| Typed MCP settings | N/A | Shared schema + native extensions | Shared schema + native extensions |
| MCP credentials | Manual env vars | `plain`, `file`, or `helper` | `plain`, `file`, or `helper` |
| Semble search integrations | Manual install | `ai.programs.semble` (Claude + Codex + Kiro) | Same; project-native paths |
| Git tool packages | Install manually | Overlay + `nix build` | Overlay + `nix build` |
| GitLab CLI config | `glab config set` | `glab.*` | `glab.*` |
| GitLab CLI credentials | Manual env vars | `plain`, `file` or `helper` | `plain`, `file` or `helper` |
| Context and rules | Copy native files | `ai.{context,rules}` (runtime capability-gated) | Same; project-native paths |
| Skills | Copy native directories | `ai.skills.*` (all five CLIs) | Same; project-native paths |
| Portable reasoning effort | Per-CLI config | `ai.settings.reasoningEffort` (Claude + Codex) | Same |
| Semantic agents | Per-CLI config | `ai.agents.*` (Claude + Codex + Copilot) | Same; project-native paths |
| Portable lifecycle hooks | Per-CLI config | `ai.hooks.*` (Claude + Codex) | Same |
| LSP server config | Per-CLI config | `ai.lspServers.*` (Claude + Copilot + Kiro) | Same; Codex has no native LSP registry |
| CLI process environment | Shell config | `ai.environmentVariables` (Codex + Copilot + Kimchi + Kiro) | Same; baked into each launcher wrapper, never the shell. Claude uses `ai.claude.nativeSettings.env` |
| Command shell | Per-CLI config or `$SHELL` | `ai.shell` / `ai.<cli>.shell` (Claude + Codex + Kiro) | Same; takes a package. Copilot and Kimchi are explicit exclusions |
| Fragment composition | N/A | `lib.ai.compose` | `lib.ai.compose` |

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
  codex.nativeSettings.model = "gpt-5.6-sol";
};
```

Enabling any harness also installs a sandbox-safe Git SSH default. It preserves
Home Manager's `~/.ssh/config` host/key routing when a Linux user-namespace
sandbox remaps the Nix-store target's owner; devenv exports the same wrapper as
`GIT_SSH_COMMAND`, so ordinary dev-shell Git and harness-launched Git behave the
same. OpenSSH batch mode makes missing credentials fail instead of opening a
password dialog. Set `ai.gitSshConfigWorkaround = false` to manage this
yourself.

Codex supports either the legacy `sandbox_mode` model or named permissions
through `ai.codex.nativeSettings.default_permissions` and
`ai.codex.nativeSettings.permissions`. Do not mix those models in any loaded
config layer. Same-named permission tables merge across user and project files.
The distinct `ai.codex.profiles` option, which would materialize whole extra
files selected with `codex --profile`, remains locked out.

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
    instructions.cli.enable = true;
    mcp.content = ["code" "docs"];
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

Claude and Codex compose the guidance into their single always-loaded
`CLAUDE.md` and `AGENTS.md` files. Kiro writes its named instruction to
`.kiro/steering/semble.md`.

Set `mcp.rootExposure = false` only on Kiro, with an enabled MCP-backed Semble
subagent for that runtime. The server then remains in the agent file while being
omitted from the root MCP pool; unsupported runtimes fail evaluation instead of
silently exposing it.

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
  agents.semble-search =
    inputs.nix-agentic-tools.lib.ai.semble.kiroAgent;
  rules.semble = inputs.nix-agentic-tools.lib.ai.semble.rule;
};
```

Semble does not declare `ai.copilot.programs.semble`; configure Copilot directly
through `ai.copilot.*` with the same exported helpers when desired.

</details>

<details>
<summary><strong>Codex config ownership</strong></summary>

Codex writes ad-hoc project trust into its user `config.toml`. Home Manager
therefore keeps that file writable and reconciles only the exact TOML leaves
declared by Nix, preserving native state and removing formerly managed leaves on
later activations. It does **not** use a read-only store symlink.

Devenv owns `.codex/config.toml` statically because no project-local Codex
writer has been observed. User-global trust remains outside the project: trust
the repository once when Codex prompts, or declare
`ai.codex.nativeSettings.projects."<absolute-path>".trust_level` through Home
Manager. Devenv rejects that bootstrap-global setting because project config
cannot grant the trust required to load itself.

Native-only settings remain under `ai.codex.nativeSettings`. Normalized settings
live under `ai.codex.settings` and narrow `ai.settings` field by field. Named
whole-file layers (`ai.codex.profiles`) are typed and emit correctly in both
backends but are **locked out** — see the sandbox section above for why. Native
Starlark command policy uses `ai.codex.execpolicyRules` rather than Markdown
`ai.rules`.

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
ai.claude.delegationClamp = {
  mitigate = true;        # off by default; set true to enable
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
<summary><strong>Stacked Workflows</strong></summary>

```nix
ai.programs.stacked-workflows.enable = true;

# Home Manager-only companion; omit in devenv configurations.
stacked-workflows.gitPreset = "full"; # or "minimal" or "none"

# Optional runtime override: null inherits, false disables one runtime.
ai.codex.programs.stacked-workflows.enable = false;
```

See the `stacked-workflows` package for git presets and skill details.

</details>

## License

Released under the [Unlicense](LICENSE).
