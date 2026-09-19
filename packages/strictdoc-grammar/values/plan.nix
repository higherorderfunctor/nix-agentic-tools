# PROPOSAL, NOT WIRED. A layer-0 grammar for PLAN documents, written against the
# consumer DSL in ../lib/dsl.nix. Nothing imports it: `ai.strictdoc.grammars` in
# devenv.nix carries a commented-out block naming it, and no check reads it.
#
# Layer 0 is deliberately pre-semantic. It declares node types, one state field
# each, and the relations between them. It declares NO transitions, no gates, no
# actors, no flows and no ripple — those are the semantic layer, and the point of
# stopping here is that a state field with no transition model is still a legal,
# thing that can be rendered and queried.
#
# PLAN IS A TREE, and it is disposable. Work decomposes by containment and gets
# collected once its durable output has dissolved into the spec grammar. That is
# why nothing durable is declared here: a plan holds no decision, no requirement
# and no mechanism, only edges to them.
#
# NOTHING IS COMPOSITE, and that is half the one-node-per-file forcing function.
# IS_COMPOSITE is the in-file nesting switch; leaving it unset makes a nested
# node impossible to express at the parser level. The other half has no spelling in
# a grammar at all — StrictDoc has no cardinality, so "exactly one node per file"
# is a check (MECH-SDOC-LAYOUT-CHECK), not a type. Together they are airtight:
# nothing nests, nothing sits beside.
#
# CONTAINMENT IS THEREFORE AN EDGE rather than document structure. That is forced
# by the two levers above, not chosen for taste.
#
# FIELD ORDER IS LOAD-BEARING. StrictDoc enforces field order within an element;
# a node whose fields are out of grammar order is a semantic error. Relation
# order inside a node is NOT enforced, but a new role should still be APPENDED,
# because this list is the emitted file's order line for line.
{dsl}: let
  inherit (dsl) el field rel;
  inherit (field) one required str;

  uid = required (str "UID");
  title = required (str "TITLE");
  statement = required (str "STATEMENT");

  # The tree. Reverse role named so a renderer can walk downward without
  # inverting the index by hand.
  containedBy = rel.parent "Contained_By" "Contains";
in [
  # A body of work with an end. Everything under it is meant to be finished and
  # then thrown away, so a plan is the unit you delete rather than the unit you
  # maintain.
  #
  # Make one when there is a goal that will eventually stop being interesting.
  # Do not make one for standing work that never completes -- that is a
  # description of how things are done, and belongs with the durable nodes.
  #
  # A plan holds no knowledge of its own. Anything learned while working on it
  # has to move out before the plan can be collected, and the edge from work to
  # a durable node is what tells you whether it has.
  (el "PLAN" {prefix = "PLAN-";} {
    fields = [
      uid
      title
      (required (one "STATUS" ["active" "archived"]))
      statement
    ];
  })

  # One thing that needs doing, at any size. The same node type covers the
  # largest goal and the smallest step; they differ in altitude, not in shape,
  # so the level is a field and the nesting is an edge.
  #
  # Make one whenever something needs doing and needs somewhere to hang.
  #
  # Work says what will be done. It never says what is true. The moment you
  # find yourself writing down the reason a thing is done this way, that is
  # knowledge, and it belongs in a durable node this one points at.
  #
  # The `finding` tier is a scratch bucket: something noticed in passing that is
  # not the current task and should not derail it. Write it, hang it off
  # whatever you were looking at, keep going. Sorting it out later means giving
  # it a real tier and moving it. What separates the two is whether anyone has
  # decided it should happen.
  (el "WORK" {prefix = "WORK-";} {
    fields = [
      uid
      title
      (required (one "TIER" ["milestone" "epic" "task" "step" "finding"]))
      (required (one "STATUS" ["todo" "active" "blocked" "done" "dropped"]))
      statement
    ];
    relations = [
      containedBy
      (rel.parent "Realizes" "Realized_By")
    ];
  })
]
