# Copilot's app record: github.com Copilot, the cloud agent and code review
# that read a repository's committed tree.
#
# One record carries two option namespaces. `ai.copilot.github` holds the
# pools github.com reads: context (the shared AGENTS.md) and rules
# (`.github/instructions/`). Agents and skills declare gaps below.
# `ai.copilot.cli` is reserved for the Copilot CLI's
# launcher, which this module does not ship: the record has no package, so
# the launcher namespace declares nothing and `ai.copilot.enable` is the
# switch. The copilot-cli package itself stays in `packages/`.
#
# Only devenv writes. Home Manager keeps the same option tree, so a value set
# there warns instead of vanishing: github.com reads no HOME. Every surface
# github.com cannot take from a repository file is declared with
# `backends = []` and the reason, so the shared registry warns with it.
#
# What github.com reads, per product, is in
# dev/fragments/ai-clis/copilot-config-delivery.md.
{
  lib,
  pkgs,
  ...
}: let
  aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
  docs = path: "https://docs.github.com/en/copilot/${path}";
  homeManagerReason = surface: "github.com Copilot reads ${surface} from a repository's committed tree, and Home Manager has no repository to write. Configure it through the devenv module. See ${docs "reference/custom-instructions-support"}.";
  # Where each unit lands, shared by the staged entries and `contentTargets`.
  instructionPath = cfg: name: "${cfg.github.projectDir}/instructions/${name}.instructions.md";
in
  lib.ai.app.mkRuntime {
    # Carried as DATA, not a module argument — see mkRuntime.nix.
    inherit pkgs;
    name = "copilot";
    optionNamespaces = {
      launcher = ["cli"];
      pools = ["github"];
    };
    contextFilename = "AGENTS.md";
    contextDescription = ''
      Copilot-specific context appended after `ai.context`. Devenv contributes
      it to the repository `AGENTS.md`, which github.com's cloud agent and code
      review read from the root; Codex and Kiro write the same file, and their
      shared contributions must agree byte for byte. Home Manager declares the
      option and warns when it is non-empty. When `text` and `source` are
      defined at different module priorities, the higher-priority definition
      supplies the content whichever field it targets; definitions at the same
      priority conflict. Same-priority `text` definitions concatenate in module
      order. Set `enable = false` to omit this context.
    '';
    rulesDescription = ''
      Copilot-specific rules replace top-level `ai.rules` entries at the same
      key; set `enable = false` to suppress an inherited rule. Same-priority
      `text` definitions concatenate in module order. Devenv writes each as
      `<projectDir>/instructions/<name>.instructions.md`, its `applyTo` from
      the rule's scopes; Home Manager declares the option and warns when it is
      non-empty.
    '';
    surfaceSupport = {
      agents = {
        backends = [];
        reason = "github.com code review never reads .github/agents.";
      };
      context = {
        backends = ["devenv"];
        reason = homeManagerReason "AGENTS.md";
      };
      environmentVariables = {
        backends = [];
        reason = "github.com Copilot reads no environment variables from repository files; the cloud agent's environment comes from .github/workflows/copilot-setup-steps.yml and the repository's Copilot secrets and variables. See ${docs "how-tos/use-copilot-agents/cloud-agent/customize-the-agent-environment"}.";
      };
      hooks = {
        backends = [];
        reason = "github.com Copilot code review runs no hooks, and the cloud agent reads only .github/hooks/*.json from the default branch, bash entries only, which this module does not write. See ${docs "how-tos/use-copilot-agents/cloud-agent/use-hooks"}.";
      };
      mcpServers = {
        backends = [];
        reason = "github.com Copilot takes MCP servers from the repository's Copilot settings on github.com, not from a file; the only file-borne MCP is `mcp-servers` inside a custom agent profile, which this module does not write. See ${docs "how-tos/use-copilot-agents/cloud-agent/extend-cloud-agent-with-mcp"}.";
      };
      rules = {
        backends = ["devenv"];
        reason = homeManagerReason "path-specific instructions";
      };
      settings = {
        backends = [];
        reason = "github.com Copilot reads no settings file from a repository; its model and review options are repository and organization settings on github.com. See ${docs "reference/customization-cheat-sheet"}.";
      };
      shell = {
        backends = [];
        reason = "github.com Copilot runs in GitHub's cloud environment, set up by .github/workflows/copilot-setup-steps.yml; a repository file cannot select its shell. See ${docs "how-tos/use-copilot-agents/cloud-agent/customize-the-agent-environment"}.";
      };
      skills = {
        backends = [];
        reason = "github.com Copilot reads committed skills, where Nix store symlinks dangle, and this module does not copy skill trees. Commit real files under .github/skills instead. See ${docs "how-tos/use-copilot-agents/cloud-agent/create-skills"}.";
      };
    };
    options.github.projectDir = lib.mkOption {
      type = lib.types.str;
      default = ".github";
      description = ''
        Directory github.com Copilot reads instructions from,
        relative to the devenv root. Home Manager has no project root
        and rejects overrides.
      '';
    };
    config = {
      backend,
      cfg,
      mergedRules,
      ...
    }:
      lib.mkMerge [
        # Declared on Home Manager for option parity only; a project-relative
        # path has no honest meaning there.
        (lib.optionalAttrs (backend == "hm") {
          assertions = [
            {
              assertion = cfg.github.projectDir == ".github";
              message = ''
                ai.copilot.github.projectDir is project-local and cannot be
                changed through Home Manager. Configure it through the devenv
                module.
              '';
            }
          ];
        })
        (lib.optionalAttrs (backend == "devenv") {
          # github.com reads the COMMITTED tree, where a store symlink
          # dangles, so instruction files are read-only copies.
          ai.copilot._generatedFiles =
            lib.mapAttrs (_path: text: {
              content = {inherit text;};
              format = "markdown";
              method = "ro";
              surface = "rules";
            }) (aiCommon.renderRules {
              path = instructionPath cfg;
              rules = mergedRules;
              runtime = "copilot";
              transformer = lib.ai.transformers.copilot.copilotTransformer;
            });
        })
      ];
    # The context joins the repository AGENTS.md through its one owner.
    sharedAgentsMd = {cfg, ...}: {key = cfg.github.context.filename;};
    # Home Manager writes nothing, so nothing there can be switched off.
    contentTargets = {
      backend,
      cfg,
      mergedRules,
      ...
    }:
      lib.optionalAttrs (backend == "devenv") {
        context = cfg.github.context.filename;
        rules = lib.mapAttrs (name: _rule: instructionPath cfg name) mergedRules;
      };
    # The old writer's directory ledgers, declared while Copilot is disabled
    # too, so the copies it wrote drain on a disable as well as on N→0. The
    # agents ledger outlives its surface: it retires the profiles the old
    # writer left in `<projectDir>/agents` on the first upgrade.
    migrationConfig = {
      backend,
      cfg,
      ...
    }:
      lib.optionalAttrs (backend == "devenv") {
        ai.copilot.legacyLedgers =
          lib.mapAttrsToList (dir: ledger: {
            codec = "dir";
            inherit ledger;
            path = "${cfg.github.projectDir}/${dir}";
          }) {
            agents = "materialize/copilot-github-agents.manifest";
            instructions = "materialize/copilot-instructions.manifest";
          };
      };
  }
