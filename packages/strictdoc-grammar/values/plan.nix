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
  (el "PLAN" {prefix = "PLAN-";} {
    # The root. One per plan, and the only node in this grammar with no
    # containment edge — which is what makes "the roots" a query rather than a
    # convention about where files live.
    fields = [
      uid
      title
      (required (one "STATUS" ["active" "archived"]))
      statement
    ];
  })

  (el "WORK" {prefix = "WORK-";} {
    # ONE node type for the whole ladder, tiered by a field rather than split
    # into MILESTONE / EPIC / TASK / STEP element types. The tiers differ in
    # altitude, not in shape: every one of them has a title, a state and a
    # parent, so five element types would be five copies of one field list.
    #
    # TIER IS DATA, DELIBERATELY REDUNDANT WITH NESTING DEPTH. Depth alone
    # cannot distinguish an epic under a milestone from an epic under an epic,
    # and a renderer would have to infer altitude by counting hops. The
    # redundancy is the point: "TIER must descend along Contained_By" is the
    # first illegal state the semantic layer gets to reject, and it is only
    # decidable because the two representations exist to disagree.
    #
    # `finding` IS THE BACKLOG, and that is why no BACKLOG element type is
    # declared. An item filed mid-session is a WORK node at TIER finding hanging
    # off whatever it was noticed under; the backlog is then a query, and
    # grooming is setting a real tier and re-parenting. Plan-global versus
    # per-subtree stops being a question — it is wherever the finding hangs.
    fields = [
      uid
      title
      (required (one "TIER" ["milestone" "epic" "task" "step" "finding"]))
      (required (one "STATUS" ["todo" "active" "blocked" "done" "dropped"]))
      statement
    ];
    relations = [
      containedBy

      # THE ONLY CROSS-GRAMMAR EDGE, and the hinge of the whole design: it is
      # what a collector consults before deleting a finished plan. A role is
      # registered on the SOURCE element, so declaring it here is what makes it
      # legal; the target only has to resolve somewhere in the index, which is
      # built across every document regardless of which grammar each imports.
      #
      # UNVERIFIED. Nothing in this repository has yet exercised a relation
      # whose two ends import different grammars. Prove it with a two-file
      # fixture before anything leans on it.
      (rel.parent "Realizes" "Realized_By")
    ];
  })
]
