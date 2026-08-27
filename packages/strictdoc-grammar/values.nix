# cspell:ignore unrun
# This repository's five design-graph node types, written against the consumer
# DSL in ./lib/dsl.nix. Renders to ../../docs/sdoc/grammar.sgra.
#
# THIS FILE IS A CONSUMER, NOT PART OF THE PACKAGE. `packages/strictdoc-grammar`
# is general purpose and intended for publication; these five node types are one
# thing somebody built with it. They exercise about half the surface — no
# composite element, no view style, no human title, no child relation, no `Tag`
# or `MultipleChoice` field — which is exactly why `fixtures/foreign.sgra`
# exists alongside them.
#
# ORDER IS LOAD-BEARING at every level. StrictDoc enforces element, field and
# relation order, so the surface uses lists and the emitter renders them as
# given. The order here is the committed file's order, element for element and
# line for line; changing it changes the rendered file.
#
# Rendered with:
#
#   nix eval --raw --impure --expr '
#     let lib = (import <nixpkgs> {}).lib;
#         g = import ./packages/strictdoc-grammar/lib {inherit lib;};
#     in g.render (import ./packages/strictdoc-grammar/values.nix {inherit (g) dsl;})'
#
# or, the way anything else should reach it, through the `generate:sgra` devenv
# task, which is what actually writes `../../docs/sdoc/grammar.sgra`. That file
# is GENERATED in this repository — hand-editing it is drift, and
# `checks/strictdoc-grammar-model-equal.nix` is what notices.
{dsl}: let
  inherit (dsl) el field rel;
  inherit (field) one required str;

  # The three vocabularies the five node types share. Written once because they
  # ARE one vocabulary each — a DEPTH that meant different things on a MECHANISM
  # and on a SLICE would be a different field, not a repeated one.
  depths = [
    "sketch"
    "needs-design"
    "needs-spike"
    "interface-settled"
    "implemented"
    "verified"
  ];
  authors = ["llm" "human"];

  # The field run every node type but DECISION carries, in this order. DECISION
  # has no DEPTH and no PARENT_FP, so it is spelled out on its own below rather
  # than assembled by subtraction — subtraction reads as "the same thing, minus"
  # when the truth is that a decision is not a thing that has a depth.
  uid = required (str "UID");
  title = required (str "TITLE");
  depth = required (one "DEPTH" depths);
  authoredBy = required (one "AUTHORED_BY" authors);
  statement = required (str "STATEMENT");
  rationale = str "RATIONALE";
  parentFp = str "PARENT_FP";
  notes = str "NOTES";

  # The relation every node type carries back to the decision that governs it.
  governedBy = rel.parent "Governed_By" "Governs";
  provenBy = rel.parent "Proven_By" "Proves";
  assumes = rel.parent "Assumes" "Assumed_By";
in [
  (el "DECISION" {prefix = "DEC-";} {
    fields = [
      uid
      title
      authoredBy
      (required (one "STATUS" ["open" "accepted" "rejected" "superseded"]))
      (required (str "RETIRES_ON"))
      statement
      rationale
      notes
    ];
    relations = [
      (rel.parent "Superseded_By" "Supersedes")
    ];
  })

  (el "MECHANISM" {prefix = "MECH-";} {
    fields = [
      uid
      title
      depth
      authoredBy
      statement
      rationale
      parentFp
      notes
    ];
    relations = [
      governedBy
      (rel.parent "Guarantees" "Guaranteed_By")
      (rel.parent "Serialized_By" "Serializes")
      provenBy
      assumes
      rel.file
    ];
  })

  (el "SLICE" {prefix = "SLICE-";} {
    fields = [
      uid
      title
      depth
      authoredBy
      statement
      rationale
      parentFp
      notes
    ];
    relations = [
      governedBy
      (rel.parent "Crosses" "Crossed_By")
      assumes
      provenBy
      rel.file
    ];
  })

  (el "INVARIANT" {prefix = "INV-";} {
    fields = [
      uid
      title
      depth
      authoredBy
      statement
      rationale
      parentFp
      notes
    ];
    relations = [
      governedBy
      provenBy
    ];
  })

  (el "SPIKE" {prefix = "SPIKE-";} {
    fields = [
      uid
      title
      depth
      authoredBy
      (required (one "STATUS" ["unrun" "run" "blocked"]))
      (required (str "RETIRES_ON"))
      statement
      rationale
      parentFp
      notes
    ];
    relations = [
      governedBy
      rel.file
    ];
  })
]
