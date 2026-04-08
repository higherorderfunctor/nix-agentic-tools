{
  description = "Agentic tools — skills, MCP servers, and home-manager modules for AI coding CLIs";

  nixConfig = {
    extra-substituters = [
      "https://nix-agentic-tools.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-agentic-tools.cachix.org-1:0jFprh5fkDez9mk6prYisYxzalr0hn78kyywGPXvOn0="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    inherit (nixpkgs) lib;
    supportedSystems = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
    forAllSystems = lib.genAttrs supportedSystems;
    pkgsFor = system:
      import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [self.overlays.default];
      };
    # Bind each overlay once so `overlays.<name>` and the
    # `overlays.default` composition share the same import.
    codingStandardsOverlay = import ./packages/coding-standards {};
    fragmentsAiOverlay = import ./packages/fragments-ai {};
    fragmentsDocsOverlay = import ./packages/fragments-docs {};
    stackedWorkflowsOverlay = import ./packages/stacked-workflows {};
  in {
    overlays = {
      coding-standards = codingStandardsOverlay;
      default = lib.composeManyExtensions [
        codingStandardsOverlay
        fragmentsAiOverlay
        fragmentsDocsOverlay
        stackedWorkflowsOverlay
      ];
      fragments-ai = fragmentsAiOverlay;
      fragments-docs = fragmentsDocsOverlay;
      stacked-workflows = stackedWorkflowsOverlay;
    };

    # Scaffolding placeholders — subsequent PRs populate these.
    devenvModules = {};
    homeManagerModules = {};

    lib = let
      fragments = import ./lib/fragments.nix {inherit lib;};
      devshellLib = import ./lib/devshell.nix {inherit lib;};
      mcpLib = import ./lib/mcp.nix {inherit lib;};

      # Cross-package presets (compose fragments from multiple
      # packages). Individual packages expose their own presets in
      # passthru.presets; these combine across package boundaries.
      #
      # We invoke the overlay functions with a stub `final` that
      # provides only `lib` and a fake `runCommand`. The overlay's
      # `passthru.fragments` attrset doesn't depend on the
      # derivation itself, only on `final.lib` (for the fragments
      # library import), so this is enough to extract fragment data
      # without instantiating a real pkgs set.
      stubFinal = {
        inherit lib;
        runCommand = name: _: _: {
          inherit name;
          type = "derivation";
        };
      };
      codingStdFragments =
        (codingStandardsOverlay stubFinal {}).coding-standards.passthru.fragments;
      swsContentFragments =
        (stackedWorkflowsOverlay stubFinal {}).stacked-workflows-content.passthru.fragments;
      presets = {
        # Full dev environment — all coding standards + skill routing
        nix-agentic-tools-dev = fragments.compose {
          fragments =
            builtins.attrValues codingStdFragments
            ++ builtins.attrValues swsContentFragments;
          description = "Full nix-agentic-tools dev standards";
        };
      };
    in {
      inherit fragments presets;
      inherit (devshellLib) mkAgenticShell;
      inherit (fragments) compose mkFragment mkFrontmatter render;
      inherit (mcpLib) loadServer mkPackageEntry mkStdioEntry mkHttpEntry mkStdioConfig;
      mkMcpConfig = entries: {mcpServers = entries;};
      mapTools = f: lib.concatLists (lib.mapAttrsToList (server: tools: map (tool: f server tool) tools));
      externalServers = {
        aws-mcp = {
          type = "http";
          url = "https://knowledge-mcp.global.api.aws";
        };
      };
      # `gitConfig` / `gitConfigFull` defer to Chunk 8 (depends on
      # modules/stacked-workflows/git-config*.nix).
    };

    checks = forAllSystems (_: {});
    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      # Instruction file derivations (from dev/generate.nix).
      # Each ecosystem produces a content directory consumed by the
      # `generate:instructions:*` devenv tasks.
      instructions-agents = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
      in
        pkgs.writeText "AGENTS.md" gen.agentsMd;

      instructions-claude = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
        files =
          {"CLAUDE.md" = gen.claudeMd;}
          // lib.mapAttrs' (
            name: content: lib.nameValuePair "rules/${name}" content
          )
          gen.claudeFiles;
      in
        pkgs.runCommand "instructions-claude" {} (
          "mkdir -p $out/rules\n"
          + lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: content: "cp ${pkgs.writeText (baseNameOf name) content} $out/${name}"
            )
            files
          )
        );

      instructions-copilot = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
        files =
          lib.mapAttrs' (
            name: content:
              lib.nameValuePair (
                if name == "copilot-instructions.md"
                then name
                else "instructions/${name}"
              )
              content
          )
          gen.copilotFiles;
      in
        pkgs.runCommand "instructions-copilot" {} (
          "mkdir -p $out/instructions\n"
          + lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: content: "cp ${pkgs.writeText (baseNameOf name) content} $out/${name}"
            )
            files
          )
        );

      instructions-kiro = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
      in
        pkgs.runCommand "instructions-kiro" {} (
          "mkdir -p $out\n"
          + lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: content: "cp ${pkgs.writeText name content} $out/${name}"
            )
            gen.kiroFiles
          )
        );
    });

    # Standard flake outputs for `nix develop` and `nix fmt`.
    # Primary dev workflow is `devenv shell` / `devenv test` via
    # devenv.nix; these outputs preserve flake UX for users who
    # prefer plain Nix CLI.
    devShells = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      default = pkgs.mkShell {
        name = "nix-agentic-tools";
        packages = with pkgs; [
          alejandra
          treefmt
        ];
      };
    });

    formatter = forAllSystems (system: (pkgsFor system).alejandra);
  };
}
