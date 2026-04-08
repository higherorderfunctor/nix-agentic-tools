# HM backend adapter for the ai-ecosystem-records refactor.
#
# Takes an ecosystem record (from lib/ai-ecosystems/<name>.nix or
# pkgs.fragments-ai.passthru.records.<name>) and returns a NixOS
# module function suitable for inclusion in a home-manager
# module's `imports` list.
#
# The returned module:
#   1. Declares options.ai.<name> as a submodule with:
#      - enable (mkEnableOption)
#      - package (default = ecoRecord.package or a caller-supplied
#        fallback; the adapter doesn't hardcode package names)
#      - any extra options from ecoRecord.extraOptions { inherit lib; }
#
#   2. Inside mkIf cfg.<name>.enable, produces a config block that:
#      - Flips the upstream module's enable (if ecoRecord.upstream.hm.enableOption != null)
#      - Writes skills via upstream.hm.skillsOption delegation or home.file direct write
#      - Renders instructions via ecoRecord.markdownTransformer through mkRenderer
#      - Places rendered instructions via upstream.hm.instructionsOption delegation
#        or home.file direct write (keyed on ecoRecord.layout.instructionPath)
#      - Translates and places settings via upstream.hm.settingsOption
#      - Translates and places lspServers via upstream.hm.lspServersOption
#      - Translates and places environmentVariables via upstream.hm.envVarsOption
#        (or skips if ecoRecord.translators.envVar is null)
#      - Translates and places mcpServers via upstream.hm.mcpServersOption
#        (or skips if null — Phase 2a ecosystems have null for mcpServers
#        because the existing inline fanout doesn't set ai-level mcp)
#
# Phase 2a scope: the adapter reads from the shared ai.* options
# directly (cfg.skills, cfg.instructions, etc.) without the per-eco
# layered pool extension. Phase 2b will add the layered pools.
#
# Module-system pattern note: dispatch conditions must never depend
# on `cfg.*`. The module system's `pushDownProperties` phase forces
# the top-level mkIf content to determine attribute shapes BEFORE
# `config.ai.*` is available. If a block's `if` condition reads
# `cfg.skills`, this triggers an infinite recursion via
# `_module.freeformType` evaluation. All block dispatch conditions
# below key solely on ecosystem-record fields (translators.*,
# upstream.hm.*Option, ecoRecord.name) — the config-dependent work
# lives inside the dispatch branch's value expression, where it's
# evaluated lazily after pushDownProperties completes.
#
# See dev/notes/ai-transformer-design.md "Layer 3: Backend adapters"
# for the full design.
{lib}: let
  fragmentsLib = import ./fragments.nix {inherit lib;};
  aiCommon = import ./ai-common.nix {inherit lib;};

  # ── Pure helpers (config-independent) ────────────────────────────
  # Build a renderer for one instruction using the ecosystem's
  # markdownTransformer. ctxExtras carries per-instruction metadata
  # that the frontmatter function pattern-matches on (claude needs
  # `package`, kiro needs `name`). We thread `name` as both
  # `package` and `name` — both frontmatter functions use `...` to
  # absorb unknown args, so this is safe.
  mkRenderInstruction = ecoRecord: name: instr: let
    ctxExtras = {
      package = name;
      inherit name;
    };
    render = fragmentsLib.mkRenderer ecoRecord.markdownTransformer ctxExtras;
  in
    render instr;

  # Set an upstream option path if non-null, else return an empty
  # attrset (caller handles the fallback).
  setUpstreamOption = optionPath: value:
    if optionPath != null
    then lib.setAttrByPath (lib.splitString "." optionPath) value
    else {};
