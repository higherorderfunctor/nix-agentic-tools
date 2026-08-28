# `ai.strictdoc` — the devenv module that owns strictdoc's wrapping and, through
# `grammars`, the generation of a project's `.sgra` files.
# (MECH-STRICTDOC-DEVENV-MODULE,
# docs/plans/strictdoc-tooling/mech-strictdoc-devenv-module.sdoc.)
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
# ── `generate:sgra` WRITES the files, and what that does not oblige ─────────
#
# Each declared grammar is rendered at evaluation and written into the working
# tree by the `generate:sgra` task below. So in THIS repository
# `docs/sdoc/grammar.sgra` is a generated file: hand-editing it is drift, and
# `checks/strictdoc-grammar-model-equal.nix` is what notices.
#
# THAT IS A CONVENTION OF THIS REPOSITORY, NOT A RULE THE SURFACE IMPOSES.
# `packages/strictdoc-grammar` is general purpose and intended for publication,
# and the operator's 2026-08-27 ruling ("every sdoc grammar here is generated,
# by way of this module") binds this repository only. A consumer of the
# published surface may use this module, call `lib/default.nix`'s `render`
# directly, or hand-write the file; nothing in the library knows which.
#
# ── Why the write is its OWN task, with no edge into `generate:sdoc-grammar` ─
#
# `rendered` is an EVALUATION-time string. devenv evaluates the whole task graph
# before running any of it, so the bytes a task writes are fixed before the
# first task starts. Chaining the write behind `generate:sdoc-grammar:normalized`
# would therefore write the grammar rendered from the normalized surface that
# existed when the run BEGAN — silently, in precisely the run that regenerated
# it. Two invocations, deliberately: regenerate the surface, then write the
# files. Nothing here references a task defined outside this module, which also
# keeps the module importable by a project that has no such tasks.
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

  # `sdoc` — SLICE-SDOC-CLI's entry point. Takes the runner above rather than
  # deriving a second interpreter; see ../../lib/mkSdocCli.nix for why the
  # script itself is resolved at run time instead of being baked in.
  sdocCli = import ../../lib/mkSdocCli.nix {
    inherit lib pkgs;
    runner = extract;
  };

  # Store paths rather than bare names: `generate:sgra` is a plain script and
  # must not depend on what happens to be on the caller's PATH. `cmp` ships in
  # diffutils, NOT coreutils — getting that wrong here would fail silently, in
  # an `if` condition where a missing binary is just a false branch.
  cu = "${pkgs.coreutils}/bin";
  du = "${pkgs.diffutils}/bin";

  # One `write_sgra` call per declared grammar. The rendered text goes through
  # the store rather than a heredoc so no quoting of the grammar's own bytes is
  # involved.
  writeCall = name: g: ''
    write_sgra ${pkgs.writeText "${name}.sgra" g.rendered} ${lib.escapeShellArg g.target}
  '';
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
        written: `devenv tasks run generate:sgra` writes every entry to its
        `target`.

        Values are declared with the NORMALIZED type rather than as bare
        attribute sets. That is the whole guarantee: the DSL in
        `packages/strictdoc-grammar/lib/dsl.nix` is sugar and asserts nothing
        by itself, so a consumer handing its output straight to the emitter
        passes through no type at all. Declaring the input here is what closes
        that (MECH-DSL-CHECKS-NOTHING-BY-ITSELF).

        Rendering happens at evaluation; writing happens in a separate task
        invocation, and the header of this file says why it cannot be the same
        one.
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
              Path, relative to the project root, this grammar is written to by
              `generate:sgra`. Interpreted against `$DEVENV_ROOT`, because a
              task's default working directory is the caller's and direnv
              activates in subdirectories.
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
              `generate:sgra` calls `writeText` on this itself; the reverse is
              not available.
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
      sdocCli
    ];

    # Declared even when `grammars` is empty, so `devenv tasks list` shows the
    # route rather than making its absence look like a missing feature. With no
    # grammars the body is just the helper definition and the task is a no-op.
    tasks."generate:sgra" = {
      description = "Write the .sgra grammar files declared in ai.strictdoc.grammars";
      exec = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        # A task's default cwd is the caller's, and direnv activates in
        # SUBDIRECTORIES, so a relative `target` has to be anchored.
        cd "$DEVENV_ROOT"

        # Idempotent: an unchanged file is never rewritten, so a `.sgra`'s mtime
        # does not churn on every run. The write goes through mktemp + mv so a
        # concurrent reader — this repository is routinely co-occupied — sees old
        # bytes or new bytes, never a partial file. Same shape and same reasons
        # as dev/tasks/generate.nix's `sync_file`.
        #
        # The `if` form rather than `cmp -s … && return`: an AND-list whose final
        # command fails would trip errexit.
        write_sgra() {
          if ${du}/cmp -s "$1" "$2" 2>/dev/null; then
            echo "==> unchanged $2" >&2
            return 0
          fi
          ${cu}/mkdir -p "$(${cu}/dirname "$2")"
          # Hidden prefix: a crashed run must not strand a visible
          # `grammar.sgra.XXXXXX` next to the real one, where a whole-project
          # `strictdoc export .` would read it as another grammar.
          tmp=$(${cu}/mktemp "$(${cu}/dirname "$2")/.$(${cu}/basename "$2").XXXXXX")
          ${cu}/cp -L "$1" "$tmp"
          ${cu}/chmod 0644 "$tmp"
          ${cu}/mv -f "$tmp" "$2"
          echo "==> wrote $2" >&2
        }

        ${lib.concatStrings (lib.mapAttrsToList writeCall cfg.grammars)}
      '';
    };
  };
}
