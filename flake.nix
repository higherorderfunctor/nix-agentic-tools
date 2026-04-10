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
    # NuschtOS options search — client-side search UI embedded at
    # /options/ in the built doc site. Generates a multi-scope
    # options browser from nixosOptionsDoc JSON output.
    nuscht-search = {
      url = "github:NuschtOS/search";
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
      "x86_64-linux"
    ];
    forAllSystems = lib.genAttrs supportedSystems;
    pkgsFor = system:
      import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [self.overlays.default];
      };
    # nvfetcher sources exposed on `final.nv-sources` per the
    # `dev/fragments/nix-standards/nix-standards.md` rule that
    # overlays must access nvfetcher sources via
    # `final.nv-sources.<key>` instead of importing
    # `generated.nix` directly. Compiled overlays then read
    # their own entry by name and merge in `hashes.json`
    # sidecar values for cargoHash etc. that nvfetcher can't
    # produce itself.
    nvSourcesOverlay = final: _prev: {
      nv-sources = import ./overlays/sources/generated.nix {
        inherit (final) fetchurl fetchgit fetchFromGitHub dockerTools;
      };
    };
    # Bind each overlay once so `overlays.<name>` and the
    # `overlays.default` composition share the same import.
    aiOverlay = import ./overlays {inherit inputs;};
    codingStandardsOverlay = import ./packages/coding-standards {};
    # Doc site generators — moved to devshell/docs-site/ in M10 but
    # restored as an overlay entry in M15 because the doc site build
    # (packages.docs) needs to read pkgs.fragments-docs.passthru.generators.
    fragmentsDocsOverlay = import ./devshell/docs-site {};
    stackedWorkflowsOverlay = import ./packages/stacked-workflows/overlay.nix {};

    # Barrel walker — collects non-binary facets from packages/*/default.nix.
    packagesBarrel = import ./packages;

    collectFacet = attrPath:
      lib.pipe packagesBarrel [
        (lib.filterAttrs (_: p: lib.hasAttrByPath attrPath p))
        (lib.mapAttrsToList (_: p: lib.getAttrFromPath attrPath p))
      ];

    packageLibContributions = lib.foldl' lib.recursiveUpdate {} (
      lib.mapAttrsToList (_: p: p.lib or {}) packagesBarrel
    );
  in {
    overlays = {
      ai = aiOverlay;
      coding-standards = codingStandardsOverlay;
      default = lib.composeManyExtensions [
        nvSourcesOverlay
        aiOverlay
        codingStandardsOverlay
        fragmentsDocsOverlay
        stackedWorkflowsOverlay
      ];
      fragments-docs = fragmentsDocsOverlay;
      stacked-workflows = stackedWorkflowsOverlay;
    };

    homeManagerModules.nix-agentic-tools = {
      imports =
        [./lib/ai/sharedOptions.nix]
        ++ collectFacet ["modules" "homeManager"];
    };

    devenvModules.nix-agentic-tools = {
      imports =
        [./lib/ai/sharedOptions.nix]
        ++ collectFacet ["modules" "devenv"];
    };

    lib = let
      fragments = import ./lib/fragments.nix {inherit lib;};
      devshellLib = import ./lib/devshell.nix {inherit lib;};
      mcpLib = import ./lib/mcp.nix {inherit lib;};
      ai = import ./lib/ai {inherit lib;};

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
      baseLib = {
        inherit ai fragments presets;
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
        # packages/stacked-workflows/modules/homeManager/git-config*.nix).
      };
    in
      lib.recursiveUpdate baseLib packageLibContributions;

    checks = forAllSystems (system: let
      pkgs = pkgsFor system;
      factoryChecks = import ./checks/factory-eval.nix {inherit lib pkgs;};
      fragmentsChecks = import ./checks/fragments-eval.nix {inherit lib pkgs;};
      moduleChecks = import ./checks/module-eval.nix {inherit lib pkgs;};
    in
      fragmentsChecks // factoryChecks // moduleChecks);

    # devShell provided by devenv CLI (devenv shell / devenv test)
    # See devenv.nix for shell configuration.

    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
      # Bind the fragment-composition data ONCE for all four
      # instruction-* derivations below. import is memoized so
      # the file is read once, but a single explicit binding is
      # clearer and cheaper to extend when a 5th ecosystem lands.
      gen = import ./dev/generate.nix {inherit lib pkgs;};

      # ── Doc site components ─────────────────────────────────────
      # Generator helpers ported from sentinel in M15. Composed into
      # the mdbook source tree under docs/src/ before `mdbook build`.
      docGen = pkgs.fragments-docs.passthru.generators;
      docData = import ./dev/data.nix {inherit lib;};

      # Options documentation generated from actual module definitions.
      # Walks homeManagerModules.nix-agentic-tools (the factory-built
      # merged module) and devenvModules.nix-agentic-tools via
      # nixosOptionsDoc to produce markdown + JSON.
      optionsDocs = import ./lib/options-doc.nix {inherit lib pkgs self;};

      # Assembled options pages: header + generated options + footer
      docsOptionsHm =
        pkgs.runCommand "docs-options-hm" {
          header = ./devshell/docs-site/pages/home-manager-header.md;
          optionsMd = optionsDocs.hmOptionsDoc.optionsCommonMark;
          footer = ./devshell/docs-site/pages/home-manager-footer.md;
        } ''
          cat $header > $out
          printf '\n' >> $out
          cat $optionsMd >> $out
          printf '\n' >> $out
          cat $footer >> $out
        '';

      docsOptionsDevenv =
        pkgs.runCommand "docs-options-devenv" {
          header = ./devshell/docs-site/pages/devenv-header.md;
          optionsMd = optionsDocs.devenvOptionsDoc.optionsCommonMark;
          footer = ./devshell/docs-site/pages/devenv-footer.md;
        } ''
          cat $header > $out
          printf '\n' >> $out
          cat $optionsMd >> $out
          printf '\n' >> $out
          cat $footer >> $out
        '';

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

      # Dev architecture fragments surfaced as mdbook contributing
      # pages. Same markdown source that feeds the scoped
      # .claude/rules, .github/instructions, and .kiro/steering files
      # — single source of truth across steering + docsite.
      siteArchitecture = pkgs.runCommand "docs-site-architecture" {} ''
        mkdir -p $out/contributing/architecture
        cp ${./dev/fragments/monorepo/architecture-fragments.md} \
          $out/contributing/architecture/architecture-fragments.md
        cp ${./dev/fragments/pipeline/fragment-pipeline.md} \
          $out/contributing/architecture/fragment-pipeline.md
        cp ${./dev/fragments/overlays/cache-hit-parity.md} \
          $out/contributing/architecture/overlay-cache-hit-parity.md
        cp ${./dev/fragments/hm-modules/module-conventions.md} \
          $out/contributing/architecture/hm-module-conventions.md
        cp ${./dev/fragments/ai-skills/skills-fanout-pattern.md} \
          $out/contributing/architecture/ai-skills-fanout-pattern.md
        cp ${./dev/fragments/devenv/files-internals.md} \
          $out/contributing/architecture/devenv-files-internals.md
        cp ${./packages/claude-code/docs/claude-code-wrapper.md} \
          $out/contributing/architecture/claude-code-wrapper.md
        cp ${./packages/claude-code/docs/buddy-activation.md} \
          $out/contributing/architecture/buddy-activation.md
        cp ${./dev/fragments/ai-module/ai-module-fanout.md} \
          $out/contributing/architecture/ai-module-fanout.md
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
        cp -r ${siteArchitecture}/* $out/
      '';

      # NuschtOS options search — static client-side options browser.
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
    in
      # Grouped namespaces (pkgs.ai.mcpServers.*, pkgs.ai.lspServers.*,
      # pkgs.gitTools.*) are flattened here for CLI ergonomics so
      # `nix build .#context7-mcp` works without knowing the group.
      # Adding a new package to the overlay automatically adds it
      # here; no flake.nix edit needed for new binaries.
      #
      # Legacy notes preserved for history:
      # - pkgs.nix-mcp-servers namespace dissolved in Milestone 5
      # - pkgs.{agnix,git-*} flat entries moved to pkgs.ai.* in Milestone 6
      # - github-copilot-cli renamed to copilot-cli in Milestone 4
      # - pkgs.ai.* grouped into mcpServers/lspServers/gitTools (factory arch)
      # Flat AI CLIs (strip nested groups which aren't derivations)
      builtins.removeAttrs pkgs.ai ["mcpServers" "lspServers"]
      // pkgs.ai.mcpServers
      // pkgs.ai.lspServers
      // pkgs.gitTools
      // {
        # Instruction file derivations (from dev/generate.nix).
        # Each ecosystem produces a content directory consumed by the
        # `generate:instructions:*` devenv tasks.
        instructions-agents = pkgs.writeText "AGENTS.md" gen.agentsMd;

        instructions-claude = let
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

        instructions-kiro = pkgs.runCommand "instructions-kiro" {} (
          "mkdir -p $out\n"
          + lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: content: "cp ${pkgs.writeText name content} $out/${name}"
            )
            gen.kiroFiles
          )
        );

        # ── Doc site outputs ────────────────────────────────────
        # Intermediate derivations exposed for debugging / inspection.
        # The top-level `docs` output is the built mdbook + NuschtOS
        # options browser + pagefind index.
        docs-options-devenv = docsOptionsDevenv;
        docs-options-hm = docsOptionsHm;
        docs-options-search = optionsSearch;
        docs-site-architecture = siteArchitecture;
        docs-site-prose = siteProse;
        docs-site-reference = siteReference;
        docs-site-snippets = siteSnippets;
        docs-site = siteCombined;

        # Documentation — built book with Pagefind and NuschtOS
        # options search embedded at /options/.
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
            # Favicon goes in theme/ for mdbook to pick up
            mkdir -p docs/theme
            cp docs/src/assets/favicon.png docs/theme/favicon.png
            mdbook build docs
            # Embed NuschtOS options search at /options/
            cp -rL $optionsSearch result-docs/options
            chmod -R u+w result-docs/options
            sed -i 's|<base href="/">|<base href="/nix-agentic-tools/options/">|g' \
              result-docs/options/index.html \
              result-docs/options/index.csr.html
            # Pagefind index
            pagefind --site result-docs
            mv result-docs $out
          '';
      });

    # Standard flake outputs for `nix develop` and `nix fmt`.
    # Primary dev workflow is `devenv shell` / `devenv test` via
    # devenv.nix; these outputs preserve flake UX for users who
    # prefer plain Nix CLI.
    # Primary dev shell is devenv (devenv.nix). This only provides
    # the lightweight CI shell for the update pipeline.
    devShells = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      ci = pkgs.mkShell {
        name = "nix-agentic-tools-ci";
        packages = with pkgs; [
          devenv
          jq
          nodejs
          nvfetcher
          prefetch-npm-deps
        ];
      };
    });

    formatter = forAllSystems (system: (pkgsFor system).alejandra);
  };
}
