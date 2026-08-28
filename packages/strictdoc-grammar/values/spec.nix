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
  # Something that must be true, written down so the next person is handed it
  # instead of working it out again.
  #
  # Make one when you notice you are explaining the same constraint for the
  # second time. Write it in the present tense, about the world, not in the
  # future tense about work.
  #
  # A requirement can be VIOLATED. If reality disagrees with it, reality is what
  # is wrong and reality is what gets fixed. That is the test that separates it
  # from a node describing how something works: ask what you would change on
  # finding a counterexample tomorrow -- the world, or this node. The world
  # means it is a requirement.
  (el "REQUIREMENT" {prefix = "REQ-";} {
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

  # A choice, and the reason it was made rather than the alternative.
  #
  # Make one whenever a question had more than one defensible answer and
  # somebody picked. If there was no alternative, there was no decision.
  #
  # The rejected options are the valuable part. An unrecorded rejection gets
  # proposed again months later by someone with no way of knowing it was already
  # weighed, and ending that is most of why this node type exists.
  #
  # Decisions stay durable even when made in passing during throwaway work,
  # which is why they live here rather than with the work that produced them.
  (el "DECISION" {prefix = "DEC-";} {
    fields = [
      uid
      title
      (required (one "STATUS" ["proposed" "accepted" "rejected" "superseded"]))
      statement
      (str "RATIONALE")
    ];
    relations = [(rel.parent "Superseded_By" "Supersedes")];
  })

  # How something actually works: the sequence, the wiring, the surprise that
  # costs an afternoon to rediscover.
  #
  # Make one when you learn something non-obvious that is not visible from
  # reading the code for ten seconds.
  #
  # A mechanism CANNOT be violated. It is a description, so if reality disagrees
  # with it, the node is simply wrong and the node is what gets fixed. That is
  # the exact opposite of a requirement, and it is why these go stale quietly:
  # nothing fails when one becomes false, it just starts misleading whoever
  # reads it next.
  (el "MECHANISM" {prefix = "MECH-";} {
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

  # One observation: what was actually done, and what came back.
  #
  # Make one when a claim would otherwise rest on sounding reasonable. Evidence
  # is what lets a decision cite a result instead of an argument.
  #
  # It is never withdrawn, only overtaken -- the world moves and the observation
  # stops describing it, which is a different kind of ending from being retired.
  #
  # One observation per node. A standing explanation resting on several of them
  # is a mechanism, and these are what it points at.
  (el "EVIDENCE" {prefix = "EV-";} {
    fields = [
      uid
      title
      freshness
      statement
    ];
    relations = [(rel.parent "Supports" "Supported_By")];
  })

  # Assembled prose for a person to read start to finish, over nodes that were
  # written to be queried rather than read.
  #
  # Make one when somebody needs the story and the graph only offers a pile.
  #
  # It CITES rather than restates, and that is the whole discipline. Prose that
  # repeats its sources drifts from them without anything noticing; prose that
  # points at them can be flagged for rewriting when they move.
  #
  # This is also the natural shape for anything generated for an outside reader
  # -- a guide, an introduction, a page of instructions.
  (el "NARRATIVE" {prefix = "NAR-";} {
    fields = [
      uid
      title
      freshness
      statement
    ];
    relations = [(rel.parent "Cites" "Cited_By")];
  })
]
