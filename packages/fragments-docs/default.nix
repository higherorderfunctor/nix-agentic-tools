# Doc site generators — snippet and full-page content for mdbook.
# Derivation: pkgs.fragments-docs
# passthru.generators provides eval-time access to content generators.
_: final: _prev: let
  # ── Snippet generators ──────────────────────────────────────────────
  # Small tables embedded in mixed pages via {{#include ../generated/X.md}}
  snippets = {
    # Overlay summary table for getting-started/home-manager.md
    overlayTable = _: ''
      | Overlay             | Packages                                              |
      | ------------------- | ----------------------------------------------------- |
      | `ai-clis`           | `github-copilot-cli`, `kiro-cli`, `kiro-gateway`      |
      | `coding-standards`  | `coding-standards` (fragment content)                 |
      | `git-tools`         | `agnix`, `git-absorb`, `git-branchless`, `git-revise` |
      | `mcp-servers`       | `nix-mcp-servers.*` (14 servers)                      |
      | `stacked-workflows` | `stacked-workflows-content` (skills, references)      |'';

    # Supported CLIs table for index.md
    cliTable = _: ''
      | CLI            | HM Module              | DevEnv Module      | Ecosystem Key |
      | -------------- | ---------------------- | ------------------ | ------------- |
      | Claude Code    | `ai.claude.enable`     | `ai.claude.enable` | `claude`      |
      | GitHub Copilot | `programs.copilot-cli` | `copilot.*`        | `copilot`     |
      | Kiro           | `programs.kiro-cli`    | `kiro.*`           | `kiro`        |'';

    # ai.* settings mapping table for reference/ai-mapping.md and mixed pages
    aiMappingTable = _: ''
      | `ai.*` option          | Claude Code                           | Copilot CLI                                 | Kiro CLI                                       |
      | ---------------------- | ------------------------------------- | ------------------------------------------- | ---------------------------------------------- |
      | `settings.model`       | `programs.claude-code.settings.model` | `programs.copilot-cli.settings.model`       | `programs.kiro-cli.settings.chat.defaultModel` |
      | `settings.telemetry`   | --                                    | --                                          | `programs.kiro-cli.settings.telemetry.enabled` |
      | `environmentVariables` | --                                    | `programs.copilot-cli.environmentVariables` | `programs.kiro-cli.environmentVariables`       |'';
  };

  # ── Full-page generators ────────────────────────────────────────────
  # Complete markdown pages generated into docs/src/ directories.
  overlayPackages = _:
    builtins.readFile ./pages/overlays-packages.md;

  hmOptions = _:
    builtins.readFile ./pages/home-manager.md;

  devenvOptions = _:
    builtins.readFile ./pages/devenv.md;

  mcpServers = _:
    builtins.readFile ./pages/mcp-servers.md;

  libApi = _:
    builtins.readFile ./pages/lib-api.md;

  typesRef = _:
    builtins.readFile ./pages/types.md;

  aiMapping = _:
    builtins.readFile ./pages/ai-mapping.md;
in {
  fragments-docs =
    final.runCommand "fragments-docs" {} ''
      mkdir -p $out
    ''
    // {
      passthru.generators = {
        inherit snippets;
        inherit aiMapping devenvOptions hmOptions libApi mcpServers overlayPackages typesRef;
      };
    };
}
