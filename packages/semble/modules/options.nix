{
  lib,
  pkgs,
}: let
  contentScope = import ../lib/contentScope.nix {inherit lib;};
  runtimeType = lib.types.enum ["claude" "codex" "kiro"];
  runtimeListType = lib.types.listOf runtimeType;

  runtimesOption = description:
    lib.mkOption {
      type = lib.types.nullOr runtimeListType;
      default = null;
      description = "AI runtimes receiving the Semble ${description}; null inherits `semble.runtimes`.";
    };

  # Two `enable` flavours, and which one a feature gets is a deliberate
  # statement about that feature rather than a style choice.
  #
  # INHERITED (nullable, null = follow `semble.enable`) is for the integration
  # a bare `semble.enable = true` is understood to mean: the MCP server.
  #
  # OPT-IN (plain bool, default false, NO inheritance) is for integrations that
  # deliver the same guidance through a second channel. Both of them used to
  # inherit, so `semble.enable = true` shipped CLI guidance into the
  # always-loaded context AND a named agent whose body was that same guidance —
  # a session carrying the agent carried the whole text twice. Making them
  # opt-in is what removes that duplication, and it is a BREAKING behaviour
  # change: a configuration that set only `semble.enable = true` loses both.
  inheritedFeature = description: {
    enable = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether to enable the Semble ${description}; null inherits `semble.enable`.";
    };
    runtimes = runtimesOption description;
  };

  optInFeature = description: {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable the Semble ${description}. This does NOT inherit
        `semble.enable` — it defaults to `false` even when Semble is enabled,
        and must be requested explicitly.
      '';
    };
    runtimes = runtimesOption description;
  };
in {
  options.semble = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable Semble's MCP integration. This installs the package
        and, unless overridden, the MCP server.

        It deliberately does NOT enable the global CLI instructions
        (`semble.instructions.cli.enable`) or the named subagent
        (`semble.subagent.enable`); both are explicit opt-ins.
      '';
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.ai.semble;
      defaultText = lib.literalExpression "pkgs.ai.semble";
      description = "Semble package installed when at least one selected integration is active.";
    };
    runtimes = lib.mkOption {
      type = runtimeListType;
      default = ["claude" "codex" "kiro"];
      description = "AI runtimes receiving enabled Semble integrations.";
    };

    # Namespaced under `cli` because the CLI is one access path among several.
    # An MCP-backed session reaches Semble through tools rather than a shell,
    # and the named subagent carries its own prompt, so global CLI guidance is
    # useful precisely when the ROOT session should shell out to `semble`.
    instructions.cli = optInFeature "CLI instructions";

    mcp =
      inheritedFeature "MCP server"
      // {
        content = lib.mkOption {
          inherit (contentScope) type default description;
        };

        # Defining the server and handing it to the root session are separate
        # questions. Setting this false defines the server for agents to claim
        # without registering it in the root session's own MCP pool.
        rootExposure = lib.mkOption {
          type = lib.types.nullOr lib.types.bool;
          default = null;
          description = ''
            Whether the configured Semble MCP server is registered in the root
            session; null inherits `semble.mcp.enable`.

            Setting this to `false` requires a runtime that can attach an MCP
            server to a named agent in isolation from the root session. Only
            Kiro can: its agent files carry their own `mcpServers` map and
            default to excluding the global pool. Claude, Copilot, and Codex
            cannot, and selecting that combination is an evaluation error
            rather than a silent fallback to a root-visible server.
          '';
        };
      };

    subagent =
      optInFeature "semantic search subagent"
      // {
        interface = lib.mkOption {
          type = lib.types.enum ["cli" "mcp"];
          default = "cli";
          description = ''
            Which access path the named subagent uses.

            `cli` gives it the shell-oriented prompt and each runtime's
            shell/read tools. `mcp` gives it the tool-oriented prompt and
            restricts it to Semble's MCP tools, which requires
            `semble.mcp` to be enabled for the same runtime.

            This is scalar: one named agent is generated, so the two prompts
            cannot both occupy the `semble-search` name. Wiring a second,
            differently-named agent is a direct-configuration job using the
            exported `lib.ai.semble.*` records.
          '';
        };
      };
  };
}
