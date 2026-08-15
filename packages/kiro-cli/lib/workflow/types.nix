# Typed option surface for the Kiro workflow definition format.
#
# Ground truth is the shipped KAS bundle, not any document: the format
# appears in ZERO public Kiro documentation (194 doc pages, no hits), so the
# engine's own Zod schema plus `src/workflow/validate.ts` are the only spec.
# Constants live in ./engine-limits.json and are shared with the Effect-TS
# port in packages/kiro-cli/schema/ so the two cannot drift from each other.
#
# ── Two shapes, deliberately ────────────────────────────────────────────────
#
# The AUTHORED shape here is not the WIRE shape. `./render.nix` bridges them.
# Every divergence buys a constraint the wire shape cannot express:
#
#   wire                                   authored
#   ────────────────────────────────────   ──────────────────────────────────
#   {type = "step"; ...}                   {step = {...};}
#   stopWhen = "wait.terminal"             stop.when.watchTerminal = "wait"
#   stopWhen = "{{a.output}} contains X"   stop.when.contains = {...}
#   jsonPath = "state.drained"             jsonPath = ["state" "drained"]
#   handler + config (two loose fields)    watcher.github-pr = {...}
#
# ── Why `attrTag` and not the house style ───────────────────────────────────
#
# The settled convention elsewhere in this repo is one wide submodule with a
# `type` enum plus nullable per-variant fields, pruned at render time, with a
# module assertion enforcing shape. That is the right call when the authored
# and wire shapes must match. It is the WRONG call here, because it makes
# every per-variant field optional and defers all shape enforcement to an
# assertion — exactly the failure mode this file exists to prevent.
#
# `lib.types.attrTag` discriminates on WHICH ATTRIBUTE IS SET. That gives,
# for free and at TYPE level rather than assertion level:
#   * exactly one variant (two tags at once is a type error)
#   * per-variant REQUIRED fields (a step with no `agent` is a type error)
#   * an unknown variant is a type error, naming the legal tags
# Verified by evaluation, not by reading: all four rejections fire.
#
# `attrTag` is already the repository convention for mutually exclusive
# credential and secret alternatives (`lib/credentials.nix`). Recursive use of
# it has no prior art here: Nix `let` bindings are recursive, so `nodeType`
# referring to itself through `listOf` resolves lazily; this was smoke-tested
# before the file was written rather than assumed.
#
# ── What this file CANNOT enforce ───────────────────────────────────────────
#
# Anything needing a walk over the whole tree (node caps, id uniqueness,
# orientation, cross-node template references) lives in ./analyze.nix, because
# an option type sees one node at a time and never its siblings or ancestors.
# Anything needing the live filesystem, the agent registry, or the server's
# model catalog is not statically checkable at all and is reported as a
# documented gap rather than guessed at.
#
# ── Strictness ledger: where this type is stricter than engine load ─────────
#
# The default posture is engine fidelity, because rejecting a definition the
# engine RUNS is as much a bug as accepting one it refuses. The house rule for
# departing from it: be stricter only where the engine's acceptance is a SILENT
# failure. These types are deliberately stricter at the sites below. Most obey
# that rule; some move a guaranteed later throw to authoring time; `name` is a
# deliberate label-quality guardrail; empty jsonPath segments are an explicit,
# operator-approved EXCEPTION, flagged as such in their row. This is the
# complete current set:
#
#   fileCheck.jsonPath   a NON-EMPTY list of NON-EMPTY segments; the first
#                        segment rejects a LEADING '$', and every segment
#                        rejects '*' or brackets.
#
#                        '$' is the house-rule case: `"$.drained"` reads a
#                        property literally named `$`, which resolves undefined
#                        so the loop never stops — silent, and expensive.
#
#                        EMPTY SEGMENTS ARE THE EXCEPTION, and it is deliberate
#                        rather than an oversight. The engine ACCEPTS them and
#                        RESOLVES THEM FINE — `walkJsonPath` does
#                        `split(".").filter(s => s.length > 0)` — so a leading
#                        `.done`, a trailing `done.` and an internal
#                        `state..done` all run correctly there. We refuse every
#                        one of them anyway, because this is an authoring and
#                        generation tool whose output is machine-generated:
#                        `state.done` is the expected convention, and a doubled
#                        dot is not a spelling preference but a sign that
#                        whatever produced the path is broken. Surfacing that
#                        beats silently collapsing it. Do NOT "restore engine
#                        fidelity" here — this row exists so a future reader
#                        knows the divergence was chosen, not missed.
#
#                        The ALL-EMPTY path (`""`, `"."`, `"..."`) falls under
#                        the same rejection and is additionally the one empty
#                        case that IS silent in the usual way: the cursor never
#                        leaves the document root, so the check deep-equals the
#                        WHOLE parsed file against `value`, which is not what
#                        any author means by a property check.
#   fileCheck.value      required here although the engine's `z.unknown()` key
#                        accepts omission; omission makes the intended target
#                        impossible to distinguish from an explicit undefined.
#   non-empty strings    fileCheck.path, stop-condition containsText, watcher
#                        refs/URL/ignored authors, artifact values, agent/name,
#                        and step/workflow modelId + effortLevel. The engine
#                        accepts empty strings at load; these either become
#                        silent conditions, guaranteed later lookup failures,
#                        or unusable labels.
#   crux-cr.crId         a NON-EMPTY value must match `^CR-[0-9]+$`, and an
#                        EMPTY one needs a `crRef` beside it. Both move a
#                        guaranteed watch-start throw to authoring time:
#                        `assertValidCrId` for the first, and
#                        "neither `crId` nor `crRef` provided" for the second,
#                        which the engine's Zod refine lets through because it
#                        tests presence while `resolveCrId` tests length.
#   stop.when.contains.template
#                        rejects `{{` and `}}` as INFIXES and also a TRAILING
#                        `}`, all three of which `render.nix` turns into a
#                        stopWhen string the engine REFUSES TO LOAD. An
#                        authored `"{{p.output}}"` renders
#                        `{{{{p.output}}}} contains DONE`; an authored
#                        `"p.output}"` renders `{{p.output}}} contains DONE`,
#                        where the delimiter forms by adjacency at the seam and
#                        the engine's first-`}}` slice is left with
#                        `} contains DONE`. A near miss re-partitions the
#                        expression instead, so the authored `text` is not the
#                        literal compared. A LONE brace ELSEWHERE is still
#                        accepted, because the engine loads it and it only
#                        resolves literally; that stays the
#                        `W-STOP-WHEN-TEMPLATE-BRACES` lint.
#   integral Nix ints    `maxIterations` rejects an integral-valued Nix float
#                        that JavaScript's `Number.isInteger` would accept.
#
# `prompt` and `description` deliberately remain plain strings. A stopWhen
# contains-expression is otherwise accepted verbatim and linted by analyze.nix
# when it would resolve as literal text forever.
{lib}: let
  inherit (lib) mkOption types;

  engine = builtins.fromJSON (builtins.readFile ./engine-limits.json);
  inherit (engine) enums limits;
  syntax = import ./syntax.nix {inherit lib;};

  # ── Cross-field invariants on submodules need `apply`, not the type ──────
  #
  # This cost two wrong attempts and is worth writing down.
  #
  #   `lib.types.addCheck` hooks `check`, which the module system calls on each
  #   raw definition. When a submodule is an option's own type (including
  #   through nullOr/listOf), `fixupOptionType` rebuilds it and discards that
  #   check. Inside an `attrTag` member it instead runs against the raw,
  #   pre-default attrset. Neither position provides the merged value needed
  #   for a reliable cross-field invariant.
  #
  #   Overriding `merge` does not help either, and it fails to the SAME
  #   discard rather than to a missing call. The module system calls
  #   `type.merge` for every defined option — hang an unconditional `throw`
  #   off a plain `types.str` and it fires — but for an option-owned submodule
  #   `fixupOptionType` has already replaced the type object, so the merge
  #   that runs is the REBUILT submodule's, the one that evaluates the nested
  #   option tree. The override never fires because it is no longer attached,
  #   not because nothing is merged. Verified both halves by evaluation.
  #
  # `apply` is the one hook that receives the MERGED value. It lives on the
  # option rather than on the type, so each use site opts in — verified to
  # fire directly, inside an `attrTag` variant, and inside a `listOf` (with
  # an explicit `map`).
  #
  # Passing `null` through untouched keeps this composable with `nullOr`.
  invariant = msg: pred: v:
    if v == null || pred v
    then v
    else throw "kiro workflow: ${msg}";

  # ── Scalar refinements ────────────────────────────────────────────────────

  # The engine types every id as a bare `z.string()` and enforces no charset,
  # so an id may legally contain dots, spaces, or be empty. We do NOT tighten
  # that in general — rejecting a definition the engine accepts is its own
  # kind of wrong. The one real lexical constraint is indirect and applies
  # only to a watch id NAMED BY a stopWhen (see `watchIdRef` below).
  nodeId = types.str;

  nonEmptyStr = types.addCheck types.str (s: s != "") // {description = "non-empty string";};

  # `parseStopWhen` rejects a watch id that is empty, contains '.', or contains
  # whitespace. An id violating this is legal ON THE NODE and merely
  # unreferenceable, so the check belongs on the REFERENCE, not the definition.
  #
  # It does NOT reject a lone brace, and neither do we. Re-read from the
  # bundle: the only brace rule is a whole-string `includes("{{")` /
  # `includes("}}")` test that runs before the suffix check, so `a{b.terminal`
  # parses and resolves fine against a node whose id is `a{b`. An earlier
  # version of this check rejected any brace and was therefore stricter than
  # the engine for no benefit — see the strictness ledger below for the rule
  # that decides when being stricter IS warranted.
  watchIdRef =
    types.addCheck types.str
    (s:
      s
      != ""
      && !(lib.hasInfix "." s)
      && !(lib.hasInfix "{{" s)
      && !(lib.hasInfix "}}" s)
      && !(syntax.hasJsWhitespace s))
    // {description = "watch id referenceable from stopWhen (non-empty, no '.', no whitespace, no '{{' or '}}')";};

  # A `{{...}}` reference expression, WITHOUT its delimiters — `render.nix`
  # adds them, which is what pins the template to offset 0.
  #
  # A LONE brace is ACCEPTED, for engine fidelity: `parseStopWhen` slices on
  # the first `}}` rather than applying the reference regex, so
  # `{{a{b}} contains DONE` loads and merely resolves as literal text forever.
  # Empty and undeclared bare expressions behave the same way. All three are
  # `policy`-basis lints in analyze.nix, not option-boundary throws.
  #
  # A `{{` or `}}` INFIX is REFUSED, because the render step already owns those
  # two delimiters and an authored copy re-enters the grammar it is being
  # wrapped into. The natural mistake is pasting the wire spelling into a field
  # that wraps: `template = "{{p.output}}"` renders
  # `{{{{p.output}}}} contains DONE`, whose first `}}` sits at offset 12, so
  # the remainder is `}} contains DONE`, which fails the ` contains ` test and
  # the engine REFUSES TO LOAD the definition. Where a delimiter does not
  # hard-fail the load it re-partitions the expression instead — a template of
  # `a}} contains b` renders wire the engine reads as literal `b}} contains
  # DONE`, so the authored `text` field is not what gets compared. Either way
  # the authored value is not the one that runs.
  #
  # A TRAILING `}` is refused for the same reason, and the infix rule ALONE
  # does not cover it: the delimiter can also form by ADJACENCY at the seam
  # `render.nix` creates when it appends its own `}}`. `template = "p.output}"`
  # carries no `}}` of its own, renders `{{p.output}}} contains DONE`, and the
  # engine's `input.indexOf("}}")` takes the FIRST occurrence — so it reads the
  # template as `{{p.output}}` and is left with `} contains DONE`, which fails
  # `startsWith(" contains ")`. REFUSED AT LOAD, exactly like the infix case.
  #
  # Found by sweeping every template of length 1-3 over the alphabet
  # `[a { } . space]`: 155 values, of which the infix rule accepted 24 whose
  # rendered string the engine cannot read back, and every one of the 24 ended
  # in `}`. With this suffix rule the sweep returns zero. The invariant it
  # restores is worth stating plainly, because it is the one this type owes
  # `render.nix`: EVERY value accepted here must render to a wire string that
  # parses back to the same template and the same text.
  #
  # A lone brace ANYWHERE ELSE still passes — `a{b` and `a}b` both render and
  # read back intact — so this stays narrower than "no braces at all".
  #
  # This port's own `parse.nix` is the cheapest proof: without these rules
  # `render.nix` emits stopWhen strings the wire reader sitting beside it
  # throws on.
  referenceExpr =
    types.addCheck types.str
    (s: !(lib.hasInfix "{{" s) && !(lib.hasInfix "}}" s) && !(lib.hasSuffix "}" s))
    // {description = "reference expression carrying neither '{{' nor '}}' and not ending in '}' (render.nix adds the delimiters)";};

  # `jsonPath` is NOT JSONPath. The engine does `split(".")` then a plain
  # property walk, so "$.drained" reads a property literally named "$",
  # resolves undefined, and the loop never stops — silently, forever. Taking
  # a SEGMENT LIST instead of a string makes that spelling unrepresentable.
  #
  # Segments are additionally constrained so the list form cannot smuggle the
  # string form back in: a segment holding a '.' would render into two
  # segments, and brackets / wildcards are JSONPath spellings that silently
  # resolve to undefined. '$' is rejected only at the path head; in a later
  # segment it is an ordinary property-name prefix to the engine.
  #
  # `s != ""` is the empty-segment rule, and it is the one place in this file
  # where being stricter than the engine is NOT justified by a silent failure —
  # the engine filters empties and resolves the path correctly. See its ledger
  # row for why it is refused here regardless.
  #
  # That last part is a HARD rejection at type level, not a `policy`-basis
  # lint — a definition using it does not evaluate at all, and no `strict`
  # toggle relaxes it. Saying "policy" here would be wrong twice over: in this
  # codebase `policy` names an advisory the analyzer emits and the engine
  # accepts, and this is neither advisory nor analyzer-side. It is one of the
  # deliberate stricter-than-engine rules listed in the strictness ledger at
  # the top of this file, and it is there because `"$.drained"` is the single
  # most expensive typo in this format: legal JSON, accepted by the engine,
  # and it hangs the loop forever without an error.
  #
  # Uncounted on purpose. This sentence used to say "one of the THREE", which
  # was true only against the ledger as it stood when it was written; the
  # ledger has grown twice since and the count went stale both times without
  # anything catching it. A cross-reference that names the list does not need
  # to also size it.
  # Spelled out as predicates rather than one regex on purpose. Nix regexes
  # are POSIX ERE, where a backslash inside a bracket expression is a LITERAL
  # backslash rather than an escape — so `[^.$*\[\]]+` does not mean what it
  # looks like, and the version of this check that used it rejected every
  # ordinary property name including "verdict".
  jsonPathSegment =
    types.addCheck types.str
    (s:
      s
      != ""
      && !(lib.hasInfix "." s)
      && !(lib.hasInfix "*" s)
      && !(lib.hasInfix "[" s)
      && !(lib.hasInfix "]" s))
    // {description = "non-empty property name (no '.', '*' or brackets — this is NOT JSONPath)";};

  # addCheck IS correct here — a list definition is its own final value.
  #
  # `xs != []` is the all-empty rule from the ledger; `jsonPathSegment` above
  # covers the leading, trailing and internal empties. The test-only wire
  # reader in ./parse.nix collapses empty wire segments, so `""`, `"."` and
  # `"..."` all arrive here as `[]` and are refused at this line; the engine
  # would walk that to the document root and compare the whole file.
  jsonPathType =
    types.addCheck (types.listOf jsonPathSegment) (xs: xs != [] && !(lib.hasPrefix "$" (builtins.head xs)))
    // {description = "non-empty list of property-name segments whose first segment does not start with '$', joined with '.' at render time";};

  # Positive integer, exclusive of zero. The engine's `.int().positive()`.
  positiveInt = types.ints.between 1 limits.maxRepeatIterations;

  # `pollIntervalSec` below minPollIntervalSec is a hard config error in the
  # handler registry, not a clamp.
  pollIntervalSec =
    types.addCheck types.numbers.positive (n: n >= engine.watch.minPollIntervalSec)
    // {description = "seconds >= ${toString engine.watch.minPollIntervalSec} (engine minPollIntervalSec)";};

  # ── Stop conditions ───────────────────────────────────────────────────────

  fileCheckType = types.submodule {
    options = {
      path = mkOption {
        type = nonEmptyStr;
        description = ''
          Path to the JSON file to poll, RELATIVE to the workspace root.

          Keep it relative. The engine resolves a relative path against the
          workspace root by construction, and step agents run with that same
          cwd, so the writing step and the check agree with no interpolation.
          An absolute or escaping path fails the run at LAUNCH; a path that
          skips the containment check instead evaluates false FOREVER, with
          no error, burning every iteration the loop has.

          A leading `{{template}}` is what skips that check. A templated path
          is nevertheless ACCEPTED here and rendered through unchanged —
          `analyze.nix` flags it as the `policy`-basis lint
          `W-FILE-CHECK-PATH-UNSAFE` instead.

          Accepting it is forced, not a preference: the vendor's own
          `feature-pipeline` and `ralph` recipes both ship templated
          `fileCheck` paths, so rejecting them would reject a corpus the
          engine ships and shape-parses. Whether the engine reaches the
          containment check at all depends on whether the leading reference
          happens to be a DECLARED input — a declared one is substituted first
          and then checked, an undeclared one skips validation entirely — which
          is exactly the kind of run-dependent behavior a static schema should
          warn about rather than pretend to decide.
        '';
      };
      jsonPath = mkOption {
        type = jsonPathType;
        example = ["drained"];
        description = ''
          Property path as SEGMENTS, joined with '.' at render time.

          Not JSONPath — no leading '$' on the path, and no brackets or
          wildcards in any segment. `["drained"]` renders to `"drained"`,
          `["state" "$value"]` to `"state.$value"`.
        '';
      };
      value = mkOption {
        type = types.anything;
        description = ''
          Value the resolved property must deep-equal.

          An ARRAY here means "any of these candidates" to the engine
          (`value.some(c => deepEqual(resolved, c))`), NOT "match this
          array". `analyze.nix` flags an array value for that reason.
        '';
      };
    };
  };

  # The engine refines "at least one of the three", and multiple may be set
  # simultaneously — so this is a non-empty subset, not a tagged union, and
  # attrTag would be the wrong tool. The emptiness rule is a type check
  # rather than an assertion so it fires at the node rather than globally.
  stopConditionType = types.submodule {
    options = {
      containsText = mkOption {
        type = types.nullOr nonEmptyStr;
        default = null;
        description = "Stop when the captured output contains this literal.";
      };
      fileCheck = mkOption {
        type = types.nullOr fileCheckType;
        default = null;
        description = "Stop when a JSON file's property deep-equals a value.";
      };
      completionSignal = mkOption {
        type = types.nullOr (types.enum enums.completionSignal);
        default = null;
        description = ''
          Stop when the step emits this completion signal.

          Vendor-real — the bundled `goal` recipe uses it verbatim — but
          absent from BOTH vendor authoring documents, and no run has ever
          confirmed the engine acts on it. See probe P-06.

          Tested FIRST and returns, so setting it alongside containsText or
          fileCheck makes those two dead. `analyze.nix` flags that.
        '';
      };
    };
  };

  # The engine's `.refine`, as an `apply` because it spans fields. Attached
  # at every site that takes a stop condition.
  stopConditionInvariant =
    invariant
    "a stop condition must set at least one of containsText, fileCheck, completionSignal"
    (c: c.containsText != null || c.fileCheck != null || c.completionSignal != null);

  # `stopWhen` is a bare string in the engine's Zod, with a real grammar
  # enforced separately by parseStopWhen. There are EXACTLY two shapes and
  # nothing else parses, so modelling them as a tagged union makes every
  # unparseable string unrepresentable — including the lexical rules
  # (' contains ' with exactly one space each side, template at offset 0,
  # non-empty literal) that no document states.
  stopWhenType = types.attrTag {
    watchTerminal = mkOption {
      type = watchIdRef;
      description = ''
        Stop when the named `watch` node reaches a terminal state.
        Renders to `"<watchId>.terminal"`.

        The id must name a watch node somewhere in the tree; `analyze.nix`
        resolves it. There is no lineage requirement — the watch may sit
        outside the repeat, which is accepted and is usually a bug (P-04).
      '';
    };
    contains = mkOption {
      description = ''
        Stop when a template's resolved value contains a literal.
        Renders to `"{{<template>}} contains <text>"`.
      '';
      type = types.submodule {
        options = {
          template = mkOption {
            type = referenceExpr;
            example = "reviewer.output";
            description = ''
              Reference expression WITHOUT the braces — they are added at
              render time, which is what pins the template to offset 0.

              Stop-context rules differ from prompt rules: `previous.output`
              is ALWAYS rejected here, self-reference is allowed, and a
              repeat may additionally reference producers inside its own
              body.
            '';
          };
          text = mkOption {
            type = nonEmptyStr;
            description = ''
              Literal needle. Matched raw against CAPTURED OUTPUT — under a
              cheap model the capture is often empty, so the condition can
              never match and the loop silently runs to maxIterations.
            '';
          };
        };
      };
    };
  };

  # ── Watch handlers ────────────────────────────────────────────────────────
  #
  # The wire shape is two loose fields (`handler: string`, `config: record`).
  # Exactly two handlers ship, each with its own Zod config schema, so a
  # tagged union recovers per-handler field checking that the wire shape
  # throws away. Both handler schemas are non-strict (unknown keys tolerated)
  # and both share a passthrough base carrying the two interval fields.

  watchBaseOptions = {
    pollIntervalSec = mkOption {
      type = types.nullOr pollIntervalSec;
      default = null;
      description = ''
        Poll interval. OMITTING it falls back to
        ${toString engine.watch.defaultPollIntervalSec}s; supplying a value
        below ${toString engine.watch.minPollIntervalSec}s is a hard error,
        not a clamp, so the type refuses it here rather than letting the run
        fail at watch-config validation.

        (`resolvePollIntervalSec` does carry a `>= minimum` guard that looks
        like a fallback, but its own comment notes the case is already
        enforced by `validateConfig`, which throws — so that branch is
        unreachable for a below-minimum value.)
      '';
    };
    commandTimeoutSec = mkOption {
      type = types.nullOr types.numbers.positive;
      default = null;
      description = "Per-poll command timeout.";
    };
  };

  watcherType = types.attrTag {
    "github-pr" = mkOption {
      description = "Watch a GitHub pull request. Requires one of prRef or url.";
      apply = invariant "github-pr watcher requires at least one of prRef, url" (c: c.prRef != null || c.url != null);
      type = types.submodule {
        options =
          watchBaseOptions
          // {
            prRef = mkOption {
              type = types.nullOr nonEmptyStr;
              default = null;
              description = "Path to a JSON file naming the PR, resolved inside the workspace roots at POLL time.";
            };
            url = mkOption {
              type = types.nullOr nonEmptyStr;
              default = null;
              description = "PR url (`https://<host>/<owner>/<repo>/pull/<n>`) or a bare 1-10 digit number.";
            };
            includeOwnActivity = mkOption {
              type = types.nullOr types.bool;
              default = null;
              description = "Count the running identity's own activity as new activity.";
            };
            ignoreAuthors = mkOption {
              type = types.nullOr (types.listOf nonEmptyStr);
              default = null;
              description = "Authors whose activity never counts. NOT template-interpolated — only string values are.";
            };
          };
      };
    };
    "crux-cr" = mkOption {
      description = "Watch a code review. Requires a crRef or a non-empty crId.";
      # Tests USEFULNESS, not presence, which is where this parts company with
      # the engine's Zod refine (`crRef !== undefined || crId !== undefined`).
      # `resolveCrId` skips an id it considers empty and then throws
      # "crux-cr: neither `crId` nor `crRef` provided", so `crId = ""` alone
      # loads and is guaranteed to die at watch start. `crRef` + `crId = ""`
      # really does resolve and is accepted.
      apply =
        invariant "crux-cr watcher requires a crRef or a NON-EMPTY crId"
        (c: c.crRef != null || (c.crId != null && c.crId != ""));
      type = types.submodule {
        options =
          watchBaseOptions
          // {
            crRef = mkOption {
              type = types.nullOr nonEmptyStr;
              default = null;
              description = "Path to a JSON file naming the CR, resolved inside the workspace roots at POLL time.";
            };
            crId = mkOption {
              # The pattern comes from the shared engine-limits.json and is
              # stored UNANCHORED, because `builtins.match` is whole-string by
              # definition while the Effect port has to wrap it in ^...$. Do not
              # re-spell it here; that duplication drifted once already.
              type =
                types.nullOr (types.addCheck types.str (s: s == "" || builtins.match engine.watch.crIdPattern s != null)
                  // {description = "empty, or a CR id matching ^${engine.watch.crIdPattern}$";});
              default = null;
              description = "CR id. Empty falls back to crRef, matching resolveCrId, so an empty value is only usable with a crRef beside it.";
            };
          };
      };
    };
  };

  # ── The node tree ─────────────────────────────────────────────────────────
  #
  # Self-referential through `listOf nodeType`; Nix laziness carries it.

  nodeType = types.attrTag {
    step = mkOption {
      description = "Run one agent turn. The only node type that costs against the ${toString limits.maxStepNodes}-step cap.";
      type = types.submodule {
        options = {
          id = mkOption {
            type = nodeId;
            description = "Unique across the WHOLE tree, not just among siblings.";
          };
          agent = mkOption {
            type = nonEmptyStr;
            description = ''
              Agent profile name, resolved live against disk at LAUNCH.

              Not checkable here. Note the engine's two tiers disagree: the
              structural pass rejects only a builtin-mode agent, while an
              agent the registry does not know at all passes structurally and
              fails at launch. The vendor guide claims unknown names fail
              validation; they do not.
            '';
          };
          prompt = mkOption {
            type = types.str;
            description = ''
              REQUIRED. The engine tests only `=== undefined`, so an empty
              string passes both the schema and the validator.

              The step-level `input` field was REMOVED and is rejected loudly
              by both the authored option type and the wire parser. There is no
              option for it here; it cannot reach `analyze.nix`.
            '';
          };
          artifacts = mkOption {
            type = types.attrsOf nonEmptyStr;
            default = {};
            description = ''
              Logical name -> path. The namespace is FLAT and GLOBAL, so the
              reference form is `{{artifacts.<name>}}` — never
              `{{id.artifactKey}}`, which classifies as a bare reference and
              is silently left literal.

              Values are themselves interpolated. Duplicate names across
              steps are legal and resolve last-writer-wins.
            '';
          };
          captureOutput = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = ''
              Defaults to TRUE. The engine's producer test is
              `captureOutput !== false`, so only an explicit `false` opts out
              — and opting out makes `{{<id>.output}}` a validation error for
              every consumer.
            '';
          };
          completion = mkOption {
            type = types.nullOr stopConditionType;
            default = null;
            apply = stopConditionInvariant;
            description = ''
              Makes the step INTERACTIVE: it parks and waits for a user
              message rather than the engine driving the next turn.

              A step declaring this may not appear anywhere beneath a
              `parallel` — checked against the whole lineage, not just the
              parent. `analyze.nix` enforces it. This is the only node
              orientation rule the engine has.
            '';
          };
          modelId = mkOption {
            type = types.nullOr nonEmptyStr;
            default = null;
            description = ''
              Overrides the workflow default. Deliberately a STRING, not an
              enum: the model catalog is fetched from the control plane at
              runtime and the compiled-in default is empty, so no literal
              union can be derived and one would reject valid ids.

              `"auto"` means unset. An unknown id is a load-time WARNING that
              never rejects, and then fails the step mid-run at session
              creation.
            '';
          };
          effortLevel = mkOption {
            type = types.nullOr nonEmptyStr;
            default = null;
            description = ''
              Also a string, for the same reason: the legal set is PER-MODEL
              and server-supplied, read out of each model's request-field
              JSON Schema. `low|medium|high|xhigh` is what the vendor's own
              prose documents and what real definitions use, but the wire
              enum carries a fifth value and nothing filters the server's
              list, so an enum here could reject a level the server accepts.

              Never validated at load time. An effort invalid for the
              resolved model is SILENTLY replaced by that model's default.
            '';
          };
        };
      };
    };

    sequence = mkOption {
      description = "Run children strictly serially, stopping at the first failed/aborted/paused child.";
      type = types.submodule {
        options = {
          id = mkOption {type = nodeId;};
          steps = mkOption {
            type = types.listOf nodeType;
            description = "Children. An empty list is legal to the engine and runs nothing; flagged as a lint.";
          };
        };
      };
    };

    repeat = mkOption {
      description = "Loop over children. A do-while: the stop condition is evaluated only AFTER an iteration.";
      type = types.submodule {
        options = {
          id = mkOption {type = nodeId;};
          steps = mkOption {type = types.listOf nodeType;};
          maxIterations = mkOption {
            type = positiveInt;
            description = "1..${toString limits.maxRepeatIterations} inclusive.";
          };
          onMaxIterations = mkOption {
            type = types.enum enums.onMaxIterations;
            description = ''
              REQUIRED — the engine's Zod has no default.

              `"continue"` is the quiet failure: it marks an EXHAUSTED repeat
              *completed*, so unfinished work scores as success. `"pause"`
              re-pauses immediately on resume and a paused run cannot be
              retried. Both are flagged as lints; `"abort"` is the safe
              choice, with the caveat that an aborted branch fails its
              enclosing parallel under BOTH `all` and `allSettled`, which can
              strand a downstream verify step.
            '';
          };
          stop = mkOption {
            type = types.nullOr stopFormType;
            default = null;
            description = ''
              At most one stop form. `null` means neither, which IS legal —
              the engine rejects only defining BOTH, and the vendor's own
              `autoresearch` recipe ships with neither. Both vendor authoring
              documents claim exactly one is required; they are wrong, and a
              schema enforcing that would reject a vendor-canonical recipe.

              A repeat with no stop form runs to maxIterations with nothing
              reporting why, so it is flagged as a lint rather than an error.
            '';
          };
        };
      };
    };

    parallel = mkOption {
      description = "Run branches concurrently. There is NO concurrency semaphore — branches all start in the same tick.";
      type = types.submodule {
        options = {
          id = mkOption {type = nodeId;};
          branches = mkOption {type = types.listOf nodeType;};
          joinPolicy = mkOption {
            type = types.enum enums.joinPolicy;
            description = ''
              REQUIRED.

              `"any"` CANCELS its siblings on the first completion, so a
              first-completion drain is unusable. `"all"` aborts every
              sibling on the first branch FAILURE — the same destructive
              semantics through the other door. `"allSettled"` is never
              passed the controllers array and so structurally cannot cancel;
              it is the right default for independent branches. `all` and
              `any` are flagged as lints.
            '';
          };
        };
      };
    };

    watch = mkOption {
      description = "Poll an external system until it goes terminal. Always a producer; never counts against the step cap.";
      type = types.submodule {
        options = {
          id = mkOption {type = nodeId;};
          watcher = mkOption {
            type = watcherType;
            description = "Handler and its config, as one tagged pair. Rendered to the wire's separate `handler` + `config` fields.";
          };
          idleTimeoutSec = mkOption {
            type = types.nullOr types.numbers.positive;
            default = null;
            description = ''
              No default. Omitted, the watch polls FOREVER, bounded only by
              the enclosing repeat's maxIterations and by run cancellation.

              Hitting the timeout is deliberately indistinguishable from a
              real terminal poll: it sets watchTerminal, synthesizes an
              `{"outcome":"idle-timeout"}` payload, and emits a
              `terminal-state` outcome. So this is the escape hatch that lets
              `<id>.terminal` eventually fire against a dead external system.
            '';
          };
        };
      };
    };
  };

  # `stop` is one level of tagging over the two stop FORMS, which is what
  # makes "at most one" structural instead of an assertion.
  stopFormType = types.attrTag {
    condition = mkOption {
      type = stopConditionType;
      apply = stopConditionInvariant;
      description = "The `stopCondition` form — containsText / fileCheck / completionSignal.";
    };
    when = mkOption {
      type = stopWhenType;
      description = "The `stopWhen` form — a watch-terminal or contains expression.";
    };
  };

  # ── The workflow root ─────────────────────────────────────────────────────

  workflowType = types.submodule {
    options = {
      name = mkOption {
        type = nonEmptyStr;
        description = ''
          Free-form. NOT required to match the filename stem — the recipe
          name a user sees is derived from the STEM, and `name` is never
          compared to it for a workspace recipe. Divergence surfaces later as
          a run labelled differently from the recipe that launched it, so
          `render.nix` warns when they disagree.
        '';
      };
      description = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      inputs = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = ''
          Declaration map only — name -> free-form type hint. The engine
          NEVER merges these in as defaults; they are the allow-list for the
          undeclared-reference warning and nothing else. A declared input
          that the caller does not supply stays LITERAL in the prompt.

          Values must be strings; a number or nested object fails the
          engine's Zod. The vendor uses a closed vocabulary of "string",
          "prompt" and "file", but nothing consumes the hint.
        '';
      };
      steps = mkOption {
        type = types.listOf nodeType;
        description = "Top-level nodes, run strictly serially.";
      };
      modelId = mkOption {
        type = types.nullOr nonEmptyStr;
        default = null;
        description = "Default for every step. Cascade is step > workflow > parent session, with `auto` skipped at each tier.";
      };
      effortLevel = mkOption {
        type = types.nullOr nonEmptyStr;
        default = null;
        description = "Default for every step. Same cascade, but `auto` is NOT a sentinel here — it is carried through literally.";
      };
      # planRevision is deliberately absent. The runner overwrites it with 0
      # at creation, so an authored value is discarded; it is a runtime
      # pairing token between workflow-state.json and workflow-definition.json,
      # never authored input.
    };
  };
in {
  inherit
    engine
    fileCheckType
    nodeType
    stopConditionType
    stopFormType
    stopWhenType
    watcherType
    workflowType
    ;
}
