# MCP Server Configuration

14 Model Context Protocol servers are packaged and ready to use. Each
has typed settings, optional credentials, and works in both stdio and
HTTP modes.

## Quick Start

```nix
# Home-manager
services.mcp-servers.servers = {
  github-mcp = {
    enable = true;
    settings.credentials.file = "/run/secrets/github-token";
  };
  nixos-mcp.enable = true;
  context7-mcp.enable = true;
};

# DevEnv (inline per-CLI)
claude.code.mcpServers.github-mcp =
  inputs.nix-agentic-tools.lib.mcp.mkStdioEntry pkgs {
    package = pkgs.nix-mcp-servers.github-mcp;
    settings.credentials.file = "/run/secrets/github-token";
  };
```

## Server Reference

### context7-mcp

Library documentation lookup. Resolves library IDs and queries
up-to-date docs for frameworks and SDKs.

| Setting       | Type           | Default | Description                   |
| ------------- | -------------- | ------- | ----------------------------- |
| `credentials` | file or helper | `null`  | `CONTEXT7_API_KEY` (optional) |
| `apiUrl`      | nullOr str     | `null`  | Override base API URL         |

**Tools:** `query-docs`, `resolve-library-id`

```nix
services.mcp-servers.servers.context7-mcp.enable = true;
```

### effect-mcp

Effect-TS documentation server. Searches and retrieves Effect
framework docs.

No settings. No credentials.

**Tools:** `effect_docs_search`, `get_effect_doc`

```nix
services.mcp-servers.servers.effect-mcp.enable = true;
```

### fetch-mcp

HTTP fetch with HTML-to-markdown conversion. Retrieves web pages and
converts them to clean markdown for context.

| Setting           | Type       | Default | Description              |
| ----------------- | ---------- | ------- | ------------------------ |
| `userAgent`       | nullOr str | `null`  | Custom User-Agent string |
| `proxyUrl`        | nullOr str | `null`  | Proxy URL for requests   |
| `ignoreRobotsTxt` | bool       | `false` | Ignore robots.txt        |

No credentials.

**Tools:** `fetch`

```nix
services.mcp-servers.servers.fetch-mcp = {
  enable = true;
  settings.userAgent = "my-agent/1.0";
};
```

### git-intel-mcp

Git repository analytics. Identifies hotspots, churn patterns,
complexity trends, and contributor knowledge maps.

| Setting      | Type       | Default | Description       |
| ------------ | ---------- | ------- | ----------------- |
| `repository` | nullOr str | `null`  | Default repo path |

No credentials.

**Tools:** `branch_risk`, `churn`, `code_age`, `commit_patterns`,
`complexity_trend`, `contributor_stats`, `coupling`, `file_history`,
`hotspots`, `knowledge_map`, `release_notes`, `risk_assessment`

```nix
services.mcp-servers.servers.git-intel-mcp.enable = true;
```

### git-mcp

Git operations server. Provides tools for staging, committing,
branching, diffing, and log inspection.

| Setting      | Type       | Default | Description                |
| ------------ | ---------- | ------- | -------------------------- |
| `repository` | nullOr str | `null`  | Restrict to this repo path |

No credentials.

**Tools:** `git_add`, `git_branch`, `git_checkout`, `git_commit`,
`git_create_branch`, `git_diff`, `git_diff_staged`,
`git_diff_unstaged`, `git_log`, `git_reset`, `git_show`, `git_status`

```nix
services.mcp-servers.servers.git-mcp.enable = true;
```

### github-mcp

GitHub platform integration. Issues, PRs, code search, actions,
releases, and more. Requires a personal access token.

| Setting                | Type           | Default   | Description                                   |
| ---------------------- | -------------- | --------- | --------------------------------------------- |
| `credentials`          | file or helper | --        | `GITHUB_PERSONAL_ACCESS_TOKEN` **(required)** |
| `toolsets`             | listOf str     | `["all"]` | Toolset groups to enable                      |
| `tools`                | listOf str     | `[]`      | Individual tools (additive)                   |
| `excludeTools`         | listOf str     | `[]`      | Tools to disable                              |
| `readOnly`             | bool           | `false`   | Restrict to read-only ops                     |
| `dynamicToolsets`      | bool           | `false`   | Runtime toolset discovery                     |
| `ghHost`               | nullOr str     | `null`    | GHE Server hostname                           |
| `contentWindowSize`    | nullOr int     | `null`    | Content window (default: 5000)                |
| `logFile`              | nullOr str     | `null`    | Log file path                                 |
| `enableCommandLogging` | bool           | `false`   | Log all commands                              |
| `insiders`             | bool           | `false`   | Enable experimental features                  |
| `lockdownMode`         | bool           | `false`   | Filter by push access                         |

