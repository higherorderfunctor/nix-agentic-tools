# tree-sitter-strictdoc — patched upstream grammar for StrictDoc's .sdoc/.sgra
# format, packaged as a flake output per DEC-GRAMMAR-PATCH-NOT-FORK
# (packages/semble/.sdoc/01-grammar-injection.sdoc): the grammar DEFINITION is
# patched in this overlay, never forked, and the build regenerates the parser
# from it.
#
# Cache-hit parity: every build input comes from THIS repo's nixpkgs pin, never
# the consumer's `final` — see dev/fragments/overlays/overlay-pattern.md.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub lib;
  vu = import ../lib.nix;

  rev = "bba07bd4d41835e3e5f456a9603ce601b1be1937";
  src = fetchFromGitHub {
    owner = "manueldiagostino";
    repo = "tree-sitter-strictdoc";
    inherit rev;
    hash = "sha256-sIbh8mYWrGhaXtRxe/FYIT1aD8WAKfQYJJbhWhz9jEs=";
  };
in
  ourPkgs.tree-sitter.buildGrammar {
    language = "strictdoc";
    # tree-sitter.json declares 0.1.0. Upstream DOES ship tags (v0.1.0,
    # v0.2.0) -- main-tracking is chosen because it ships no PUBLISHED
    # release: `releases/latest` 404s, so ghLatestVersionCmd cannot resolve a
    # version at all. Do not "correct" this to tag tracking on seeing the
    # tags; that breaks the update script. The pin is main HEAD, which is
    # ahead of v0.2.0 (40dfc545).
    version = vu.mkVersion {
      upstream = "0.1.0";
      inherit rev;
    };
    inherit src;

    # `generate = true` pulls in nodejs+tree-sitter and runs the builder's own
    # bare `tree-sitter generate`. This grammar's tree-sitter.json declares no
    # `.path`, so configurePhase never leaves the repo root — but the grammar
    # DEFINITION lives under grammar/, not at the root the bare command
    # expects, so the entry point needs to be named explicitly. Skipping this
    # override is a SILENT no-op: the build succeeds, ships upstream's
    # committed src/parser.c unchanged, and the patch below never takes
    # effect. See DEC-GRAMMAR-PATCH-NOT-FORK.
    generate = true;
    preBuild = "tree-sitter generate grammar/grammar.js";

    # Patches the grammar DEFINITION (grammar/grammar.js,
    # grammar/rules/document_grammar.js, grammar/rules/type_system.js), not the
    # generated parser. Three gaps, each measured against a real file upstream
    # could not parse:
    #   - the root rule required a [DOCUMENT] header, so a bare .sgra grammar
    #     file could never parse at all;
    #   - grammar_relation_parent/child had no REVERSE_ROLE field, which this
    #     repo's own grammar.sgra uses on every non-File Parent relation;
    #   - choice_option was `[\w/-]+`, which rejects both the QUOTED option form
    #     and any option containing a `.`. StrictDoc's own production is
    #     `(["])[^,]+\1|[^,()"]+`, so a legal
    #     `SingleChoice("MIT (Expat)", GPL-3.0-or-later, proprietary)` failed.
    #     Found by checks/strictdoc-grammar-corpus.nix the moment
    #     packages/strictdoc-grammar/fixtures/foreign.sgra entered the corpus.
    patches = [./tree-sitter-strictdoc.patch];
    patchFlags = ["-p1" "--fuzz=0"];

    meta = {
      description = "Tree-sitter grammar for StrictDoc's .sdoc/.sgra format, patched to parse standalone .sgra grammar files and REVERSE_ROLE relations";
      homepage = "https://github.com/manueldiagostino/tree-sitter-strictdoc";
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  }
