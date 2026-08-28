# PROPOSAL, NOT WIRED. A layer-0 grammar for SPEC documents, written against the
# consumer DSL in ../lib/dsl.nix. Nothing imports it. See ./plan.nix for the
# layer-0 boundary, the composite rule and the field-order rule; both grammars
# are governed by the same three and they are not restated here.
#
# SPEC IS A GRAPH, not a tree, and the asymmetry with ./plan.nix is the design
# rather than an inconsistency. Work decomposes by containment: a step is inside
# a task is inside an epic. Knowledge does not. A requirement is never INSIDE
# another requirement — it refines one, which is a different relation with a
# different meaning, and modelling it as containment would claim a whole-part
# reading nobody argued for.
#
# So there is no root node here and no grouping element. If areas are wanted
# later they are a relation, not a tree.
#
# SPEC IS THE DURABLE HALF. It is where a plan's output dissolves to, so that
# collecting a finished plan destroys nothing that outlives it. That is why
# DECISION lives here rather than in ./plan.nix even though decisions are made
# during planning: a decision is durable by nature — a rejected one especially,
# since the record of what was ruled out is the part that stops it being
# argued again from scratch. Keeping plans free of anything durable makes them safe to
# delete, and that property is worth more than the convenience of writing a
# decision where it was made.
#
# ONE STATE FIELD PER NODE TYPE. Not a simplification to be undone later — a
# node carrying two state fields is a state TUPLE, and a tuple is a product of
# machines with all the reachability and atomicity questions that implies.
# Layer 1 over this grammar is five independent one-field ladders, which is the
# cheapest possible first semantic layer. The product can be introduced when
# something actually needs it, and not before.
#
# NO FILE RELATIONS ANYWHERE, deliberately. A File relation names a filesystem
# path, which is an outside data source: nothing checks it exists, let alone
# that it changed. Declaring one would owe a staleness story on day one.
{dsl}: let
  inherit (dsl) el field rel;
  inherit (field) one required str;

  uid = required (str "UID");
  title = required (str "TITLE");
  statement = required (str "STATEMENT");

  # Written once each because each IS one vocabulary. A draft REQUIREMENT and a
  # draft MECHANISM mean the same thing; if they ever diverge that is a signal
  # they were never the same field, not a reason to copy the list.
  lifecycle = required (one "STATUS" ["draft" "active" "retired"]);
  freshness = required (one "STATUS" ["current" "stale"]);

  # The edge every content node carries back to what ruled it. Not carried by
  # DECISION itself: a decision governed by a decision is supersession, which is
  # its own role below.
  decidedBy = rel.parent "Decided_By" "Decides";
in [
  (el "REQUIREMENT" {prefix = "REQ-";} {
    # What must be true. The successor to an instruction or steering line: the
    # settled, persisted context a session is handed rather than re-derives.
    fields = [
      uid
      title
      lifecycle
      statement
    ];
    relations = [
      (rel.parent "Refines" "Refined_By")
      decidedBy
    ];
  })

  (el "DECISION" {prefix = "DEC-";} {
    # A choice and its reason. RATIONALE is the one optional field in either
    # grammar, and optional rather than required on purpose: forcing a rationale
    # produces a restated statement, which reads as a reason and is not one.
    fields = [
      uid
      title
      (required (one "STATUS" ["proposed" "accepted" "rejected" "superseded"]))
      statement
      (str "RATIONALE")
    ];
    relations = [
      # Supersession points FORWARD, from the retired decision to the one that
      # replaced it, so a reader who arrives at a stale node is carried to the
      # live one. The reverse direction would need the live node to know every
      # thing it ever displaced.
      (rel.parent "Superseded_By" "Supersedes")
    ];
  })

  (el "MECHANISM" {prefix = "MECH-";} {
    # How something actually works. Distinct from REQUIREMENT because the two
    # fail differently: a requirement is wrong when the world should be other
    # than it says, a mechanism is wrong when the world already is.
    fields = [
      uid
      title
      lifecycle
      statement
    ];
    relations = [
      (rel.parent "Implements" "Implemented_By")
      decidedBy
    ];
  })

  (el "EVIDENCE" {prefix = "EV-";} {
    # A measurement or observation that backs something else. Carries FRESHNESS
    # rather than LIFECYCLE because evidence is never retired by a decision —
    # it stops describing the world, which is a different kind of ending.
    fields = [
      uid
      title
      freshness
      statement
    ];
    relations = [(rel.parent "Supports" "Supported_By")];
  })

  (el "NARRATIVE" {prefix = "NAR-";} {
    # Guided prose over the unit nodes: the assembled, human-readable form. It
    # cites rather than restates, so its citations are what a later layer reads
    # to decide it needs rewriting when something under it moves.
    fields = [
      uid
      title
      freshness
      statement
    ];
    relations = [(rel.parent "Cites" "Cited_By")];
  })
]
