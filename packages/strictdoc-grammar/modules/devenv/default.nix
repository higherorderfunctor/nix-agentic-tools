# `ai.strictdoc` — the devenv module that owns strictdoc's wrapping and, through
# `grammars`, the route by which a `.sgra` file is generated.
# (MECH-STRICTDOC-DEVENV-MODULE, docs/plans/strictdoc-tooling/99-backlog.sdoc.)
#
# Named for the TOOL, not the milestone: `ai.strictdoc`, never
# `ai.strictdocGrammar`. The grammar surface is one thing this module
# configures, not what it is.
#
# ── Deliberate exclusions, both ruled rather than overlooked ─────────────────
#
# HOME MANAGER IS OUT OF SCOPE. There is therefore no `../options.nix` shared
# between two facets the way glab and beads have one: a single consumer is not a
# duplication, and splitting the declarations now would be an abstraction with
# nothing on the other side of it. If an HM facet lands, the split lands with
# it.
#
# NOT REGISTERED IN THE PACKAGE BARREL, and that is load-bearing rather than an
# omission. `packages/*/default.nix` exposing `modules.devenv` feeds
# `flake.devenvModules.nix-agentic-tools`, which `checks/options-doc.nix` diffs
# option-name for option-name against `flake.homeManagerModules.default`. A
# devenv-only `ai.*` namespace fails that gate by construction. devenv.nix
# imports this directory directly instead, which is what "this repository's
# convention" means here — see MECH-STRICTDOC-DEVENV-MODULE-NOT-PUBLISHED.
#
# ── What this module does NOT do yet ────────────────────────────────────────
#
# It renders each declared grammar and names the file that grammar belongs in.
# NOTHING WRITES THAT FILE. Wiring the write is a later step, because the
# generators' output shape is changing in parallel; until then `grammars.<name>`
# is the path by which `docs/sdoc/grammar.sgra` WOULD be generated, and
# `check:sdoc-grammar` still renders to a temporary file and diffs.
#
# Consequence worth stating, because it is the one thing that can rot here
# unnoticed: `target` is declared and read by nothing. It exists so the step
# that wires the write has one place to take the destination from rather than
# inventing a second convention for it.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;

  cfg = config.ai.strictdoc;

  # The typed `.sgra` surface. `render` is the whole chain — DSL values in,
  # `.sgra` source text out, with `check.elements` in between — and is the only
  # entry point that cannot skip the type check.
  grammar = import ../../lib {inherit lib;};

  # The generation-time runner. The wrap used to live in
  # overlays/dev-tools/strictdoc-grammar-extract.nix; see the header of
  # ../../lib/mkExtract.nix for why it moved here.
  extract = import ../../lib/mkExtract.nix {
    inherit lib pkgs;
    strictdoc = cfg.package;
  };
in {
  options.ai.strictdoc = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install strictdoc in the project's dev shell, together with the
        generation-time runner its `.sgra` grammar surface is extracted and
        rendered through.

        Home Manager is deliberately out of scope: strictdoc here is a
        project's document toolchain, not a user-global one.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.ai.devTools.strictdoc;
      defaultText = lib.literalExpression "pkgs.ai.devTools.strictdoc";
      description = ''
        The strictdoc package to install and to build the extractor's
        environment from.

        OVERRIDING THIS IS UNSAFE, and knowingly so. The two generated layers
        of the option surface (`lib/faithful.nix`, `lib/normalized.nix`) are
        extracted from one strictdoc release's own grammar string, so a package
        speaking a different grammar type-checks values against a grammar
        nothing is running. `checks/strictdoc-grammar-surface-current.nix` is
        what notices; it is a check, not a constraint on this option.
      '';
    };

    grammars = mkOption {
      default = {};
      description = ''
        Grammar files this project generates, keyed by name. The intended way
        to configure this module, and the route by which a `.sgra` file gets
        written.

        Values are declared with the NORMALIZED type rather than as bare
        attribute sets. That is the whole guarantee: the DSL in
        `packages/strictdoc-grammar/lib/dsl.nix` is sugar and asserts nothing
        by itself, so a consumer handing its output straight to the emitter
        passes through no type at all. Declaring the input here is what closes
        that (MECH-DSL-CHECKS-NOTHING-BY-ITSELF).

        Rendering happens at evaluation. WRITING DOES NOT HAPPEN YET — see the
        header of this file.
      '';
      example = lib.literalExpression ''
        {
          repo = {
            target = "docs/sdoc/grammar.sgra";
            elements = import ./packages/strictdoc-grammar/values.nix {
              inherit (grammar) dsl;
            };
          };
        }
      '';
      type = types.attrsOf (types.submodule ({
        config,
        name,
        ...
      }: {
        options = {
          elements = mkOption {
            type = types.nonEmptyListOf grammar.normalized.types.GrammarElement;
            description = ''
              The `[GRAMMAR]` block's elements, in order. A list and not an
              attribute set: strictdoc enforces element order and Nix sorts
              attribute-set keys, which would silently reorder the emitted
              file.
            '';
          };

          target = mkOption {
            type = types.str;
            default = name;
            defaultText = lib.literalMD "the attribute name";
            description = ''
              Path, relative to the project root, that this grammar belongs in.

              Nothing writes it yet. It is declared now so the later step that
              wires the write has one place to read the destination from,
              rather than inventing a second convention for it.
            '';
          };

          rendered = mkOption {
            type = types.str;
            internal = true;
            readOnly = true;
            default = grammar.render config.elements;
            defaultText = lib.literalMD "the rendered `.sgra` source text";
            description = ''
              The `.sgra` source text for this grammar, rendered through
              `grammar.render` — which runs the values back through the
              normalized surface before the emitter sees them, so the emitter
              never receives a value the types did not fill in.

              SOURCE TEXT, not a derivation, and that is what lets a check
              compare it: a `writeText` here would put the rendered bytes
              behind a build, so nothing could read them back at evaluation.
              The step that wires the write can call `writeText` on this; the
              reverse is not available.
            '';
          };
        };
      }));
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [
      cfg.package
      extract
    ];
  };
}
