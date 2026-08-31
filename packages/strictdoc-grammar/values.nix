# cspell:ignore unrun
# This repository's design-graph node types, written against the consumer DSL
# in ./lib/dsl.nix. Renders to ../../docs/sdoc/grammar.sgra.
#
# THIS FILE IS A CONSUMER, NOT PART OF THE PACKAGE. `packages/strictdoc-grammar`
# is general purpose and intended for publication; these node types are one
# thing somebody built with it. `fixtures/foreign.sgra` exists alongside them to
# exercise the parts of the surface they leave alone.
#
# THE VOCABULARY IS RULED, NOT ENUMERATED. DEC-NODE-FAMILIES (docs/spec) derives
# it from four families:
#
#   Definition      the claims the canon asserts, in a 2x2 —
#                   normative x universal   REQUIREMENT   can be violated
#                   normative x particular  DECISION      can be violated
#                   descriptive x universal MECHANISM     can only be wrong
#                   descriptive x particular EVIDENCE     can be wrong or outdated
#   Coverage        USE_CASE   a path the specification must enable; covered or not
#   Representation  NARRATIVE  a maintained projection for a reader; its edges go
#                              dirty when what it presents changes
#   Work            WORK       something to do; not a claim; dies with its plan
#   Commentary      COMMENTARY a remark ABOUT the canon: a gap, an architecture
#                              note, a verdict, a note on one edge. Whether this
#                              is a fifth family or the odd member of
#                              Representation is OPEN
#                              (DEC-COMMENTARY-IS-THE-FIFTH-FAMILY).
#
# UID PREFIXES NAME THE TYPE A NODE WAS BORN WITH, NOT THE TYPE IT IS.
# DEC-UID-OUTLIVES-TYPE: a UID never changes, so the node-type migration of
# 2026-08-30 retyped SLICE-, INV- and SPIKE- nodes in place and those prefixes
# are retired history. The element tag is the type. `sdoc new` still requires
# the current prefix on a NEW node; `sdoc check` tolerates a prefix no element
# declares and reports only a prefix that belongs to a DIFFERENT element.
#
# ORDER IS LOAD-BEARING, though not uniformly, and the difference was measured
# 2026-08-27 rather than assumed. StrictDoc enforces element and FIELD order: a
# node whose fields are out of grammar order is a semantic error. It does NOT
# enforce relation order inside a node -- a RELATIONS block listing roles in any
# order parses clean. What it does check is that the role is REGISTERED:
# an unknown one fails with "Requirement relation type/role is not registered".
#
# The surface still uses lists and the emitter still renders them as given, and
# a new field or relation role should still be APPENDED rather than inserted,
# because the order here is the committed file's order line for line and
# reordering it rewrites `docs/sdoc/grammar.sgra` for no reason. For FIELDS it
# is also a corpus argument: inserting one mid-list means repositioning it in
# every existing node of that type.
#
# THAT CORPUS ARGUMENT HOLDS ONLY ONCE NODES CARRY THE FIELD, measured
# 2026-08-31 rather than assumed. Appending an optional field exports clean;
# INSERTING one mid-list, while no node carries it, ALSO exports clean --
# strictdoc validates the order of the fields a node ACTUALLY HAS, so an
# absent optional field only advances the grammar pointer. The positive
# control that makes those two greens mean anything: swapping DEPTH and
# AUTHORED_BY on one real node fails with "Semantic error: Wrong field
# order". COMPONENT was therefore appended on the .sgra-diff ground alone,
# and its position is still free until a migration writes values.
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
  inherit (field) one required str tag;

  # The vocabularies the node types share. Written once because they ARE one
  # vocabulary each — a DEPTH that meant different things on two types would be
  # a different field, not a repeated one.
  depths = [
    "sketch"
    "needs-design"
    "needs-spike"
    "interface-settled"
    "implemented"
    "verified"
  ];
  # DEC-AUTHORSHIP-LADDER: one monotonic ladder that only rises. The middle two
  # rungs are a human's acts (seen and let stand; adopted as their own); the
  # writer stamps the bottom rung and has no flag for the others.
  authors = ["llm" "llm-accepted" "llm-adopted" "human"];

  # The field run every claim-bearing type carries, in this order. DECISION has
  # no DEPTH and no PARENT_FP, so it is spelled out on its own below rather than
  # assembled by subtraction — subtraction reads as "the same thing, minus" when
  # the truth is that a decision is not a thing that has a depth.
  uid = required (str "UID");
  title = required (str "TITLE");
  depth = required (one "DEPTH" depths);
  authoredBy = required (one "AUTHORED_BY" authors);
  statement = required (str "STATEMENT");
  rationale = str "RATIONALE";
  parentFp = str "PARENT_FP";
  notes = str "NOTES";

  # DEC-COMPONENT-IS-DECLARED (open): what a node is ABOUT, said by the node
  # rather than computed from where its file sits. Free words rather than a
  # MultiChoice, because a closed list here would put the vocabulary in two
  # places and make adding a component a grammar regeneration. Optional, so
  # the field lands before any corpus carries it. Excluded from the contract
  # hash in dev/scripts/sdoc_fp.py for the same reason PLACE is: re-filing a
  # node does not change what it claims.
  component = tag "COMPONENT";

  # Roles. Every Parent role is a dependency: the node that carries it depends
  # on the target's wording, may fingerprint it in PARENT_FP, and is walked by
  # readiness and the cycle check. A Child role is the opposite: the node that
  # carries it points DOWN at something it owns or produced, with no dependency
  # and no fingerprint, so a collectable node can point at a durable one and
  # collection never strands a reference.
  governedBy = rel.parent "Governed_By" "Governs";
  provenBy = rel.parent "Proven_By" "Proves";
  assumes = rel.parent "Assumes" "Assumed_By";
  guarantees = rel.parent "Guarantees" "Guaranteed_By";
  serializedBy = rel.parent "Serialized_By" "Serializes";
  crosses = rel.parent "Crosses" "Crossed_By";
  coveredBy = rel.parent "Covered_By" "Covers";
  cites = rel.parent "Cites" "Cited_By";
  contains = rel.child "Contains" "Contained_In";
  produces = rel.child "Produces" "Produced_By";

  # Containment by EDGE rather than by file. A plan's backlog is a register
  # node, and an ungroomed item points at it. Carried by every type because
  # anything can be noticed before it is groomed. Appended to each element's
  # relation list rather than slotted in beside the roles it reads like, per the
  # ORDER note above.
  backloggedIn = rel.parent "Backlogged_In" "Backlogs";

  # A commentary DEPENDS on the wording of what it remarks on -- that is what
  # makes a stale remark detectable at all, because the PARENT_FP entry drifts
  # when the target's contract changes. Parent, therefore, and fingerprintable.
  # Carried by COMMENTARY alone.
  remarksOn = rel.parent "Remarks_On" "Remarked_On_By";

  # The relation run the four Definition types and WORK share: what rules it,
  # what it upholds, what serializes it, what evidence backs it, what it takes
  # as given, the file it lives in, and its backlog register.
  claimRelations = [
    governedBy
    guarantees
    serializedBy
    provenBy
    assumes
    rel.file
    backloggedIn
  ];
