# nix-agentic-tools

Stacked commit workflows, MCP servers, and declarative configuration for AI
coding CLIs (Claude Code, Copilot, Kiro). Works without Nix; Nix unlocks
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

# Kiro
cp -r packages/stacked-workflows/skills/stack-* .kiro/skills/

# GitHub Copilot
cp -r packages/stacked-workflows/skills/stack-* .github/skills/
```

Each skill is self-contained with a `SKILL.md` and bundled reference docs.

</details>

<details>
<summary><strong>Home-Manager (system-level declarative config)</strong></summary>

```nix
# flake.nix
inputs.nix-agentic-tools = {
  url = "github:higherorderfunctor/nix-agentic-tools";
  inputs.nixpkgs.follows = "nixpkgs";
};

# Apply overlay
nixpkgs.overlays = [inputs.nix-agentic-tools.overlays.default];

# Home-manager config
imports = [inputs.nix-agentic-tools.homeManagerModules.default];

ai = {
  claude.enable = true;
  copilot.enable = true;
  kiro.enable = true;
};

stacked-workflows = {
  enable = true;
  gitPreset = "full";
  integrations.claude.enable = true;
};

services.mcp-servers.servers.github-mcp = {
  enable = true;
  settings.credentials.file = "/run/secrets/github-token";
};
```

> **Note (Kiro steering uninstall):** Kiro steering files are materialized as
> read-only real files (the Kiro v3 engine ignores symlinks —
> kirodotdev/Kiro#9787). Disabling `ai.kiro` removes the materializer itself, so
> already-written steering files are NOT pruned. To uninstall cleanly, first
> empty the steering surface (or set `ai.kiro.steeringStrategy = "symlink"`) for
> one activation, then disable.

</details>

<details open>
<summary><strong>DevEnv (per-project dev shell)</strong></summary>

```yaml
# devenv.yaml
inputs:
  nix-agentic-tools:
    url: github:higherorderfunctor/nix-agentic-tools
    inputs:
      nixpkgs:
        follows: nixpkgs
```

```nix
# devenv.nix
{inputs, ...}: {
  imports = [inputs.nix-agentic-tools.devenvModules.nix-agentic-tools];

  ai.claude.enable = true;

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
| `openmemory-mcp` | Persistent memory + vector search | None |
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

<!-- prettier-ignore -->
| Package | Description |
|---------|-------------|
| `oxlint` | Fast JS/TS linter with type-aware (tsgo) linting and JS plugins |
| `tsgolint` | Type-aware linting backend for oxlint (typescript-go) |

```bash
nix build .#oxlint
```

</details>

<details>
<summary><strong>Generic Packages</strong></summary>

Nothing agentic about these — they live in a split-ready `overlays/generic/`
subtree and are exposed as `pkgs.generic.*`.

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
| `gh` | GitHub CLI |
| `glab` | GitLab CLI |
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
| Stacked workflow skills | Copy skills/ | `stacked-workflows.enable` | `ai.skills.*` |
| MCP server packages | Install manually | `nix build .#<server>` | `nix build .#<server>` |
| MCP server config | Manual JSON | `services.mcp-servers.*` | `claude.code.mcpServers.*` |
| Typed MCP settings | N/A | Per-server typed options | N/A (raw JSON) |
| MCP credentials | Manual env vars | `file` or `helper` | Manual env vars |
| Git tool packages | Install manually | Overlay + `nix build` | Overlay + `nix build` |
| GitLab CLI config | `glab config set` | `glab.*` | `glab.*` |
| GitLab CLI credentials | Manual env vars | `plain`, `file` or `helper` | `plain`, `file` or `helper` |
| Unified AI config | N/A | `ai.*` fans out to all CLIs | `ai.*` fans out to all CLIs |
| LSP server config | N/A | `ai.lspServers.*` | `ai.lspServers.*` |
| Fragment composition | N/A | `lib.ai.compose` | `lib.ai.compose` |

## Configuration

<details>
<summary><strong>Unified ai.* Module</strong></summary>

Single source of truth for shared config across Claude, Copilot, and Kiro.
Settings fan out at `mkDefault` priority — per-CLI overrides always win.

```nix
ai = {
  claude.enable = true;
  copilot.enable = true;

  skills.my-skill = ./skills/my-skill;

  instructions.standards = {
    text = "Use strict mode everywhere";
    paths = ["src/**"];
    description = "Project standards";
  };

  lspServers.nixd = {
    package = pkgs.nixd;
    extensions = ["nix"];
  };

  settings = {
    model = "claude-sonnet-4";
    telemetry = false;
  };
};
```

</details>

<details>
<summary><strong>Claude Delegation-Clamp Mitigation (on by default)</strong></summary>

Claude Code injects a system-prompt section telling the model not to use
subagents, workflows, or deep research "unless the user requested it". It is
gated on a **model capability**, not on your configuration — on by default for
Opus 5 — and no setting, flag, or environment variable turns it off. It never
appears in the transcript, so a session with delegation silently suppressed
looks identical to a normal one. It also directly contradicts
`ai.claude.ultracodeOnLaunch`, which asks for the opposite.

Enabling Claude through `ai.claude` installs a mitigation automatically. It
patches nothing: a `UserPromptSubmit` hook supplies the request that the clamp's
own escape clause is asking for, as user-side context. It is injected once per
session and re-armed by a `PreCompact` hook, so the cost is roughly 75 tokens
per session rather than per turn.

```nix
ai.claude.delegationClamp = {
  mitigate = true;        # default; set false for stock behavior
  text = "…";             # the standing request — wording is load-bearing
};
```

Upstream:
[anthropics/claude-code#80988](https://github.com/anthropics/claude-code/issues/80988).
Two tripwires force re-evaluation instead of letting this calcify — a flake
check fails when the pinned Claude Code version moves, and a dated CI step fails
once `config/heron-brook-tripwire.json`'s `reviewBy` passes. See
`packages/claude-code/docs/heron-brook-clamp.md`.

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
stacked-workflows = {
  enable = true;
  gitPreset = "full";     # or "minimal" or "none"
  integrations = {
    claude.enable = true;
    copilot.enable = true;
    kiro.enable = true;
  };
};
```

See the `stacked-workflows` package for git presets and skill details.

</details>

## License

Released under the [Unlicense](LICENSE).