**Tools:** 30+ tools across repos, issues, PRs, search, actions, etc.

```nix
services.mcp-servers.servers.github-mcp = {
  enable = true;
  settings = {
    credentials.file = "/run/secrets/github-token";
    toolsets = ["repos" "pull_requests" "issues"];
    readOnly = true;
  };
};
```

### kagi-mcp

Kagi search and summarization. Web search with Kagi quality and
document summarization.

| Setting            | Type           | Default | Description                             |
| ------------------ | -------------- | ------- | --------------------------------------- |
| `credentials`      | file or helper | --      | `KAGI_API_KEY` **(required)**           |
| `summarizerEngine` | nullOr enum    | `null`  | `cecil`, `agnes`, `daphne`, or `muriel` |

**Tools:** `kagi_search_fetch`, `kagi_summarizer`

```nix
services.mcp-servers.servers.kagi-mcp = {
  enable = true;
  settings = {
    credentials.helper = "${pkgs.pass}/bin/pass show api/kagi";
    summarizerEngine = "cecil";
  };
};
```

### nixos-mcp

NixOS and Nix documentation server. Queries Nix package info and
version data.

| Setting         | Type        | Default | Description         |
| --------------- | ----------- | ------- | ------------------- |
| `statelessHttp` | nullOr bool | `null`  | Stateless HTTP mode |

No credentials.

**Tools:** `nix`, `nix_versions`

```nix
services.mcp-servers.servers.nixos-mcp.enable = true;
```

### openmemory-mcp

Persistent memory with vector search. Stores, queries, and manages
memories with configurable backends and embedding providers.

| Setting             | Type                                   | Default     | Description                              |
| ------------------- | -------------------------------------- | ----------- | ---------------------------------------- |
| `credentials`       | file or helper                         | `null`      | `OM_API_KEY` (optional)                  |
| `openaiCredentials` | file or helper                         | `null`      | `OPENAI_API_KEY` (for OpenAI embeddings) |
| `tier`              | enum                                   | `"hybrid"`  | `hybrid`, `fast`, `smart`, `deep`        |
| `telemetry`         | bool                                   | `true`      | Anonymous telemetry                      |
| `metadataBackend`   | sqlite or postgres                     | `sqlite`    | Metadata storage                         |
| `vectorBackend`     | sqlite, postgres, or valkey            | `sqlite`    | Vector storage                           |
| `embeddings`        | ollama, openai, local, synthetic, etc. | `synthetic` | Embedding provider                       |

Many additional tuning options for decay, reflection, rate limiting,
compression, and search relevance. See the server module source for
the full list.

**Tools:** `openmemory_delete`, `openmemory_get`, `openmemory_list`,
`openmemory_query`, `openmemory_reinforce`, `openmemory_store`

```nix
services.mcp-servers.servers.openmemory-mcp = {
  enable = true;
  settings = {
    embeddings.ollama = {
      url = "http://localhost:11434";
      model = "nomic-embed-text";
    };
  };
};
```

### sequential-thinking-mcp

Step-by-step reasoning server. Helps break down complex problems into
sequential thought steps.

No settings. No credentials.

**Tools:** `sequentialthinking`

```nix
services.mcp-servers.servers.sequential-thinking-mcp.enable = true;
```

### serena-mcp

Codebase-aware semantic tools. Provides symbol finding, reference
tracking, and semantic code navigation.

No settings. No credentials (optional API keys via environment).

**Tools:** `find_referencing_symbols`, `find_symbol`,
`insert_after_symbol`, and more

```nix
services.mcp-servers.servers.serena-mcp.enable = true;
```

### sympy-mcp

Symbolic mathematics via SymPy. Differentiation, integration, equation
solving, linear algebra, tensor calculus, and unit conversion.

No settings. No credentials.

**Tools:** 30+ tools including `differentiate_expression`,
`integrate_expression`, `solve_algebraically`, `create_matrix`,
`calculate_tensor`, `convert_to_units`

```nix
services.mcp-servers.servers.sympy-mcp.enable = true;
```

## Build Patterns

Servers are packaged using the appropriate Nix builder for their
upstream language:

| Builder                  | Servers                                                                          |
| ------------------------ | -------------------------------------------------------------------------------- |
| `buildNpmPackage`        | context7-mcp, effect-mcp, git-intel-mcp, openmemory-mcp, sequential-thinking-mcp |
| `buildPythonApplication` | fetch-mcp, git-mcp, kagi-mcp, sympy-mcp                                          |
| `buildGoModule`          | github-mcp                                                                       |

Serena-mcp and nixos-mcp use their own build patterns.
