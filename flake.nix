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
    mcp-nixos = {
      url = "github:utensils/mcp-nixos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nuscht-search = {
      url = "github:NuschtOS/search";
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
    serena = {
      url = "github:oraios/serena";
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
        config.allowUnfree = true;
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
        (import ./packages/fragments-docs {})
        (import ./packages/git-tools {inherit inputs;})
        (import ./packages/mcp-servers {inherit inputs;})
        (import ./packages/stacked-workflows {})
      ];
      fragments-ai = import ./packages/fragments-ai {};
      fragments-docs = import ./packages/fragments-docs {};
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
      docGen = pkgs.fragments-docs.passthru.generators;
      docData = import ./dev/data.nix {inherit lib;};

      # Options documentation generated from actual module definitions
      optionsDocs = import ./lib/options-doc.nix {inherit lib pkgs self;};

      # Assembled options pages: header + generated options + footer
      docsOptionsHm =
        pkgs.runCommand "docs-options-hm" {
          header = ./packages/fragments-docs/pages/home-manager-header.md;
          optionsMd = optionsDocs.hmOptionsDoc.optionsCommonMark;
          footer = ./packages/fragments-docs/pages/home-manager-footer.md;
        } ''
          cat $header > $out
          printf '\n' >> $out
          cat $optionsMd >> $out
          printf '\n' >> $out
          cat $footer >> $out
        '';

      docsOptionsDevenv =
        pkgs.runCommand "docs-options-devenv" {
          header = ./packages/fragments-docs/pages/devenv-header.md;
          optionsMd = optionsDocs.devenvOptionsDoc.optionsCommonMark;
          footer = ./packages/fragments-docs/pages/devenv-footer.md;
        } ''
          cat $header > $out
          printf '\n' >> $out
          cat $optionsMd >> $out
          printf '\n' >> $out
          cat $footer >> $out
        '';

      # Doc site components — local bindings for cross-referencing
      siteProse = pkgs.runCommand "docs-site-prose" {} ''
        cp -r ${./dev/docs} $out
        chmod -R u+w $out
      '';

      siteSnippets =
        pkgs.runCommand "docs-site-snippets" {
          aiMappingTable = pkgs.writeText "ai-mapping-table.md" (docGen.snippets.aiMappingTable {});
          cliTable = pkgs.writeText "cli-table.md" (docGen.snippets.cliTable {});
          credentialsTable = pkgs.writeText "credentials-table.md" (docGen.snippets.credentialsTable {data = docData;});
          overlayTable = pkgs.writeText "overlay-table.md" (docGen.snippets.overlayTable {data = docData;});
          routingTable = pkgs.writeText "routing-table.md" (docGen.snippets.routingTable {});
          skillTable = pkgs.writeText "skill-table.md" (docGen.snippets.skillTable {data = docData;});
        } ''
          mkdir -p $out/snippets
          cp $aiMappingTable $out/snippets/ai-mapping-table.md
          cp $cliTable $out/snippets/cli-table.md
          cp $credentialsTable $out/snippets/credentials-table.md
          cp $overlayTable $out/snippets/overlay-table.md
          cp $routingTable $out/snippets/routing-table.md
          cp $skillTable $out/snippets/skill-table.md
        '';

      siteReference =
        pkgs.runCommand "docs-site-reference" {
          overlayPackages = pkgs.writeText "overlays-packages.md" (docGen.overlayPackages {data = docData;});
          inherit docsOptionsHm docsOptionsDevenv;
          mcpServers = pkgs.writeText "mcp-servers.md" (docGen.mcpServers {data = docData;});
          libApi = pkgs.writeText "lib-api.md" (docGen.libApi {});
          typesRef = pkgs.writeText "types.md" (docGen.typesRef {});
          aiMapping = pkgs.writeText "ai-mapping.md" (docGen.aiMapping {});
        } ''
          mkdir -p $out/{concepts,guides,reference}
          cp $overlayPackages $out/concepts/overlays-packages.md
          cp $docsOptionsHm $out/guides/home-manager.md
          cp $docsOptionsDevenv $out/guides/devenv.md
          cp $mcpServers $out/guides/mcp-servers.md
          cp $libApi $out/reference/lib-api.md
          cp $typesRef $out/reference/types.md
          cp $aiMapping $out/reference/ai-mapping.md
        '';

      siteCombined = pkgs.runCommand "docs-site" {} ''
        cp -r ${siteProse} $out
        chmod -R u+w $out
        mkdir -p $out/generated
        cp -r ${siteSnippets}/* $out/generated/
        cp -r ${siteReference}/concepts/* $out/concepts/
        cp -r ${siteReference}/guides/* $out/guides/
        mkdir -p $out/reference
        cp -r ${siteReference}/reference/* $out/reference/
      '';

      # NuschtOS options search — static client-side options browser.
      # Use default baseHref="/"; served under /options/ by copying into
      # the built doc site output directory.
      optionsSearch = inputs.nuscht-search.packages.${system}.mkMultiSearch {
        title = "nix-agentic-tools Options";
        scopes = [
          {
            name = "DevEnv";
            optionsJSON = optionsDocs.devenvOptionsDoc.optionsJSON + /share/doc/nixos/options.json;
            urlPrefix = "https://github.com/higherorderfunctor/nix-agentic-tools/tree/main/";
          }
          {
            name = "Home-Manager";
            optionsJSON = optionsDocs.hmOptionsDoc.optionsJSON + /share/doc/nixos/options.json;
            urlPrefix = "https://github.com/higherorderfunctor/nix-agentic-tools/tree/main/";
          }
        ];
      };
    in {
      # Documentation — generated doc site components
      docs-options-devenv = docsOptionsDevenv;
      docs-options-hm = docsOptionsHm;
      docs-options-search = optionsSearch;
      docs-site-prose = siteProse;
      docs-site-reference = siteReference;
      docs-site-snippets = siteSnippets;
      docs-site = siteCombined;

      # Documentation — built book with Pagefind and NuschtOS options search
      docs =
        pkgs.runCommand "nix-agentic-tools-docs" {
          nativeBuildInputs = [pkgs.gnused pkgs.mdbook pkgs.pagefind];
          src = ./docs;
          site = siteCombined;
          inherit optionsSearch;
        } ''
          cp -r $src docs
          chmod -R u+w docs
          rm -rf docs/src
          cp -r $site docs/src
          chmod -R u+w docs/src
          mdbook build docs
          # Embed NuschtOS options search at /options/
          cp -rL $optionsSearch result-docs/options
          chmod -R u+w result-docs/options
          sed -i 's|<base href="/">|<base href="/options/">|g' \
            result-docs/options/index.html \
            result-docs/options/index.csr.html
          # Build Pagefind full-text search index
          pagefind --site result-docs
          mv result-docs $out
        '';

      # AI CLIs
      inherit (pkgs) claude-code github-copilot-cli kiro-cli kiro-gateway;
      # Content packages
      inherit (pkgs) coding-standards fragments-ai fragments-docs stacked-workflows-content;
      # Git tools
      inherit (pkgs) agnix git-absorb git-branchless git-revise;

      # README derivation (from dev/generate.nix)
      repo-readme = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
      in
        pkgs.writeText "README.md" gen.readmeMd;

      # CONTRIBUTING.md derivation (from dev/generate.nix)
      repo-contributing = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
      in
        pkgs.writeText "CONTRIBUTING.md" gen.contributingMd;

      # Instruction derivations (from dev/generate.nix)
      instructions-agents = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
      in
        pkgs.writeText "AGENTS.md" gen.agentsMd;

      instructions-claude = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
        files =
          {"CLAUDE.md" = gen.claudeMd;}
          // lib.mapAttrs' (name: content:
            lib.nameValuePair "rules/${name}" content)
          gen.claudeFiles;
      in
        pkgs.runCommand "instructions-claude" {} (
          "mkdir -p $out/rules\n"
          + lib.concatStringsSep "\n" (lib.mapAttrsToList (name: content: "cp ${pkgs.writeText (baseNameOf name) content} $out/${name}")
            files)
        );

      instructions-copilot = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
        files = lib.mapAttrs' (name: content:
          lib.nameValuePair (
            if name == "copilot-instructions.md"
            then name
            else "instructions/${name}"
          )
          content)
        gen.copilotFiles;
      in
        pkgs.runCommand "instructions-copilot" {} (
          "mkdir -p $out/instructions\n"
          + lib.concatStringsSep "\n" (lib.mapAttrsToList (name: content: "cp ${pkgs.writeText (baseNameOf name) content} $out/${name}")
            files)
        );

      instructions-kiro = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
      in
        pkgs.runCommand "instructions-kiro" {} (
          "mkdir -p $out\n"
          + lib.concatStringsSep "\n" (lib.mapAttrsToList (name: content: "cp ${pkgs.writeText name content} $out/${name}")
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
