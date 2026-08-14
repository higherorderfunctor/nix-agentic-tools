# Whole-tree analysis for a Kiro workflow definition.
#
# ./types.nix enforces everything decidable from ONE node. This file carries
# everything that needs the tree: counts, id uniqueness, node orientation, and
# the cross-node template reference rules. It is a re-implementation of the
# engine's own `analyzeWorkflow` (src/workflow/validate.ts), against which
# every rule below is traceable.
#
# ── The `basis` taxonomy ────────────────────────────────────────────────────
#
# Adopted verbatim from fixtures/kiro-primitives/workflows/contract.jq rather
# than reinvented, so the two checkers stay comparable. Every diagnostic says
# WHOSE rule it is:
#
#   engine      the engine performs an equivalent check and will refuse
#   policy      the engine ACCEPTS this; the rule exists because acceptance
#               is silent and the consequence is expensive
#   mechanical  generator hygiene, no engine opinion
#
# Only `engine` and `policy` are emitted here. The one `mechanical` finding in
# this package — a filename stem disagreeing with `workflow.name` — is emitted
# by ./render.nix, because it is a property of the FILE, not of the tree.
#
# Keeping these separable is load-bearing. A prior measurement found that a
# policy-basis rule would reject this repo's own working drain recipe, so a
# consumer must be able to run the engine rules alone.
#
# Match on `code`, never on `message`.
#
# ── Shape of the walk ───────────────────────────────────────────────────────
#
# One flatten pass produces a record per node carrying its lineage, then the
# rules are pure functions over that list. This mirrors the engine, which
# accumulates into one walk state and then runs its post-passes. The flatten
# uses an explicit accumulator rather than tree recursion so it has the same
# shape as the TypeScript type-level walker in packages/kiro-cli/schema/,
# where tail position actually matters.
{lib}: let
  inherit (builtins) attrNames elemAt filter head isList length;
  inherit (lib) concatLists concatStringsSep imap0 optional optionals;

  engine = builtins.fromJSON (builtins.readFile ./engine-limits.json);
  inherit (engine) limits;

  diag = severity: basis: code: where: message: {inherit basis code message severity where;};
  err = diag "error" "engine";
  pol = diag "warning" "policy";

  # ── Flatten ───────────────────────────────────────────────────────────────
  #
  # A lineage segment is {kind, index}; `kind` is the CONTAINER's kind, so a
  # child of a parallel carries "concurrent". Top-level steps are "ordered".
  # Depth is `length lineage`, matching the engine's `lineage.length` test.
  flatten = nodes: let
    go = parentLineage: kind: ns:
      concatLists (imap0 (
          i: n: let
            tag = head (attrNames n);
            v = n.${tag};
            lineage =
              parentLineage
              ++ [
                {
                  inherit kind;
                  index = i;
                }
              ];
            self = {
              inherit lineage tag;
              node = v;
              id = v.id or "<missing>";
              siblingIndex = i;
              siblings = ns;
              where =
                if parentLineage == []
                then "steps[${toString i}]"
                else "${v.id or "?"}";
            };
            kids =
              if tag == "sequence" || tag == "repeat"
              then go lineage "ordered" v.steps
              else if tag == "parallel"
              then go lineage "concurrent" v.branches
              else [];
          in
            [self] ++ kids
        )
        ns);
  in
    go [] "ordered" nodes;

  # A node produces referenceable output iff it is a watch (unconditionally)
  # or a step that did not explicitly opt out. Containers never produce.
  isProducer = e:
    e.tag == "watch" || (e.tag == "step" && (e.node.captureOutput or null) != false);

  # Engine `precedes`. Divergence inside a concurrent container is NEVER an
  # ordering, and an ancestor/descendant pair does not "precede" either.
  precedes = a: b: let
    n = let
      la = length a;
      lb = length b;
    in
      if la < lb
      then la
      else lb;
    firstDiff = let
      hits = filter (i: (elemAt a i).index != (elemAt b i).index) (lib.range 0 (n - 1));
    in
      if n == 0 || hits == []
      then null
      else head hits;
  in
    if firstDiff == null
    then false
    else if (elemAt a firstDiff).kind == "concurrent"
    then false
    else (elemAt a firstDiff).index < (elemAt b firstDiff).index;

  isDescendantOf = ancestorLineage: lineage:
    length lineage
    > length ancestorLineage
    && lib.take (length ancestorLineage) lineage == ancestorLineage;

  # ── Template references ───────────────────────────────────────────────────
  #
  # The engine's grammar is one regex: `{{` + a run with no braces + `}}`.
  # No nesting, no filters, no escaping. POSIX ERE has no lazy quantifier,
  # but `[^{}]*` cannot span a closing `}}`, so a greedy capture is exact.
  #
  # Braces are bracketed rather than backslash-escaped: Nix regexes are POSIX
  # ERE, where `\{` is not a defined escape and the whole pattern is rejected
  # at runtime as invalid.
  refsIn = s: let
    parts = builtins.split "[{][{]([^{}]*)[}][}]" s;
  in
    map (m: lib.trim (head m)) (filter isList parts);

  # Ordered exactly as the engine's if-chain. `artifacts.` is tested BEFORE
  # the generic `.output` suffix, so `{{artifacts.foo.output}}` is the
  # artifact named "foo.output", not an output reference.
  classify = expr:
    if expr == "previous.output"
    then {kind = "previous";}
    else if lib.hasPrefix "steps." expr && lib.hasSuffix ".output" expr
    then {
      kind = "output";
      target = lib.removeSuffix ".output" (lib.removePrefix "steps." expr);
    }
    else if lib.hasPrefix "artifacts." expr
    then {
      kind = "artifact";
      target = lib.removePrefix "artifacts." expr;
    }
    else if lib.hasSuffix ".output" expr
    then {
      kind = "output";
      target = lib.removeSuffix ".output" expr;
    }
    else {
      kind = "bare";
      target = expr;
    };
  # ── The analysis ──────────────────────────────────────────────────────────
