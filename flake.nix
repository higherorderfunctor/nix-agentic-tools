{
  description = "Agentic tools — skills, MCP servers, and home-manager modules for AI coding CLIs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    lib = nixpkgs.lib;
    supportedSystems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    forAllSystems = lib.genAttrs supportedSystems;
    pkgsFor = system: import nixpkgs {inherit system;};
    fragments = import ./lib/fragments.nix {inherit lib;};
  in {
    homeManagerModules = {
      copilot-cli = ./modules/copilot-cli;
      kiro-cli = ./modules/kiro-cli;
      default = ./modules;
    };

    lib = {
      inherit fragments;
    };

    apps = forAllSystems (system: let
      pkgs = pkgsFor system;
      devPackages = fragments.packagesWithProfile "dev";
      generateScript = pkgs.writeShellApplication {
        name = "generate";
        text = let
          claudeCommon = fragments.mkInstructions {package = "monorepo"; profile = "dev"; ecosystem = "claude";};
          kiroCommon = fragments.mkInstructions {package = "monorepo"; profile = "dev"; ecosystem = "kiro";};
          copilotCommon = fragments.mkInstructions {package = "monorepo"; profile = "dev"; ecosystem = "copilot";};
          agentsBase = fragments.mkInstructions {package = "monorepo"; profile = "dev"; ecosystem = "agentsmd";};
          agentsPackageContent = builtins.concatStringsSep "\n" (lib.mapAttrsToList (pkg: _: fragments.mkPackageContent {package = pkg; profile = "dev";}) nonRootPackages);
          agentsContent = agentsBase + lib.optionalString (agentsPackageContent != "") ("\n" + agentsPackageContent);
          nonRootPackages = lib.filterAttrs (name: _: name != "monorepo") devPackages;
          perPackageOutputs = lib.concatMapStringsSep "\n" (pkg: let
            claude = fragments.mkInstructions {package = pkg; profile = "dev"; ecosystem = "claude";};
            kiro = fragments.mkInstructions {package = pkg; profile = "dev"; ecosystem = "kiro";};
            copilot = fragments.mkInstructions {package = pkg; profile = "dev"; ecosystem = "copilot";};
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
      generate = {type = "app"; program = lib.getExe generateScript;};
    });

    devShells = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      default = pkgs.mkShell {
        name = "agentic-tools";
        packages = with pkgs; [
          alejandra
          dprint
        ];
      };
    });

    checks = forAllSystems (system: let
      pkgs = pkgsFor system;
      moduleChecks = import ./checks/module-eval.nix {inherit lib pkgs self;};
    in moduleChecks);

    formatter = forAllSystems (system: (pkgsFor system).dprint);
  };
}