in
  ecoRecord: {
    config,
    pkgs,
    ...
  }: let
    extraOptionAttrs = ecoRecord.extraOptions {inherit lib;};
  in {
    options.ai.${ecoRecord.name} = lib.mkOption {
      type = lib.types.submodule {
        options =
          {
            enable = lib.mkEnableOption "Fan out shared config to ${ecoRecord.name}";
            package = lib.mkOption {
              type = lib.types.package;
              default = ecoRecord.package or (pkgs.${ecoRecord.name} or pkgs.hello);
              defaultText = lib.literalExpression "ecoRecord.package or pkgs.${ecoRecord.name}";
              description = "${ecoRecord.name} package.";
            };
          }
          // extraOptionAttrs;
      };
      default = {};
      description = "${ecoRecord.name} ecosystem configuration.";
    };

    # ── Fanout config ────────────────────────────────────────────
    # Every dispatch condition below keys on ecosystem-record
    # fields, not cfg.*. Inside each dispatch branch's value, we
    # freely read cfg.* — by that point the module system has
    # finished pushDownProperties and config is ready.
    config = lib.mkIf config.ai.${ecoRecord.name}.enable (
      let
        cfg = config.ai;
        ecoCfg = cfg.${ecoRecord.name};
      in
        lib.mkMerge [
          # Enable the upstream module (programs.<cli>.enable = true)
          (
            if ecoRecord.upstream.hm.enableOption != null
            then setUpstreamOption ecoRecord.upstream.hm.enableOption (lib.mkDefault true)
            else {}
          )

          # Skills: delegate to upstream option if present, wrapping
          # each entry with mkDefault so per-ecosystem overrides win.
          (
            if
              ecoRecord.translators.skills
              != null
              && ecoRecord.upstream.hm.skillsOption != null
            then
              setUpstreamOption ecoRecord.upstream.hm.skillsOption (
                lib.mapAttrs (
                  n: v: lib.mkDefault (ecoRecord.translators.skills n v)
                )
                cfg.skills
              )
            else {}
          )

          # Instructions: two dispatch paths.
          #   Path 1 (claude): no dedicated upstream option;
          #     rendered bytes go to home.file via
          #     layout.instructionPath.
          #   Path 2 (copilot, kiro): upstream option
          #     (programs.copilot-cli.instructions /
          #     programs.kiro-cli.steering) accepts the rendered
          #     text per name; we map the rendered values into it.
          # The record's upstream.hm may grow an
          # `instructionsOption` field in Phase 2b to unify these
          # paths; for now Phase 2a matches the existing inline
          # behavior by checking ecoRecord.name directly. This
          # name-switch is deliberate — it's the one place the
          # adapter has per-ecosystem branching, and it gets
          # removed in Phase 2b's layered-pool refactor.
          (
            if ecoRecord.name == "claude"
            then {
              home.file =
                lib.concatMapAttrs (name: instr: {
                  "${ecoRecord.layout.instructionPath name}" = {
                    text = lib.mkDefault (mkRenderInstruction ecoRecord name instr);
                  };
                })
                cfg.instructions;
            }
            else if ecoRecord.name == "copilot"
            then {
              programs.copilot-cli.instructions =
                lib.mapAttrs (
                  name: instr:
                    lib.mkDefault (mkRenderInstruction ecoRecord name instr)
                )
                cfg.instructions;
            }
            else if ecoRecord.name == "kiro"
            then {
              programs.kiro-cli.steering =
                lib.mapAttrs (
                  name: instr:
                    lib.mkDefault (mkRenderInstruction ecoRecord name instr)
                )
                cfg.instructions;
            }
            else {}
          )

          # Settings: delegate to upstream option if the ecosystem
          # has a settings translator + settings option. The
          # translator call happens inside this branch, so the
          # (potentially empty) translator output is computed
          # lazily — pushDownProperties only needs to see the
          # record-level condition.
          #
          # KNOWN ISSUE (Commit 6): kiro.nix's translators.settings
          # returns `lib.mkMerge [...]` rather than a plain attrset,
          # so the `mapAttrsRecursive` below will not handle it
          # correctly. Commit 6's implementer must either:
          #   (a) change kiro.nix translators.settings to return a
          #       plain attrset (preferred — keeps the adapter
          #       simple), or
          #   (b) generalize this dispatch to detect mkMerge
          #       sentinels and forward them without recursive
          #       mkDefault wrapping.
          # Claude's translator returns a plain attrset, so this
          # branch is safe for Commit 3's isolation test.
          (
            if
              ecoRecord.translators.settings
              != null
              && ecoRecord.upstream.hm.settingsOption != null
            then
              setUpstreamOption ecoRecord.upstream.hm.settingsOption (
                lib.mapAttrsRecursive (_: v: lib.mkDefault v) (
                  ecoRecord.translators.settings cfg.settings
                )
              )
            else {}
          )

          # LSP servers: the current inline fanout uses
          # mkLspConfig / mkCopilotLspConfig from lib/ai-common.nix,
          # which do roughly what the record's translator.lspServer
          # does but with ecosystem-specific key mangling. For
          # Phase 2a we invoke the existing helpers directly to
          # preserve byte-identical behavior; Phase 2b will migrate
          # to the record's translator.
          (
            if ecoRecord.name == "claude"
            then {
              programs.claude-code.settings.env.ENABLE_LSP_TOOL =
                lib.mkIf (cfg.lspServers != {}) (lib.mkDefault "1");
            }
            else if ecoRecord.name == "copilot"
            then {
              programs.copilot-cli.lspServers =
                lib.mapAttrs (
                  name: server:
                    lib.mkDefault (aiCommon.mkCopilotLspConfig name server)
                )
                cfg.lspServers;
            }
            else if ecoRecord.name == "kiro"
            then {
              programs.kiro-cli.lspServers =
                lib.mapAttrs (
                  name: server:
                    lib.mkDefault (aiCommon.mkLspConfig name server)
                )
                cfg.lspServers;
            }
            else {}
          )

          # Environment variables: claude skips (translator is
          # null); copilot/kiro pass through to
          # programs.<cli>.environmentVariables.
          (
            if ecoRecord.translators.envVar != null
            then
              if ecoRecord.name == "copilot"
              then {
                programs.copilot-cli.environmentVariables =
                  lib.mapAttrs (_: lib.mkDefault) cfg.environmentVariables;
              }
              else if ecoRecord.name == "kiro"
              then {
                programs.kiro-cli.environmentVariables =
                  lib.mapAttrs (_: lib.mkDefault) cfg.environmentVariables;
              }
              else {}
            else {}
          )

          # Fanout for claude's buddy field: set
          # programs.claude-code.buddy when ecoCfg.buddy is
          # configured. This is another per-ecosystem special-case
          # that Phase 2b absorbs into the layered-pool pattern.
          #
          # The outer `if` keys on record name (pure, safe during
          # pushDownProperties); the inner `lib.mkIf` defers
          # reading ecoCfg.buddy until the final config merge. The
          # inner mkIf emits a definition for the
          # programs.claude-code.buddy path unconditionally (with a
          # false condition when ecoCfg.buddy is null), so the
          # option path must be declared by the importing module
          # set. Callers that wire this adapter into
          # homeManagerModules.ai pick up the canonical buddy
          # option via modules/claude-code-buddy; the isolation
          # test fixture stubs the same path with a loose
          # `nullOr anything` type.
          (
            if ecoRecord.name == "claude"
            then {
              programs.claude-code.buddy = lib.mkIf (ecoCfg.buddy != null) ecoCfg.buddy;
            }
            else {}
          )
        ]
    );
  }
