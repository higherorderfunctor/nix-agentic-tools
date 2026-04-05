{
  description = "Agentic tools — skills, MCP servers, and home-manager modules for AI coding CLIs";

  inputs = {
    mcp-nixos = {
      url = "github:utensils/mcp-nixos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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
      default = lib.composeManyExtensions [
        (import ./packages/ai-clis {inherit inputs;})
        (import ./packages/git-tools {inherit inputs;})
        (import ./packages/mcp-servers {inherit inputs;})
      ];
      git-tools = import ./packages/git-tools {inherit inputs;};
      mcp-servers = import ./packages/mcp-servers {inherit inputs;};
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
    in {
      inherit fragments;
      inherit (devshellLib) mkAgenticShell;
      inherit (mcpLib) loadServer mkStdioEntry mkHttpEntry mkStdioConfig;
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

    apps = forAllSystems (system: let
      pkgs = pkgsFor system;
      devPackages = fragments.packagesWithProfile "dev";
      generateScript = pkgs.writeShellApplication {
        name = "generate";
        text = let
          claudeCommon = fragments.mkInstructions {
            package = "monorepo";
            profile = "dev";
            ecosystem = "claude";
          };
          kiroCommon = fragments.mkInstructions {
            package = "monorepo";
            profile = "dev";
            ecosystem = "kiro";
          };
          copilotCommon = fragments.mkInstructions {
            package = "monorepo";
            profile = "dev";
            ecosystem = "copilot";
          };
          agentsBase = fragments.mkInstructions {
            package = "monorepo";
            profile = "dev";
            ecosystem = "agentsmd";
          };
          agentsPackageContent = builtins.concatStringsSep "\n" (lib.mapAttrsToList (pkg: _:
            fragments.mkPackageContent {
              package = pkg;
              profile = "dev";
            })
          nonRootPackages);
          agentsContent = agentsBase + lib.optionalString (agentsPackageContent != "") ("\n" + agentsPackageContent);
          nonRootPackages = lib.filterAttrs (name: _: name != "monorepo") devPackages;
          perPackageOutputs = lib.concatMapStringsSep "\n" (pkg: let
            claude = fragments.mkInstructions {
              package = pkg;
              profile = "dev";
              ecosystem = "claude";
            };
            kiro = fragments.mkInstructions {
              package = pkg;
              profile = "dev";
              ecosystem = "kiro";
            };
            copilot = fragments.mkInstructions {
              package = pkg;
              profile = "dev";
              ecosystem = "copilot";
            };
          in ''
            cat > "$REPO_ROOT/.claude/rules/${pkg}.md" << 'FRAGMENT_EOF'
            ${claude}
            FRAGMENT_EOF
            cat > "$REPO_ROOT/.kiro/steering/${pkg}.md" << 'FRAGMENT_EOF'
            ${kiro}
            FRAGMENT_EOF
            cat > "$REPO_ROOT/.github/instructions/${pkg}.instructions.md" << 'FRAGMENT_EOF'
            ${copilot}
            FRAGMENT_EOF
          '') (builtins.attrNames nonRootPackages);
        in ''
          REPO_ROOT="$(pwd)"
          cat > "$REPO_ROOT/.claude/rules/common.md" << 'FRAGMENT_EOF'
          ${claudeCommon}
          FRAGMENT_EOF
          cat > "$REPO_ROOT/.kiro/steering/common.md" << 'FRAGMENT_EOF'
          ${kiroCommon}
          FRAGMENT_EOF
          cat > "$REPO_ROOT/.github/copilot-instructions.md" << 'FRAGMENT_EOF'
          ${copilotCommon}
          FRAGMENT_EOF
          cat > "$REPO_ROOT/AGENTS.md" << 'FRAGMENT_EOF'
          # AGENTS.md

          Project instructions for AI coding assistants working in this repository.
          Read by Claude Code, Kiro, GitHub Copilot, Codex, and other tools that
          support the [AGENTS.md standard](https://agents.md).

          ${agentsContent}
          FRAGMENT_EOF
          ${perPackageOutputs}
          echo "Generated instruction files from fragments."
        '';
      };
    in {
      generate = {
        type = "app";
        program = lib.getExe generateScript;
      };
    });

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
      # AI CLIs
      inherit (pkgs) github-copilot-cli kiro-cli kiro-gateway;
      # Git tools
      inherit (pkgs) agnix git-absorb git-branchless git-revise;
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
        sympy-mcp
        ;
    });
  };
}
