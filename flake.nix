{
  description = "Agentic tools — skills, MCP servers, and home-manager modules for AI coding CLIs";

  inputs = {
    mcp-nixos = {
      url = "github:utensils/mcp-nixos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    serena = {
      url = "github:oraios/serena";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nvfetcher = {
      url = "github:berberman/nvfetcher";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    inherit (nixpkgs) lib;
    supportedSystems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    forAllSystems = lib.genAttrs supportedSystems;
    pkgsFor = system:
      import nixpkgs {
        inherit system;
        config = lib.optionalAttrs (system == "x86_64-linux") {
          allowUnfree = true;
          cudaSupport = true;
          cudaCapabilities = ["7.5" "8.6" "8.9"];
        };
        overlays = [self.overlays.default];
      };
    fragments = import ./lib/fragments.nix {inherit lib;};
  in {
    overlays = {
      ai-clis = import ./packages/ai-clis {inherit inputs;};
      coding-standards = import ./packages/coding-standards {};
      default = lib.composeManyExtensions [
        (import ./packages/ai-clis {inherit inputs;})
        (import ./packages/coding-standards {})
        (import ./packages/fragments-ai {})
        (import ./packages/git-tools {inherit inputs;})
        (import ./packages/mcp-servers {inherit inputs;})
        (import ./packages/stacked-workflows {})
      ];
      fragments-ai = import ./packages/fragments-ai {};
      git-tools = import ./packages/git-tools {inherit inputs;};
      mcp-servers = import ./packages/mcp-servers {inherit inputs;};
      stacked-workflows = import ./packages/stacked-workflows {};
    };

    devenvModules = {
      ai = ./modules/devenv/ai.nix;
      copilot = ./modules/devenv/copilot.nix;
      default = ./modules/devenv;
      kiro = ./modules/devenv/kiro.nix;
    };

    homeManagerModules = {
      ai = ./modules/ai;
      copilot-cli = ./modules/copilot-cli;
      default = ./modules;
      kiro-cli = ./modules/kiro-cli;
      mcp-servers = ./modules/mcp-servers;
      stacked-workflows = ./modules/stacked-workflows;
    };

    lib = let
      devshellLib = import ./lib/devshell.nix {inherit lib;};
      mcpLib = import ./lib/mcp.nix {inherit lib;};

      # Cross-package presets (compose fragments from multiple packages).
      # Individual packages expose their own presets in passthru.presets;
      # these combine across package boundaries.
      codingStdFragments = import ./packages/coding-standards/default.nix {} lib.id {};
      swsFragments = import ./packages/stacked-workflows/default.nix {} lib.id {};
      presets = {
        # Full dev environment — all coding standards + skill routing
        nix-agentic-tools-dev = fragments.compose {
          fragments =
            builtins.attrValues codingStdFragments.coding-standards.passthru.fragments
            ++ builtins.attrValues swsFragments.stacked-workflows-content.passthru.fragments;
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
      gitConfig = import ./modules/stacked-workflows/git-config.nix;
      gitConfigFull = import ./modules/stacked-workflows/git-config-full.nix;
    };

    checks = forAllSystems (system: let
      pkgs = pkgsFor system;
      moduleChecks = import ./checks/module-eval.nix {inherit lib pkgs self;};
      devshellChecks = import ./checks/devshell-eval.nix {inherit lib pkgs self;};
    in
      moduleChecks // devshellChecks);

    # devShell provided by devenv CLI (devenv shell / devenv test)
    # See devenv.nix for shell configuration.

    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      # Documentation
      docs =
        pkgs.runCommand "nix-agentic-tools-docs" {
          nativeBuildInputs = [pkgs.mdbook];
          src = ./docs;
        } ''
          cp -r $src docs
          mdbook build docs
          mv docs/../result-docs $out
        '';

      # AI CLIs
      inherit (pkgs) claude-code github-copilot-cli kiro-cli kiro-gateway;
      # Content packages
      inherit (pkgs) coding-standards fragments-ai stacked-workflows-content;
      # Git tools
      inherit (pkgs) agnix git-absorb git-branchless git-revise;

      # Instruction derivations (from dev/generate.nix)
      instructions-agents = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
      in
        pkgs.writeText "AGENTS.md" gen.agentsMd;

      instructions-claude = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
      in
        pkgs.writeText "CLAUDE.md" gen.claudeMd;

      instructions-copilot = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
      in
        pkgs.runCommand "instructions-copilot" {} (
          "mkdir -p $out/instructions\n"
          + lib.concatStringsSep "\n" (lib.mapAttrsToList (name: content: ''
              cat > $out/${
                if name == "copilot-instructions.md"
                then name
                else "instructions/${name}"
              } << 'FRAGMENT_EOF'
              ${content}
              FRAGMENT_EOF
            '')
            gen.copilotFiles)
        );

      instructions-kiro = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
      in
        pkgs.runCommand "instructions-kiro" {} (
          "mkdir -p $out\n"
          + lib.concatStringsSep "\n" (lib.mapAttrsToList (name: content: ''
              cat > $out/${name} << 'FRAGMENT_EOF'
              ${content}
              FRAGMENT_EOF
            '')
            gen.kiroFiles)
        );
      inherit
        (pkgs.nix-mcp-servers)
        context7-mcp
        effect-mcp
        fetch-mcp
        git-intel-mcp
        git-mcp
        github-mcp
        kagi-mcp
        mcp-language-server
        mcp-proxy
        nixos-mcp
        openmemory-mcp
        sequential-thinking-mcp
        serena-mcp
        sympy-mcp
        ;
    });
  };
}
