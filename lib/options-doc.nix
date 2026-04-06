# Generate options documentation from module definitions.
#
# Uses nixosOptionsDoc to produce markdown from actual NixOS-style module
# option definitions. Two entry points: mkHmOptionsDocs (home-manager
# modules) and mkDevenvOptionsDocs (devenv modules).
#
# Consumed by flake.nix to produce docs-options-hm and docs-options-devenv
# derivations, which are then wired into the doc site.
{
  lib,
  pkgs,
  self,
}: let
  repoUrl = "https://github.com/nix-community/nix-agentic-tools/blob/main";

  # ── Declaration path cleanup ────────────────────────────────────────
  # Module declarations point to nix store paths or absolute local paths.
  # Rewrite them to relative repo paths with GitHub URLs.
  cleanDecl = decl: let
    str = toString decl;

    # Try to extract a repo-relative path by splitting on known prefixes.
    # Returns the first match or null.
    tryExtract = sep: let
      parts = lib.splitString sep str;
    in
      if builtins.length parts > 1
      then sep + lib.last parts
      else null;

    candidates = map tryExtract ["/modules/" "/lib/" "/packages/"];
    matches = builtins.filter (x: x != null) candidates;
    relative =
      if matches != []
      then builtins.head matches
      else null;
  in
    if relative != null
    then {
      name = lib.removePrefix "/" relative;
      url = "${repoUrl}${relative}";
    }
    else {
      name = str;
      url = str;
    };

  # ── Shared transformOptions ─────────────────────────────────────────
  # Filters options to only show those matching the given prefixes,
  # and rewrites declaration paths to repo-relative GitHub URLs.
  mkTransformOptions = prefixes: opt:
    opt
    // {
      visible =
        opt.visible
        && builtins.any (p: lib.hasPrefix p opt.name) prefixes;
      declarations = map cleanDecl opt.declarations;
    };

  # ── HM stub module ─────────────────────────────────────────────────
  # Minimal stubs for home-manager interfaces that our modules reference.
  # These satisfy option lookups without importing all of home-manager.
  hmStubModule = {lib, ...}: {
    options = {
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
        description = "Module assertions.";
      };
      home = {
        activation = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
          description = "Activation scripts.";
        };
        file = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
          description = "Managed files.";
        };
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [];
          description = "User packages.";
        };
      };
      programs = {
        git.settings = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
          description = "Git configuration.";
        };
        mcp = {
          enable = lib.mkEnableOption "shared MCP server registry";
          servers = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = {};
            description = "Shared MCP server definitions.";
          };
        };
      };
      # Stub: upstream programs.claude-code (not defined in this repo)
      programs.claude-code = {
        enable = lib.mkEnableOption "Claude Code (upstream HM module)";
        settings = lib.mkOption {
          type = lib.types.submodule {
            freeformType = (pkgs.formats.json {}).type;
            options.model = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Claude Code model.";
            };
          };
          default = {};
          description = "Claude Code settings.";
        };
        skills = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
          description = "Claude Code skills.";
        };
      };
      systemd.user.services = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
        description = "Systemd user services.";
      };
    };
  };

  # ── Devenv stub module ──────────────────────────────────────────────
  devenvStubModule = {lib, ...}: {
    options = {
      claude.code = {
        enable = lib.mkEnableOption "Claude Code devenv integration";
        env = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "Claude Code environment variables.";
        };
        mcpServers = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
          default = {};
          description = "Claude Code MCP servers.";
        };
        model = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Claude Code model.";
        };
      };
      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Devenv environment variables.";
      };
      files = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
        description = "Devenv managed files.";
      };
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
        description = "Devenv packages.";
      };
    };
  };

  # ── HM options doc ──────────────────────────────────────────────────
  hmEval = lib.evalModules {
    modules = [
      self.homeManagerModules.default
      {
        config._module.args = {
          inherit pkgs;
          osConfig = {};
        };
      }
      hmStubModule
    ];
  };

  hmPrefixes = [
    "ai."
    "programs.copilot-cli."
    "programs.kiro-cli."
    "services.mcp-servers."
    "stacked-workflows."
  ];

  hmOptionsDoc = pkgs.nixosOptionsDoc {
    inherit (hmEval) options;
    warningsAreErrors = false;
    transformOptions = mkTransformOptions hmPrefixes;
  };

  # ── Devenv options doc ──────────────────────────────────────────────
  devenvEval = lib.evalModules {
    modules = [
      self.devenvModules.ai
      self.devenvModules.copilot
      self.devenvModules.kiro
      {
        config._module.args = {
          inherit pkgs;
        };
      }
      devenvStubModule
    ];
  };

  devenvPrefixes = [
    "ai."
    "copilot."
    "kiro."
  ];

  devenvOptionsDoc = pkgs.nixosOptionsDoc {
    inherit (devenvEval) options;
    warningsAreErrors = false;
    transformOptions = mkTransformOptions devenvPrefixes;
  };
in {
  inherit hmOptionsDoc devenvOptionsDoc;
}
