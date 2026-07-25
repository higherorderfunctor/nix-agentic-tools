# Shared description mappings for README and CONTRIBUTING generation.
#
# Single source of truth for package/server/tool descriptions used by
# dev/generate.nix (README, CONTRIBUTING).
#
# Using explicit descriptions rather than meta.description because
# user-facing wording may differ from upstream/nixpkgs descriptions.
_: let
  # ── MCP server metadata ──────────────────────────────────────────────
  mcpServerMeta = {
    context7-mcp = {
      description = "Library documentation lookup";
      credentials = "None";
    };
    effect-mcp = {
      description = "Effect-TS documentation";
      credentials = "None";
    };
    fetch-mcp = {
      description = "HTTP fetch + HTML-to-markdown";
      credentials = "None";
    };
    git-intel-mcp = {
      description = "Git repository analytics";
      credentials = "None";
    };
    git-mcp = {
      description = "Git operations";
      credentials = "None";
    };
    github-mcp = {
      description = "GitHub platform integration";
      credentials = "Required";
    };
    gitlab-mcp = {
      description = "GitLab platform integration";
      credentials = "Required";
    };
    kagi-mcp = {
      description = "Kagi search and summarization";
      credentials = "Required";
    };
    mcp-language-server = {
      description = "LSP-to-MCP bridge";
      credentials = "None";
    };
    mcp-proxy = {
      description = "stdio-to-HTTP bridge proxy";
      credentials = "None";
    };
    nixos-mcp = {
      description = "NixOS and Nix documentation";
      credentials = "None";
    };
    openmemory-mcp = {
      description = "Persistent memory + vector search";
      credentials = "None";
    };
    sequential-thinking-mcp = {
      description = "Step-by-step reasoning";
      credentials = "None";
    };
    serena-mcp = {
      description = "Codebase-aware semantic tools";
      credentials = "Optional";
    };
    sympy-mcp = {
      description = "Symbolic mathematics";
      credentials = "None";
    };
  };

  # ── AI CLI descriptions ──────────────────────────────────────────────
  aiCliDescriptions = {
    chatgpt-codex = "OpenAI Codex CLI";
    claude-code = "Claude Code CLI";
    github-copilot-cli = "GitHub Copilot CLI";
    kimchi = "Kimchi CLI";
    kiro-cli = "Kiro CLI";
    kiro-gateway = "Python proxy API for Kiro";
  };

  # ── Dev tool descriptions ────────────────────────────────────────────
  devToolDescriptions = {
    oxlint = "Fast JS/TS linter with type-aware (tsgo) linting and JS plugins";
    tsgolint = "Type-aware linting backend for oxlint (typescript-go)";
  };

  # ── Generic (non-agentic) package descriptions ───────────────────────
  genericDescriptions = {
    arkenfox = "Hardened Firefox user.js preference set";
    catppuccin-btop = "Catppuccin theme files for btop";
    dns-root-hints = "IANA DNS root name server hints (named.root)";
  };

  # ── Git tool descriptions ────────────────────────────────────────────
  gitToolDescriptions = {
    agnix = "Linter, LSP, and MCP for AI config files";
    git-absorb = "Automatic fixup commit routing";
    git-branchless = "Anonymous branching, in-memory rebases";
    git-revise = "In-memory commit rewriting";
  };

  # ── Overlay package listings ─────────────────────────────────────────
  # Maps overlay name to its user-visible packages and description suffix.
  overlayPackages = {
    ai-clis = {
      packages = ["chatgpt-codex" "github-copilot-cli" "kimchi" "kiro-cli" "kiro-gateway"];
      suffix = null;
    };
    coding-standards = {
      packages = ["coding-standards"];
      suffix = "fragment content";
    };
    dev-tools = {
      packages = ["oxlint" "tsgolint"];
      suffix = null;
    };
    generic = {
      packages = ["arkenfox" "catppuccin-btop" "dns-root-hints"];
      suffix = null;
    };
    git-tools = {
      packages = ["agnix" "git-absorb" "git-branchless" "git-revise"];
      suffix = null;
    };
    mcp-servers = {
      packages = [];
      display = "`nix-mcp-servers.*` (${toString mcpServerCount} servers)";
    };
    stacked-workflows = {
      packages = ["stacked-workflows-content"];
      suffix = "skills, references";
    };
  };

  # ── Skill descriptions ──────────────────────────────────────────────
  skillDescriptions = {
    stack-fix = "Absorb fixes into correct stack commits";
    stack-plan = "Plan and build a commit stack from description or existing commits";
    stack-split = "Split a large commit into reviewable atomic commits";
    stack-submit = "Sync, validate, push stack, and create stacked PRs";
    stack-summary = "Analyze stack quality, flag violations, produce planner-ready summary";
    stack-test = "Run tests or formatters across every commit in a stack";
  };

  # ── Derived counts ──────────────────────────────────────────────────
  mcpServerCount = builtins.length (builtins.attrNames mcpServerMeta);
in {
  inherit
    aiCliDescriptions
    devToolDescriptions
    genericDescriptions
    gitToolDescriptions
    mcpServerCount
    mcpServerMeta
    overlayPackages
    skillDescriptions
    ;
}
