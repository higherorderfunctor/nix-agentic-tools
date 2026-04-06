# Doc site generators — snippet and full-page content for mdbook.
# Derivation: pkgs.fragments-docs
# passthru.generators provides eval-time access to content generators.
#
# Snippets and the overlays-packages page are data-driven: they take
# description mappings from dev/data.nix (passed through flake.nix)
# so the same data feeds both the README and the doc site.
_: final: _prev: let
  inherit (final) lib;

  # ── Table formatting helpers ─────────────────────────────────────────
  # Generates a sorted markdown table body from an attrset.
  mkSortedRows = names: mkRow:
    lib.concatMapStringsSep "\n" mkRow
    (lib.sort lib.lessThan names);

  # Format a single overlay row from overlayPackages data.
  mkOverlayDisplay = info:
    info.display
    or (
      let
        pkgList = lib.concatMapStringsSep ", " (p: "`${p}`") info.packages;
      in
        if info.suffix or null != null
        then "${pkgList} (${info.suffix})"
        else pkgList
    );

  # ── Snippet generators ──────────────────────────────────────────────
  # Small tables embedded in mixed pages via {{#include ../generated/X.md}}
  # Each takes { data } with the relevant description mappings.
  snippets = {
    # Overlay summary table for getting-started/home-manager.md
    overlayTable = {data}: let
      overlayNames = lib.sort lib.lessThan (builtins.attrNames data.overlayPackages);
      mkRow = name: "| `${name}` | ${mkOverlayDisplay data.overlayPackages.${name}} |";
    in ''
      | Overlay | Packages |
      | ------- | -------- |
      ${lib.concatMapStringsSep "\n" mkRow overlayNames}'';

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

  # Dynamic: generated from package data
  overlayPackages = {data}: let
    # ── AI CLI table ───────────────────────────────────────────────
    aiCliNames = builtins.attrNames data.aiCliDescriptions;
    aiCliRows = mkSortedRows aiCliNames (name: "| `${name}` | ${data.aiCliDescriptions.${name}} |");

    # ── Git tool table ─────────────────────────────────────────────
    gitToolNames = builtins.attrNames data.gitToolDescriptions;
    gitToolRows = mkSortedRows gitToolNames (name: "| `${name}` | ${data.gitToolDescriptions.${name}} |");

    # ── MCP server table ───────────────────────────────────────────
    mcpNames = builtins.attrNames data.mcpServerMeta;
    mcpRows = mkSortedRows mcpNames (name: let
      meta = data.mcpServerMeta.${name};
    in "| `${name}` | ${meta.description} | ${meta.credentials} |");

    # ── Overlay table ──────────────────────────────────────────────
    overlayNames = lib.sort lib.lessThan (builtins.attrNames data.overlayPackages);
    overlayRows =
      lib.concatMapStringsSep "\n" (name: "| `overlays.${name}` | ${mkOverlayDisplay data.overlayPackages.${name}} |")
      overlayNames;
  in ''
    # Overlays & Packages

    nix-agentic-tools exports packages via Nix overlays. Apply the overlay to
    your nixpkgs, and the packages become available in `pkgs`.

    ## Overlays

    | Overlay | What it adds |
    | ------- | ------------ |
    | `overlays.default` | All overlays composed |
    ${overlayRows}

    Most users should apply `overlays.default`:

    ```nix
    nixpkgs.overlays = [inputs.nix-agentic-tools.overlays.default];
    ```

    ## Package Reference

    ### AI CLIs

    | Package | Description |
    | ------- | ----------- |
    ${aiCliRows}

    ### Git Tools

    | Package | Description |
    | ------- | ----------- |
    ${gitToolRows}

    ### MCP Servers

    Available under `pkgs.nix-mcp-servers.*`:

    | Package | Description | Credentials |
    | ------- | ----------- | ----------- |
    ${mcpRows}

    ### Content Packages

    | Package | Description | passthru |
    | ------- | ----------- | -------- |
    | `coding-standards` | Reusable coding standard fragments | `.fragments.*`, `.presets.all`, `.presets.minimal` |
    | `stacked-workflows-content` | Skills, references, routing-table | `.fragments.*`, `.skillsDir`, `.referencesDir` |

    ## Content Package passthru

    Content packages are Nix derivations (store paths with files) that also
    carry typed data in `passthru` for eval-time composition.

    ### coding-standards

    ```nix
    pkgs.coding-standards.passthru.fragments
    # => {
    #   coding-standards = { text = "..."; description = "..."; priority = 10; };
    #   commit-convention = { ... };
    #   config-parity = { ... };
    #   tooling-preference = { ... };
    #   validation = { ... };
    # }

    pkgs.coding-standards.passthru.presets.all
    # => composed fragment with all 5 standards

    pkgs.coding-standards.passthru.presets.minimal
    # => coding-standards + commit-convention only
    ```

    ### stacked-workflows-content

    ```nix
    pkgs.stacked-workflows-content.passthru.fragments.routing-table
    # => { text = "..."; description = "Stacked workflow skill routing table"; }

    "${"$"}{pkgs.stacked-workflows-content}/skills/stack-fix"
    # => /nix/store/...-stacked-workflows-content/skills/stack-fix/

    pkgs.stacked-workflows-content.passthru.skillsDir
    # => source path to skills directory (for symlinks)
    ```

    ## MCP Package passthru

    MCP server packages carry metadata for composing MCP entries:

    ```nix
    pkgs.nix-mcp-servers.github-mcp.mcpName
    # => "github-mcp"

    # Some packages carry mcpBinary (when it differs from mainProgram):
    pkgs.agnix.mcpBinary
    # => "agnix-mcp"

    # Or mcpArgs (for subcommand-based servers):
    pkgs.serena-mcp.mcpArgs
    # => ["start-mcp-server"]
    ```

    Use `lib.mkPackageEntry` to derive a complete MCP config entry:

    ```nix
    lib.mkPackageEntry pkgs.nix-mcp-servers.github-mcp
    # => { type = "stdio"; command = "/nix/store/.../github-mcp-server"; args = [...]; }
    ```
  '';

  # Static pages — kept as readFile for now; Phase 4 makes these dynamic
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