in rec {
  inherit classify flatten precedes refsIn;

  analyze = workflow: let
    entries = flatten workflow.steps;
    byId = lib.listToAttrs (map (e: lib.nameValuePair e.id e) entries);
    stepEntries = filter (e: e.tag == "step") entries;
    watchIds = map (e: e.id) (filter (e: e.tag == "watch") entries);
    declaredInputs = attrNames (workflow.inputs or {});

    # name -> list of declaring step entries. Duplicates are legal; the
    # engine keeps every declarer and passes if ANY of them precedes.
    artifactProducers =
      lib.foldl' (
        acc: e:
          lib.foldl' (a: n: a // {${n} = (a.${n} or []) ++ [e];}) acc
          (attrNames (e.node.artifacts or {}))
      ) {}
      stepEntries;

    # ── engine-basis: counts, ids, depth ──────────────────────────────────
    stepCount = length stepEntries;
    countDiag =
      optional (stepCount > limits.maxStepNodes)
      (err "E-STEP-NODES-MAX" "workflow"
        ("workflow has ${toString stepCount} step nodes, exceeding the maximum of "
          + "${toString limits.maxStepNodes}; only `step` nodes count, wrappers are free"));

    depthDiags = map (
      e:
        err "E-NESTING-DEPTH" e.where
        ("node sits at nesting depth ${toString (length e.lineage)}, exceeding the maximum of "
          + "${toString limits.maxNestingDepth}")
    ) (filter (e: length e.lineage > limits.maxNestingDepth) entries);

    dupDiags = let
      ids = map (e: e.id) entries;
      duplicated = lib.unique (filter (i: length (filter (x: x == i) ids) > 1) ids);
    in
      map (i:
        err "E-NODE-DUPLICATE-ID" "workflow"
        "duplicate node id '${i}'; ids must be unique across the WHOLE tree, not just among siblings")
      duplicated;

    # ── engine-basis: the one node-orientation rule ───────────────────────
    #
    # A step declaring `completion` is interactive: it parks and waits for a
    # user message. It may not appear anywhere beneath a parallel, because a
    # reply cannot resume a parked step while sibling branches keep the run
    # loop busy. Checked against ANY concurrent ancestor, not the parent.
    #
    # This is the ONLY placement rule the engine has. Nested repeats, nested
    # parallels, watch-inside-parallel and sequence-anywhere are all legal
    # and are deliberately NOT restricted here.
    interactiveDiags =
      map (
        e:
          err "E-INTERACTIVE-STEP-IN-PARALLEL" e.where
          ("step '${e.id}' declares `completion` beneath a `parallel`; an interactive step "
            + "cannot be resumed while sibling branches keep the run loop busy")
      ) (filter (
          e:
            e.tag
            == "step"
            && (e.node.completion or null) != null
            && lib.any (seg: seg.kind == "concurrent") e.lineage
        )
        entries);

    # ── engine-basis: stopWhen watch resolution ───────────────────────────
    watchRefDiags =
      map (
        e:
          err "E-STOP-WHEN-WATCH-ID" e.where
          ("repeat '${e.id}' stops on watch id '${e.node.stop.when.watchTerminal}', which names no "
            + "`watch` node in this workflow (known: "
            + "${
              if watchIds == []
              then "none"
              else concatStringsSep ", " watchIds
            })")
      ) (filter (
          e:
            e.tag
            == "repeat"
            && (e.node.stop or null) != null
            && (e.node.stop ? when)
            && (e.node.stop.when ? watchTerminal)
            && !(lib.elem e.node.stop.when.watchTerminal watchIds)
        )
        entries);

    # ── engine-basis: template references in prompts and artifact values ──
    templateDiags = concatLists (map (
        e: let
          surfaces =
            [e.node.prompt] ++ (lib.attrValues (e.node.artifacts or {}));
          exprs = lib.unique (concatLists (map refsIn surfaces));
        in
          concatLists (map (expr: checkPromptRef e expr) exprs)
      )
      stepEntries);

    checkPromptRef = e: expr: let
      c = classify expr;
      priorSiblingProducers =
        filter (s: isProducer (flattenSibling s))
        (lib.take e.siblingIndex e.siblings);
      # A sibling is a bare node attrset; wrap it enough for isProducer.
      flattenSibling = n: let
        tag = head (attrNames n);
      in {
        inherit tag;
        node = n.${tag};
      };
    in
      if c.kind == "previous"
      then
        optionals ((head (lib.reverseList e.lineage)).kind == "concurrent") [
          (err "E-TEMPLATE-PREVIOUS-IN-PARALLEL" e.where
            "step '${e.id}' uses {{previous.output}} inside a parallel branch, where there is no guaranteed prior sibling")
        ]
        ++ optionals ((head (lib.reverseList e.lineage)).kind != "concurrent" && priorSiblingProducers == []) [
          (err "E-TEMPLATE-PREVIOUS-NO-PRODUCER" e.where
            "step '${e.id}' uses {{previous.output}} but no earlier sibling produces output")
        ]
      else if c.kind == "output"
      then
        if !(byId ? ${c.target})
        then [(err "E-TEMPLATE-REF-UNKNOWN" e.where "step '${e.id}' references {{${expr}}}, but no node has id '${c.target}'")]
        else if !(isProducer byId.${c.target})
        then [
          (err "E-TEMPLATE-REF-NOT-PRODUCER" e.where
            ("step '${e.id}' references {{${expr}}}, but '${c.target}' produces no output"
              + " (a `${byId.${c.target}.tag}` node, or a step with captureOutput = false)"))
        ]
        else if !(precedes byId.${c.target}.lineage e.lineage)
        then [
          (err "E-TEMPLATE-REF-NOT-PRECEDING" e.where
            ("step '${e.id}' references {{${expr}}}, but '${c.target}' does not run strictly before it"
              + " — a later sibling, an ancestor/descendant, or a different parallel branch"))
        ]
        else []
      else if c.kind == "artifact"
      then
        if !(artifactProducers ? ${c.target})
        then [(err "E-ARTIFACT-REF-UNKNOWN" e.where "step '${e.id}' references {{${expr}}}, but no step declares artifact '${c.target}'")]
        else if !(lib.any (p: precedes p.lineage e.lineage) artifactProducers.${c.target})
        then [
          (err "E-ARTIFACT-REF-NOT-PRECEDING" e.where
            "step '${e.id}' references {{${expr}}}, but no step declaring artifact '${c.target}' runs strictly before it")
        ]
        else []
      else
        # A bare reference is NEVER an error — the engine leaves it literal.
        # It warns only for names that look like identifiers, so a typo'd
        # `{{foo.bar}}` is invisible to the engine. We surface that too,
        # because silent-literal is the failure it causes.
        optionals (!(lib.elem c.target declaredInputs)) [
          (pol "W-UNDECLARED-INPUT-REF" e.where
            ("step '${e.id}' references {{${expr}}}, which is not a declared input; it stays LITERAL"
              + " in the prompt at runtime rather than erroring"))
        ];

    # ── engine-basis: stop-context references ─────────────────────────────
    #
    # Stop contexts use a DIFFERENT, relaxed rule set: {{previous.output}} is
    # always rejected, self-reference is allowed, and a repeat may reach into
    # producers inside its own body.
    stopContextDiags = concatLists (map (
        e: let
          includeDescendants = e.tag == "repeat";
          templates =
            if e.tag == "step"
            then optional ((e.node.completion.fileCheck or null) != null) e.node.completion.fileCheck.path
            else if e.tag == "repeat" && (e.node.stop or null) != null
            then
              optional ((e.node.stop.condition.fileCheck or null) != null) e.node.stop.condition.fileCheck.path
              ++ optional ((e.node.stop.when.contains or null) != null) "{{${e.node.stop.when.contains.template}}}"
            else [];
          exprs = lib.unique (concatLists (map refsIn templates));
        in
          concatLists (map (expr: checkStopRef e includeDescendants expr) exprs)
      )
      entries);

    checkStopRef = e: includeDescendants: expr: let
      c = classify expr;
      visible = t:
        t.id
        == e.id
        || precedes t.lineage e.lineage
        || (includeDescendants && isDescendantOf e.lineage t.lineage);
    in
      if c.kind == "previous"
      then [(err "E-STOP-CONTEXT-PREVIOUS" e.where "'${e.id}' uses {{previous.output}} in a stop condition, which is never legal there")]
      else if c.kind == "output"
      then
        if !(byId ? ${c.target})
        then [(err "E-STOP-CONTEXT-REF-UNKNOWN" e.where "'${e.id}' stop condition references {{${expr}}}, but no node has id '${c.target}'")]
        else if !(isProducer byId.${c.target})
        then [(err "E-STOP-CONTEXT-REF-NOT-PRODUCER" e.where "'${e.id}' stop condition references {{${expr}}}, which produces no output")]
        else if !(visible byId.${c.target})
        then [(err "E-STOP-CONTEXT-REF-NOT-VISIBLE" e.where "'${e.id}' stop condition references {{${expr}}}, which is neither itself, nor earlier, nor inside its own body")]
        else []
      else [];

    # ── policy-basis lints ────────────────────────────────────────────────
    policyDiags =
      concatLists (map (
          e:
            optionals (e.tag == "repeat") (
              optional ((e.node.stop or null) == null)
              (pol "W-REPEAT-NO-STOP-FORM" e.where
                ("repeat '${e.id}' defines neither stop form. This IS legal — the vendor's own "
                  + "`autoresearch` recipe ships this way — but the loop then runs to maxIterations "
                  + "with nothing reporting why"))
              ++ optional (e.node.onMaxIterations == "continue")
              (pol "W-ON-MAX-ITERATIONS-CONTINUE" e.where
                ("repeat '${e.id}' uses onMaxIterations = \"continue\", which marks an EXHAUSTED loop "
                  + "*completed* — unfinished work scores as success"))
              ++ optional (e.node.onMaxIterations == "pause")
              (pol "W-ON-MAX-ITERATIONS-PAUSE" e.where
                ("repeat '${e.id}' uses onMaxIterations = \"pause\"; resuming grants no further "
                  + "iterations, it re-pauses immediately, and a paused run cannot be retried"))
              ++ optional (e.node.steps == [])
              (pol "W-CONTAINER-EMPTY" e.where "repeat '${e.id}' has no children and would loop doing nothing")
            )
            ++ optionals (e.tag == "parallel") (
              optional (e.node.joinPolicy == "any")
              (pol "W-JOIN-POLICY-ANY" e.where
                "parallel '${e.id}' uses joinPolicy = \"any\", which CANCELS its siblings on the first completion")
              ++ optional (e.node.joinPolicy == "all")
              (pol "W-JOIN-POLICY-ALL" e.where
                ("parallel '${e.id}' uses joinPolicy = \"all\", which aborts every sibling on the first branch "
                  + "FAILURE; \"allSettled\" structurally cannot cancel"))
              ++ optional (e.node.branches == [])
              (pol "W-CONTAINER-EMPTY" e.where "parallel '${e.id}' has no branches and would join immediately")
            )
            ++ optionals (e.tag == "sequence") (
              optional (e.node.steps == [])
              (pol "W-CONTAINER-EMPTY" e.where "sequence '${e.id}' has no children and would run nothing")
            )
            ++ optionals (e.tag == "step") (
              optional (
                (e.node.completion or null)
                != null
                && e.node.completion.completionSignal != null
                && (e.node.completion.containsText != null || e.node.completion.fileCheck != null)
              )
              (pol "W-STOP-CONDITION-SIGNAL-FIRST" e.where
                ("step '${e.id}' sets completionSignal alongside another stop form; the signal is tested "
                  + "FIRST and returns, making the others dead"))
            )
        )
        entries)
      ++ fileCheckDiags
      ++ strandedVerifyDiags;

    # An array `fileCheck.value` means "any of these candidates" to the
    # engine, not "match this array" — a spelling that reads as the opposite
    # of what it does.
    fileCheckDiags = let
      checks = concatLists (map (
          e:
            optional ((e.node.completion.fileCheck or null) != null) {
              inherit (e) id where;
              fc = e.node.completion.fileCheck;
            }
            ++ optional ((e.node.stop.condition.fileCheck or null) != null) {
              inherit (e) id where;
              fc = e.node.stop.condition.fileCheck;
            }
        )
        entries);
      unsafePath = p:
        lib.hasInfix "{{" p
        || lib.hasPrefix "/" p
        || lib.hasPrefix "~" p
        || lib.elem ".." (lib.splitString "/" p);
    in
      map (c:
        pol "W-FILE-CHECK-VALUE-ARRAY" c.where
        ("'${c.id}' uses an ARRAY fileCheck.value, which the engine reads as \"any of these candidates\" "
          + "(value.some(deepEqual)), not as \"match this array\""))
      (filter (c: builtins.isList c.fc.value) checks)
      ++ map (c:
        pol "W-FILE-CHECK-PATH-UNSAFE" c.where
        ("'${c.id}' fileCheck.path '${c.fc.path}' is templated, absolute, tilde-prefixed or escaping. "
          + "A path the containment check REACHES fails the run at LAUNCH; one that SKIPS it evaluates "
          + "false forever with no error, burning every iteration. Keep it a plain relative path."))
      (filter (c: unsafePath c.fc.path) checks);

    # Measured, not theorized: a parallel is marked failed if ANY branch
    # aborted, under `all` AND `allSettled` alike, and the enclosing sequence
    # bubbles that and returns. So a repeat with onMaxIterations = "abort"
    # inside a parallel makes every downstream sibling of that parallel
    # UNREACHABLE in exactly the exhaustion case a verify step exists to
    # catch. This defect shipped in a real drain recipe.
    strandedVerifyDiags =
      map (
        e:
          pol "W-ABORT-BRANCH-STRANDS-DOWNSTREAM" e.where
          ("parallel '${e.id}' contains a repeat with onMaxIterations = \"abort\" and has later siblings; "
            + "an aborted branch fails the parallel under every joinPolicy, so those siblings never run "
            + "in the exhaustion case")
      ) (filter (
          e:
            e.tag
            == "parallel"
            && lib.any (d: d.tag == "repeat" && d.node.onMaxIterations == "abort") (
              filter (d: isDescendantOf e.lineage d.lineage) entries
            )
            && lib.any (o:
              length o.lineage
              == length e.lineage
              && lib.take (length e.lineage - 1) o.lineage == lib.take (length e.lineage - 1) e.lineage
              && (head (lib.reverseList o.lineage)).index > (head (lib.reverseList e.lineage)).index)
            entries
        )
        entries);

    diagnostics =
      countDiag
      ++ depthDiags
      ++ dupDiags
      ++ interactiveDiags
      ++ watchRefDiags
      ++ templateDiags
      ++ stopContextDiags
      ++ policyDiags;
  in {
    inherit diagnostics entries stepCount;
    maxDepth =
      lib.foldl' (a: e: let
        d = length e.lineage;
      in
        if d > a
        then d
        else a)
      0
      entries;
    errors = filter (d: d.severity == "error") diagnostics;
    warnings = filter (d: d.severity == "warning") diagnostics;
    engineErrors = filter (d: d.basis == "engine" && d.severity == "error") diagnostics;
  };

  # Convenience: throw on any engine-basis error. `strict` also throws on
  # policy lints, matching contract.jq's `--strict`.
  assertValid = {strict ? false}: workflow: let
    r = analyze workflow;
    fatal =
      if strict
      then r.diagnostics
      else r.errors;
    render = d: "  [${d.basis}] ${d.code} at ${d.where}: ${d.message}";
  in
    if fatal == []
    then workflow
    else
      throw ''
        kiro workflow '${workflow.name}' failed validation (${toString (length fatal)} finding(s)):
        ${concatStringsSep "\n" (map render fatal)}
      '';
}