in [
  # ----------------------------------------------------------------- Definition
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
      component
    ];
    relations = [
      (rel.parent "Superseded_By" "Supersedes")
      backloggedIn
      provenBy
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
      component
    ];
    relations = claimRelations;
  })

  (el "REQUIREMENT" {prefix = "REQ-";} {
    fields = [
      uid
      title
      depth
      authoredBy
      statement
      rationale
      parentFp
      notes
      component
    ];
    relations = claimRelations;
  })

  # SOURCE is where the observation came from when it is not this repository:
  # a URL, a paper, a vendor document, a log path, the command that produced
  # it. An observation with no SOURCE was made here.
  (el "EVIDENCE" {prefix = "EV-";} {
    fields = [
      uid
      title
      depth
      authoredBy
      (str "SOURCE")
      statement
      rationale
      parentFp
      notes
      component
    ];
    relations = claimRelations;
  })

  # ------------------------------------------------------------------- Coverage
  # A use case is covered by the requirements, decisions and mechanisms that
  # together enable it; it depends on their wording, so Covered_By is a Parent
  # role and may be fingerprinted.
  (el "USE_CASE" {prefix = "UC-";} {
    fields = [
      uid
      title
      depth
      authoredBy
      statement
      rationale
      parentFp
      notes
      component
    ];
    relations = [
      governedBy
      coveredBy
      provenBy
      backloggedIn
    ];
  })

  # ------------------------------------------------------------- Representation
  # WIDGET names how this node's STATEMENT is drawn -- the renderer knows the
  # widget words and nothing else. The first seven draw the STATEMENT itself;
  # stack, grid, ladder and facts draw its rows as a figure; strip, tally,
  # index and list count or list the SUBJECT's children; edges and
  # fingerprints draw the selection. The subject is the narrative named by the
  # Over relation, else the narrative itself (DEC-WIDGET-SUBJECT-IS-ITS-OVER-
  # TARGET). PLACE says how a narrative sits on the screen of the narrative
  # that Contains it: a tab of its own, a screen of its own reached from an
  # index, a section stacked on the container's screen, or a card; absent
  # reads section, and a root has none (DEC-NARRATIVE-DECLARES-ITS-PLACE).
  # TAGS are free facet words the VIEW reads: a tab key, a query word, or a
  # reserved marker such as term, systems, tabs or colours. COMPONENT is a
  # different axis and deliberately a different field -- TAGS says how a node
  # is PRESENTED, COMPONENT says what it is ABOUT. A narrative Cites what it presents (dependency, fingerprintable)
  # and Contains the narratives it is composed of, in RELATIONS order. PLACE
  # and Over are outside the contract hash: moving a card must not dirty
  # what cites it.
  (el "NARRATIVE" {prefix = "NAR-";} {
    fields = [
      uid
      title
      depth
      authoredBy
      (one "WIDGET" [
        "prose"
        "callout"
        "rows"
        "table"
        "facts"
        "glossary"
        "legend"
        "stack"
        "grid"
        "ladder"
        "strip"
        "tally"
        "index"
        "list"
        "edges"
        "fingerprints"
      ])
      (one "PLACE" ["tab" "screen" "section" "card"])
      (tag "TAGS")
      statement
      rationale
      parentFp
      notes
      component
    ];
    relations = [
      cites
      contains
      backloggedIn
      (rel.parent "Over" "Shown_By")
    ];
  })

  # ----------------------------------------------------------------------- Work
  # Work declares what it crosses (the lane), what it assumes, and what it
  # Produces — the evidence it leaves behind, pointed at downward so the
  # evidence outlives the work. DEPTH on WORK conflates design maturity with
  # delivery; DEC-WORK-STATE-FIELD holds that open until beads runs.
  (el "WORK" {prefix = "WORK-";} {
    fields = [
      uid
      title
      depth
      authoredBy
      statement
      rationale
      parentFp
      notes
      component
    ];
    relations = [
      governedBy
      crosses
      assumes
      provenBy
      produces
      rel.file
      backloggedIn
    ];
  })

  # ----------------------------------------------------------------- Commentary
  # A remark ABOUT the canon rather than about the system the canon describes:
  # a gap, an architecture note, a verdict on a node, a note on one edge. Its
  # point is that a validator can be run against it, which a narrative row
  # carrying a bracketed word cannot be.
  #
  # DEC-COMMENTARY-IS-THE-FIFTH-FAMILY is OPEN. Whether this is a fifth family
  # or the odd member of Representation is the operator's call, and no code
  # reads the family, so the element exists while that is unsettled. Nothing in
  # the corpus is a COMMENTARY yet.
  #
  # STANDING, not STATUS: STATUS is one name with one word list on one type,
  # and a second list under that name would make the word mean two things.
  # CLOSES_ON is RETIRES_ON's shape and is required for the same reason -- a
  # remark with no closing condition is a complaint, not a finding, and being
  # `required` is what makes the grammar itself enforce that.
  #
  # There is deliberately NO KIND field: verdict vocabularies are legend data
  # (DEC-LEGEND-IS-DATA-WHERE-PLACED), never a grammar field, so facet words
  # ride in TAGS.
  #
  # EDGE names one relation structurally, "<FROM> <Role> <TO>", because a
  # strictdoc relation is a TYPE/VALUE/ROLE triple with no identity of its own.
  # Both endpoints are ALSO Remarks_On relations, which is what makes the
  # PARSER refuse a dangling end; dev/scripts/commentary-check.py keeps the
  # redundancy honest. The three-token split assumes no role name contains
  # whitespace, which holds -- every role is Snake_Case.
  (el "COMMENTARY" {prefix = "CMT-";} {
    fields = [
      uid
      title
      authoredBy
      (required (one "STANDING" ["open" "closed" "withdrawn"]))
      (required (str "CLOSES_ON"))
      (str "EDGE")
      (tag "TAGS")
      statement
      rationale
      parentFp
      notes
      component
    ];
    relations = [
      remarksOn
      provenBy
      backloggedIn
      rel.file
    ];
  })
]
