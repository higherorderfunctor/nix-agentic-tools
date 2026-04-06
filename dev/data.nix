# Shared description mappings for README, doc site, and snippet generators.
#
# Single source of truth for package/server/tool descriptions used by
# both dev/generate.nix (README, CONTRIBUTING) and fragments-docs
# (doc site snippets and reference pages).
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
    claude-code = "Claude Code CLI";
    github-copilot-cli = "GitHub Copilot CLI";
    kiro-cli = "Kiro CLI";
    kiro-gateway = "Python proxy API for Kiro";
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
      packages = ["github-copilot-cli" "kiro-cli" "kiro-gateway"];
      suffix = null;
    };
    coding-standards = {
      packages = ["coding-standards"];
      suffix = "fragment content";
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
    gitToolDescriptions
    mcpServerCount
    mcpServerMeta
    overlayPackages
    skillDescriptions
    ;
}
