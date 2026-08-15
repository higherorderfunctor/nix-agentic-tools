# Eval-time conformance gate for the Kiro workflow typed schema
# (packages/kiro-cli/lib/workflow/).
#
# Three kinds of assertion, and all three are load-bearing:
#
#   ACCEPT   a definition the engine accepts must evaluate. Rejecting what
#            the engine runs is as much a bug as the reverse, and it is the
#            failure mode a hand-written schema falls into by default.
#   REJECT   a definition the engine refuses must fail to evaluate. Uses
#            `tryEval` + `deepSeq`; the deepSeq is load-bearing, because a
#            submodule type error only surfaces when the value is FORCED and
#            a shallow tryEval passes silently.
#   VENDOR   the seven recipes inlined in the engine bundle must be
#            EXPRESSIBLE in this schema: each one must read into the authored
#            shape, force clean through the option types, and analyze clean of
#            engine-basis errors. The engine shape-parses these at module init
#            but does not structurally analyze them until launch. They are the
#            highest-fidelity corpus available, but a failure warrants checking
#            both the local rule and the vendor recipe.
#
# The wire reader those recipes go through — `packages/kiro-cli/lib/workflow/
# parse.nix` — is TEST-ONLY SCAFFOLDING and is imported by path below, because
# the library barrel deliberately does not export it. Authoring runs one way
# (authored attrset -> wire JSON); nothing in this repo consumes the wire
# format, and nothing here asserts that reading a recipe and rendering it back
# reproduces the file it came from.
#
# A tryEval-based reject harness needs shape-matched positive controls, because
# "threw for the reason I meant" and "threw for an unrelated reason" are
# indistinguishable. `accept-baseline` controls step-shaped rejects; explicit
# empty repeat and parallel controls force the collection shapes used by their
# reject families; the watch section carries its own accepted watch control.
{
  lib,
  pkgs,
  ...
}: let
  W = import ../packages/kiro-cli/lib/workflow {inherit lib;};

  # Test-only scaffolding, imported by path rather than through the barrel —
  # see the header. This is the ONLY consumer of it in the repository.
  parse = import ../packages/kiro-cli/lib/workflow/parse.nix {inherit lib;};

  eval = wf:
    (lib.evalModules {
      modules = [
        {options.workflow = lib.mkOption {type = W.types.workflowType;};}
        {workflow = wf;}
      ];
    })
    .config
    .workflow;

  forces = wf: (builtins.tryEval (builtins.deepSeq (eval wf) true)).success;

  mkTest = name: assertion:
    pkgs.runCommand "kiro-workflow-${name}" {} ''
      ${
        if assertion
        then ''echo "PASS: ${name}" > $out''
        else throw "FAIL: ${name}"
      }
    '';

  accept = name: wf: mkTest "accept-${name}" (forces wf);
  reject = name: wf: mkTest "reject-${name}" (!(forces wf));

  codesOf = wf: map (d: d.code) (W.analyze.analyze (eval wf)).diagnostics;
  messagesFor = wf: code:
    map (d: d.message) (builtins.filter (d: d.code == code) (W.analyze.analyze (eval wf)).diagnostics);
  whereFor = wf: code:
    map (d: d.where) (builtins.filter (d: d.code == code) (W.analyze.analyze (eval wf)).diagnostics);
  emits = name: wf: code: mkTest "emits-${name}" (lib.elem code (codesOf wf));
  silentOn = name: wf: code: mkTest "silent-${name}" (!(lib.elem code (codesOf wf)));

  # Node constructors. Each supplies the minimum the option types demand and
  # takes an `extra` overlay for the ONE field a fixture is about, so a
  # positive fixture and its silent control differ in exactly that field and
  # nothing else. `repeat` and `parallel` carry a child by default because an
  # empty collection is itself a diagnosed condition.
  step = id: extra: {
    step =
      {
        inherit id;
        agent = "ag";
        prompt = "p";
      }
      // extra;
  };
  repeat = id: extra: {
    repeat =
      {
        inherit id;
        maxIterations = 2;
        onMaxIterations = "abort";
        steps = [(step "s" {})];
      }
      // extra;
  };
  parallel = id: extra: {
    parallel =
      {
        inherit id;
        joinPolicy = "allSettled";
        branches = [(step "b" {})];
      }
      // extra;
  };
  wrap = steps: {
    name = "w";
    inherit steps;
  };
  baseline = wrap [(step "a" {})];

  # The authored stopWhen contains-form, with the template as the ONLY
  # variable. Every fixture below that exercises the template rule differs in
  # nothing else, so the shape is written once and each of them doubles as the
  # others' shape-matched control.
  stopWhenTemplate = template:
    wrap [
      (repeat "r" {
        stop.when.contains = {
          inherit template;
          text = "DONE";
        };
      })
    ];

  # A template the option type refuses, paired with the wire string `render.nix`
  # builds from it: the string must be exactly what is expected AND must fail to
  # read back, which is the whole justification for refusing the template.
  renderedStopWhenIsUnparseable = template: expected: let
    wire = W.render.renderStopWhen {
      contains = {
        inherit template;
        text = "DONE";
      };
    };
  in
    wire
    == expected
    && !(builtins.tryEval (builtins.deepSeq (parse.parseStopWhen "probe" wire) true)).success;

  # Same idea for the fileCheck jsonPath family: the segment list is the ONLY
  # variable, so `accept-jsonpath-dollar-after-head` is the shape-matched
  # positive control for every `reject-jsonpath-*` fixture below it.
  jsonPathFixture = segments:
    wrap [
      (step "a" {
        completion.fileCheck = {
          path = "p.json";
          jsonPath = segments;
          value = true;
        };
      })
    ];

  # The same idea once more for the two fileCheck lints: `path` and `value` are
  # each the only variable in their family, so every positive below is its own
  # control's twin.
  fileCheckPath = path:
    wrap [
      (step "a" {
        completion.fileCheck = {
          inherit path;
          jsonPath = ["done"];
          value = true;
        };
      })
    ];
  fileCheckValue = value:
    wrap [
      (step "a" {
        completion.fileCheck = {
          path = "state.json";
          jsonPath = ["done"];
          inherit value;
        };
      })
    ];

  # One artifact reference, moved across the declaring step. `artifactBefore`
  # is the shape-matched silent control for BOTH artifact lints: the name is
  # declared (so not `UNKNOWN`) and the declarer runs first (so not
  # `NOT-PRECEDING`).
  artifactBefore = wrap [
    (step "p" {artifacts.report = "r.json";})
    (step "a" {prompt = "see {{artifacts.report}}";})
  ];
  artifactAfter = wrap [
    (step "a" {prompt = "see {{artifacts.report}}";})
    (step "p" {artifacts.report = "r.json";})
  ];

  # Shared by the `accept-empty-*` controls and the `emits-empty-*` fixtures:
  # the same definition must both FORCE and be flagged, and writing it twice
  # would let the two drift apart.
  emptyParallel = wrap [(parallel "p" {branches = [];})];
  emptyRepeat = wrap [(repeat "r" {steps = [];})];

  unicodeWhitespaceWatchId = builtins.fromJSON "\"wait\\u00a0for\\u00a0it\"";

  # ── vendor corpus ─────────────────────────────────────────────────────────
  vendorDir = ./fixtures/kiro-workflows/vendor;
  vendorNames = lib.attrNames (builtins.readDir vendorDir);

  vendorTests = lib.listToAttrs (map (
      entry: let
        stem = lib.removeSuffix ".workflow.json" entry;
        raw = builtins.fromJSON (builtins.readFile (vendorDir + "/${entry}"));
        authored = eval (parse.fromAttrs raw);
        analysis = W.analyze.analyze authored;
      in
        lib.nameValuePair "kiro-workflow-vendor-${stem}"
        (mkTest "vendor-${stem}" (
          # Two things, and both are about the SCHEMA rather than about bytes:
          # the recipe is expressible in the option types (the deepSeq is what
          # forces every leaf — a submodule type error is invisible until the
          # value is forced), and it carries no engine-basis error. Rendering is
          # forced as well, so a render throw on real vendor input is caught
          # here; the rendered value is NOT compared against the file, because
          # reproducing the input is not a property this schema offers.
          builtins.deepSeq authored
          (builtins.deepSeq (W.render.toAttrs authored)
            (analysis.engineErrors == []))
        ))
    )
    vendorNames);
in
  vendorTests
  // {
    # The positive control for step-shaped reject fixtures.
    kiro-workflow-accept-baseline = accept "baseline" baseline;

    # Variant controls for reject fixtures that intentionally use empty child
    # collections. A non-empty vendor recipe cannot prove these shapes remain
    # valid.
    kiro-workflow-accept-empty-parallel = accept "empty-parallel" emptyParallel;
    kiro-workflow-accept-empty-repeat = accept "empty-repeat" emptyRepeat;

    # ── ACCEPT: things the engine permits and a naive schema would refuse ───
    #
    # Every one of these was a real temptation to over-constrain.
    kiro-workflow-accept-repeat-no-stop-form =
      accept "repeat-no-stop-form"
      (wrap [
        {
          repeat = {
            id = "r";
            maxIterations = 3;
            onMaxIterations = "abort";
            steps = [(step "s" {})];
          };
        }
      ]);
    kiro-workflow-accept-max-iterations-at-ceiling =
      accept "max-iterations-at-ceiling"
      (wrap [
        {
          repeat = {
            id = "r";
            maxIterations = 1000;
            onMaxIterations = "abort";
            steps = [(step "s" {})];
          };
        }
      ]);
    kiro-workflow-accept-nested-repeats =
      accept "nested-repeats"
      (wrap [
        {
          repeat = {
            id = "outer";
            maxIterations = 2;
            onMaxIterations = "abort";
            steps = [
              {
                repeat = {
                  id = "inner";
                  maxIterations = 2;
                  onMaxIterations = "abort";
                  steps = [(step "s" {})];
                };
              }
            ];
          };
        }
      ]);
    kiro-workflow-accept-empty-id = accept "empty-id" (wrap [(step "" {})]);
    kiro-workflow-accept-empty-description = accept "empty-description" (baseline // {description = "";});
    kiro-workflow-accept-empty-prompt = accept "empty-prompt" (wrap [
      {
        step = {
          id = "a";
          agent = "ag";
          prompt = "";
        };
      }
    ]);
    # Pins an INTERNAL implementation detail of the test-only wire reader, not
    # a supported behavior: it collapses empty wire segments the way the engine
    # does so a wire document carrying a redundant dot still reads. The
    # authored surface refuses all four spellings outright — see the
    # `reject-jsonpath-*-empty-segment` fixtures directly below.
    kiro-workflow-parse-normalizes-jsonpath-empty-segments = mkTest "parse-normalizes-jsonpath-empty-segments" (
      let
        parsed = eval (parse.fromAttrs {
          name = "w";
          steps = [
            {
              type = "step";
              id = "a";
              agent = "ag";
              prompt = "p";
              completion.fileCheck = {
                path = "state.json";
                jsonPath = ".state..done.";
                value = true;
              };
            }
          ];
        });
        parsedPath = (builtins.elemAt parsed.steps 0).step.completion.fileCheck.jsonPath;
        renderedPath = (builtins.elemAt (W.render.toAttrs parsed).steps 0).completion.fileCheck.jsonPath;
      in
        parsedPath == ["state" "done"] && renderedPath == "state.done"
    );
    kiro-workflow-accept-jsonpath-dollar-after-head =
      accept "jsonpath-dollar-after-head"
      (jsonPathFixture ["state" "$value"]);

    # ── REJECT: per-node type rules ────────────────────────────────────────
    kiro-workflow-reject-two-tags =
      reject "two-tags"
      (wrap [
        {
          step = {
            id = "a";
            agent = "ag";
            prompt = "p";
          };
          sequence = {
            id = "s";
            steps = [];
          };
        }
      ]);
    kiro-workflow-reject-unknown-tag = reject "unknown-tag" (wrap [{fanout = {id = "a";};}]);
    kiro-workflow-reject-step-missing-prompt = reject "step-missing-prompt" (wrap [
      {
        step = {
          id = "a";
          agent = "ag";
        };
      }
    ]);
    kiro-workflow-reject-removed-input-field =
      reject "removed-input-field"
      (wrap [
        {
          step = {
            id = "a";
            agent = "ag";
            prompt = "p";
            input = "x";
          };
        }
      ]);
    kiro-workflow-reject-removed-input-field-on-wire = mkTest "reject-removed-input-field-on-wire" (!(builtins.tryEval (builtins.deepSeq (parse.fromAttrs {
        name = "w";
        steps = [
          {
            type = "step";
            id = "a";
            agent = "ag";
            prompt = "p";
            input = "x";
          }
        ];
      })
      true)).success);
    kiro-workflow-reject-max-iterations-zero =
      reject "max-iterations-zero"
      (wrap [
        {
          repeat = {
            id = "r";
            maxIterations = 0;
            onMaxIterations = "abort";
            steps = [];
          };
        }
      ]);
    kiro-workflow-reject-max-iterations-over-ceiling =
      reject "max-iterations-over-ceiling"
      (wrap [
        {
          repeat = {
            id = "r";
            maxIterations = 1001;
            onMaxIterations = "abort";
            steps = [];
          };
        }
      ]);
    kiro-workflow-reject-max-iterations-fractional =
      reject "max-iterations-fractional"
      (wrap [
        {
          repeat = {
            id = "r";
            maxIterations = 2.5;
            onMaxIterations = "abort";
            steps = [];
          };
        }
      ]);
    kiro-workflow-reject-unknown-on-max-iterations =
      reject "unknown-on-max-iterations"
      (wrap [
        {
          repeat = {
            id = "r";
            maxIterations = 2;
            onMaxIterations = "stop";
            steps = [];
          };
        }
      ]);
    kiro-workflow-reject-unknown-join-policy =
      reject "unknown-join-policy"
      (wrap [
        {
          parallel = {
            id = "p";
            joinPolicy = "first";
            branches = [];
          };
        }
      ]);
    kiro-workflow-reject-both-stop-forms =
      reject "both-stop-forms"
      (wrap [
        {
          repeat = {
            id = "r";
            maxIterations = 2;
            onMaxIterations = "abort";
            steps = [];
            stop = {
              condition.containsText = "x";
              when.watchTerminal = "w";
            };
          };
        }
      ]);
    kiro-workflow-reject-empty-stop-condition = reject "empty-stop-condition" (wrap [(step "a" {completion = {};})]);
    kiro-workflow-reject-jsonpath-dollar =
      reject "jsonpath-dollar"
      (jsonPathFixture ["$.drained"]);
    # The four empty-segment spellings, each rejected on its own. The engine
    # ACCEPTS all four and resolves the first three correctly — `walkJsonPath`
    # filters empty segments — so this family is the deliberate,
    # operator-approved exception to "be stricter only where the engine's
    # acceptance is silent". The reasoning is in the `fileCheck.jsonPath` row of
    # the strictness ledger in types.nix; the short version is that these paths
    # are machine-generated, so an empty segment means the generator is broken
    # and should say so rather than be quietly collapsed.
    kiro-workflow-reject-jsonpath-leading-empty-segment =
      reject "jsonpath-leading-empty-segment"
      (jsonPathFixture ["" "done"]);
    kiro-workflow-reject-jsonpath-trailing-empty-segment =
      reject "jsonpath-trailing-empty-segment"
      (jsonPathFixture ["done" ""]);
    kiro-workflow-reject-jsonpath-internal-empty-segment =
      reject "jsonpath-internal-empty-segment"
      (jsonPathFixture ["state" "" "done"]);
    # The all-empty path has two authored spellings — a list of nothing, and a
    # list of one empty segment — caught by different predicates
    # (`jsonPathType`'s `xs != []` and `jsonPathSegment`'s `s != ""`), so both
    # are pinned.
    kiro-workflow-reject-jsonpath-empty =
      reject "jsonpath-empty"
      (jsonPathFixture []);
    kiro-workflow-reject-jsonpath-only-empty-segment =
      reject "jsonpath-only-empty-segment"
      (jsonPathFixture [""]);
    # The wire spelling of the all-empty rule, and the one the engine really
    # does accept: `".."` filters to no segments at all, so `walkJsonPath`
    # leaves the cursor at the document root and the check deep-equals the
    # whole parsed file. `parse-normalizes-jsonpath-empty-segments` is the
    # shape-matched control — same import path, same fileCheck, one surviving
    # segment.
    kiro-workflow-reject-jsonpath-all-empty-on-wire =
      reject "jsonpath-all-empty-on-wire"
      (parse.fromAttrs {
        name = "w";
        steps = [
          {
            type = "step";
            id = "a";
            agent = "ag";
            prompt = "p";
            completion.fileCheck = {
              path = "p.json";
              jsonPath = "..";
              value = true;
            };
          }
        ];
      });
    kiro-workflow-reject-unknown-completion-signal =
      reject "unknown-completion-signal"
      (wrap [(step "a" {completion.completionSignal = "done";})]);
    kiro-workflow-reject-unknown-watch-handler =
      reject "unknown-watch-handler"
      (wrap [
        {
          watch = {
            id = "w";
            watcher.gitlab-mr = {};
          };
        }
      ]);
    kiro-workflow-reject-watch-without-ref =
      reject "watch-without-ref"
      (wrap [
        {
          watch = {
            id = "w";
            watcher.github-pr = {};
          };
        }
      ]);
    kiro-workflow-reject-poll-interval-below-minimum =
      reject "poll-interval-below-minimum"
      (wrap [
        {
          watch = {
            id = "w";
            watcher.github-pr = {
              prRef = "pr.json";
              pollIntervalSec = 5;
            };
          };
        }
      ]);
    kiro-workflow-reject-malformed-cr-id =
      reject "malformed-cr-id"
      (wrap [
        {
          watch = {
            id = "w";
            watcher.crux-cr = {crId = "123";};
          };
        }
      ]);
    # `resolveCrId` skips an id it considers empty, so `""` beside a `crRef`
    # really does resolve — but `""` on its own falls through to a guaranteed
    # "neither `crId` nor `crRef` provided" throw at watch start. The engine's
    # Zod refine passes both because it tests PRESENCE; these two fixtures pin
    # the difference, and each is the other's shape-matched control.
    kiro-workflow-accept-empty-cr-id-with-cr-ref =
      accept "empty-cr-id-with-cr-ref"
      (wrap [
        {
          watch = {
            id = "w";
            watcher.crux-cr = {
              crId = "";
              crRef = "cr.json";
            };
          };
        }
      ]);
    kiro-workflow-reject-empty-cr-id-alone =
      reject "empty-cr-id-alone"
      (wrap [
        {
          watch = {
            id = "w";
            watcher.crux-cr = {crId = "";};
          };
        }
      ]);
    # The engine's watch-id rule is `non-empty, no '.', no whitespace`, plus a
    # whole-string `{{`/`}}` test. A LONE brace passes all of that, so the type
    # must accept it — an earlier version rejected any brace and was stricter
    # than the engine for no benefit.
    kiro-workflow-accept-lone-brace-watch-id =
      accept "lone-brace-watch-id"
      {
        name = "w";
        steps = [
          {
            watch = {
              id = "a{b";
              watcher.github-pr = {prRef = "pr.json";};
            };
          }
          {
            repeat = {
              id = "r";
              maxIterations = 2;
              onMaxIterations = "abort";
              stop.when.watchTerminal = "a{b";
              steps = [(step "s" {})];
            };
          }
        ];
      };
    kiro-workflow-reject-doubled-brace-watch-id =
      reject "doubled-brace-watch-id"
      {
        name = "w";
        steps = [
          {
            watch = {
              id = "a{{b";
              watcher.github-pr = {prRef = "pr.json";};
            };
          }
          {
            repeat = {
              id = "r";
              maxIterations = 2;
              onMaxIterations = "abort";
              stop.when.watchTerminal = "a{{b";
              steps = [(step "s" {})];
            };
          }
        ];
      };
    kiro-workflow-reject-dotted-watch-reference =
      reject "dotted-watch-reference"
      (wrap [
        {
          repeat = {
            id = "r";
            maxIterations = 2;
            onMaxIterations = "abort";
            steps = [];
            stop.when.watchTerminal = "a.b";
          };
        }
      ]);
    kiro-workflow-reject-unicode-whitespace-watch-reference =
      reject "unicode-whitespace-watch-reference"
      (wrap [
        {
          repeat = {
            id = "r";
            maxIterations = 2;
            onMaxIterations = "abort";
            steps = [];
            stop.when.watchTerminal = unicodeWhitespaceWatchId;
          };
        }
      ]);
    kiro-workflow-reject-unicode-whitespace-watch-wire =
      reject "unicode-whitespace-watch-wire"
      (parse.fromAttrs {
        name = "w";
        steps = [
          {
            type = "repeat";
            id = "r";
            maxIterations = 2;
            onMaxIterations = "abort";
            steps = [];
            stopWhen = "${unicodeWhitespaceWatchId}.terminal";
          }
        ];
      });

    # ── Tree-level diagnostics ─────────────────────────────────────────────
    kiro-workflow-emits-step-cap =
      emits "step-cap" (wrap (map (i: step "s${toString i}" {}) (lib.range 1 21))) "E-STEP-NODES-MAX";
    kiro-workflow-silent-at-step-cap =
      silentOn "at-step-cap" (wrap (map (i: step "s${toString i}" {}) (lib.range 1 20))) "E-STEP-NODES-MAX";
    kiro-workflow-emits-nesting-depth =
      emits "nesting-depth"
      (wrap [
        (lib.foldl' (inner: i: {
          sequence = {
            id = "d${toString i}";
            steps = [inner];
          };
        }) (step "leaf" {}) (lib.range 1 8))
      ]) "E-NESTING-DEPTH";
    kiro-workflow-silent-at-nesting-depth =
      silentOn "at-nesting-depth"
      (wrap [
        (lib.foldl' (inner: i: {
          sequence = {
            id = "d${toString i}";
            steps = [inner];
          };
        }) (step "leaf" {}) (lib.range 1 7))
      ]) "E-NESTING-DEPTH";
    kiro-workflow-emits-duplicate-id =
      emits "duplicate-id" (wrap [(step "a" {}) (step "a" {})]) "E-NODE-DUPLICATE-ID";
    kiro-workflow-duplicate-id-order-is-second-occurrence = mkTest "duplicate-id-order-is-second-occurrence" (
      let
        duplicateMessages =
          map (d: d.message)
          (builtins.filter
            (d: d.code == "E-NODE-DUPLICATE-ID")
            (W.analyze.analyze (eval (wrap [
              (step "a" {})
              (step "b" {})
              (step "b" {})
              (step "a" {})
            ])))
            .diagnostics);
      in
        duplicateMessages
        == [
          "duplicate node id 'b'; ids must be unique across the WHOLE tree, not just among siblings"
          "duplicate node id 'a'; ids must be unique across the WHOLE tree, not just among siblings"
        ]
    );
    kiro-workflow-emits-duplicate-id-lineage-is-last-wins =
      emits "duplicate-id-lineage-is-last-wins"
      (wrap [
        (step "dup" {})
        (step "consumer" {prompt = "{{dup.output}}";})
        (step "dup" {})
      ])
      "E-TEMPLATE-REF-NOT-PRECEDING";
    kiro-workflow-duplicate-id-producer-is-any-occurrence = mkTest "duplicate-id-producer-is-any-occurrence" (
      let
        code = "E-TEMPLATE-REF-NOT-PRODUCER";
        producerFirst = wrap [
          (step "dup" {})
          (step "dup" {captureOutput = false;})
          (step "consumer" {prompt = "{{dup.output}}";})
        ];
        producerLast = wrap [
          (step "dup" {captureOutput = false;})
          (step "dup" {})
          (step "consumer" {prompt = "{{dup.output}}";})
        ];
      in
        !(lib.elem code (codesOf producerFirst))
        && !(lib.elem code (codesOf producerLast))
    );
    kiro-workflow-emits-interactive-in-parallel =
      emits "interactive-in-parallel"
      (wrap [
        {
          parallel = {
            id = "p";
            joinPolicy = "allSettled";
            branches = [
              {
                sequence = {
                  id = "nested";
                  steps = [(step "a" {completion.containsText = "x";})];
                };
              }
            ];
          };
        }
      ])
      "E-INTERACTIVE-STEP-IN-PARALLEL";
    kiro-workflow-emits-dangling-watch =
      emits "dangling-watch"
      (wrap [
        {
          repeat = {
            id = "r";
            maxIterations = 2;
            onMaxIterations = "abort";
            stop.when.watchTerminal = "nope";
            steps = [(step "s" {})];
          };
        }
      ])
      "E-STOP-WHEN-WATCH-ID";
    # A LONE brace is engine-legal and merely resolves literally, so it stays a
    # warning and the definition must still evaluate.
    kiro-workflow-emits-braced-stop-when-template =
      emits "braced-stop-when-template"
      (stopWhenTemplate "a{b")
      "W-STOP-WHEN-TEMPLATE-BRACES";
    kiro-workflow-emits-empty-stop-when-template =
      emits "empty-stop-when-template"
      (stopWhenTemplate "")
      "W-STOP-WHEN-LITERAL-TEMPLATE";
    # A DOUBLE brace is a different failure and must not evaluate at all.
    # `render.nix` wraps this field, so `"{{p.output}}"` — copying the wire
    # spelling into a field that already supplies the delimiters — renders
    # `{{{{p.output}}}} contains DONE`, which the engine's `parseStopWhen`
    # refuses at LOAD (its first `}}` leaves a remainder of `}} contains DONE`,
    # failing the ` contains ` test). The warning above cannot see this: it
    # fires on the same fixture while `assertValid` still passes.
    kiro-workflow-accept-stop-when-template-without-delimiters =
      accept "stop-when-template-without-delimiters"
      (stopWhenTemplate "p.output");
    kiro-workflow-reject-stop-when-template-open-delimiter =
      reject "stop-when-template-open-delimiter"
      (stopWhenTemplate "{{p.output}}");
    kiro-workflow-reject-stop-when-template-close-delimiter =
      reject "stop-when-template-close-delimiter"
      (stopWhenTemplate "p.output}}");
    # A TRAILING lone brace is the same failure reached by ADJACENCY rather than
    # by an infix: it carries no `}}` of its own, but `render.nix` appends one,
    # so `"p.output}"` renders `{{p.output}}} contains DONE` and the engine's
    # first-`}}` slice is left with `} contains DONE`. The `"a{b"` fixture above
    # structurally cannot see this — its brace is not at the seam.
    kiro-workflow-reject-stop-when-template-trailing-brace =
      reject "stop-when-template-trailing-brace"
      (stopWhenTemplate "p.output}");
    # The bare minimal case, which is what a sweep of short templates finds
    # first and what makes the rule a suffix rule rather than a "no brace next
    # to a dot" rule.
    kiro-workflow-reject-stop-when-template-is-only-a-brace =
      reject "stop-when-template-is-only-a-brace"
      (stopWhenTemplate "}");
    # These rules exist because this port's own wire reader throws on this
    # port's own rendered output. Rendering has to be done on a hand-built
    # attrset, since the option type is what now refuses the authored value.
    kiro-workflow-render-of-braced-stop-when-template-is-unparseable =
      mkTest "render-of-braced-stop-when-template-is-unparseable"
      (renderedStopWhenIsUnparseable "{{p.output}}" "{{{{p.output}}}} contains DONE");
    kiro-workflow-render-of-trailing-brace-stop-when-template-is-unparseable =
      mkTest "render-of-trailing-brace-stop-when-template-is-unparseable"
      (renderedStopWhenIsUnparseable "p.output}" "{{p.output}}} contains DONE");
    kiro-workflow-stop-when-bare-input-references = mkTest "stop-when-bare-input-references" (
      let
        workflow = declared: {
          name = "w";
          inputs =
            if declared
            then {target = "string";}
            else {};
          steps = [
            {
              repeat = {
                id = "r";
                maxIterations = 2;
                onMaxIterations = "abort";
                stop.when.contains = {
                  template = "target";
                  text = "DONE";
                };
                steps = [(step "s" {})];
              };
            }
          ];
        };
      in
        lib.elem "W-UNDECLARED-INPUT-REF" (codesOf (workflow false))
        && !(lib.elem "W-UNDECLARED-INPUT-REF" (codesOf (workflow true)))
    );
    kiro-workflow-stop-condition-signal-message = mkTest "stop-condition-signal-message" (
      messagesFor
      (wrap [
        (step "a" {
          completion = {
            completionSignal = "success";
            containsText = "DONE";
          };
        })
      ])
      "W-STOP-CONDITION-SIGNAL-FIRST"
      == ["step 'a' sets completionSignal alongside another stop form; the signal is tested first and may bypass the others when it matches"]
    );
    kiro-workflow-emits-unknown-template-ref =
      emits "unknown-template-ref" (wrap [(step "a" {prompt = "see {{ghost.output}}";})]) "E-TEMPLATE-REF-UNKNOWN";
    kiro-workflow-diagnostic-where-uses-node-id = mkTest "diagnostic-where-uses-node-id" (
      whereFor
      (wrap [
        (step "top" {prompt = "{{ghost.output}}";})
        {
          sequence = {
            id = "s";
            steps = [(step "deep" {prompt = "{{ghost2.output}}";})];
          };
        }
      ])
      "E-TEMPLATE-REF-UNKNOWN"
      == ["top" "deep"]
    );
    kiro-workflow-empty-template-ref-is-ignored = mkTest "empty-template-ref-is-ignored" (
      let
        code = "W-UNDECLARED-INPUT-REF";
      in
        !(lib.elem code (codesOf (wrap [(step "empty" {prompt = "{{}}";})])))
        && !(lib.elem code (codesOf (wrap [(step "space" {prompt = "{{ }}";})])))
    );
    kiro-workflow-emits-backward-template-ref =
      emits "backward-template-ref" (wrap [(step "a" {prompt = "see {{b.output}}";}) (step "b" {})]) "E-TEMPLATE-REF-NOT-PRECEDING";
    kiro-workflow-emits-cross-branch-template-ref =
      emits "cross-branch-template-ref"
      (wrap [
        {
          parallel = {
            id = "p";
            joinPolicy = "allSettled";
            branches = [(step "l" {}) (step "r" {prompt = "see {{l.output}}";})];
          };
        }
      ])
      "E-TEMPLATE-REF-NOT-PRECEDING";
    kiro-workflow-emits-non-producer-ref =
      emits "non-producer-ref"
      (wrap [(step "a" {captureOutput = false;}) (step "b" {prompt = "see {{a.output}}";})])
      "E-TEMPLATE-REF-NOT-PRODUCER";
    kiro-workflow-stop-context-artifact-visibility = mkTest "stop-context-artifact-visibility" (
      let
        unknown = "E-STOP-CONTEXT-ARTIFACT-UNKNOWN";
        notVisible = "E-STOP-CONTEXT-ARTIFACT-NOT-VISIBLE";
        fileCheck = path: {
          inherit path;
          jsonPath = ["done"];
          value = true;
        };
        missing = wrap [(step "a" {completion.fileCheck = fileCheck "{{artifacts.nope}}";})];
        later = wrap [
          (step "a" {completion.fileCheck = fileCheck "{{artifacts.later}}";})
          (step "b" {artifacts.later = "later.json";})
        ];
        self = wrap [
          (step "a" {
            artifacts.own = "own.json";
            completion.fileCheck = fileCheck "{{artifacts.own}}";
          })
        ];
        descendant = wrap [
          {
            repeat = {
              id = "r";
              maxIterations = 2;
              onMaxIterations = "abort";
              stop.condition.fileCheck = fileCheck "{{artifacts.child}}";
              steps = [(step "child" {artifacts.child = "child.json";})];
            };
          }
        ];
      in
        lib.elem unknown (codesOf missing)
        && lib.elem notVisible (codesOf later)
        && !(lib.elem unknown (codesOf self))
        && !(lib.elem notVisible (codesOf self))
        && !(lib.elem unknown (codesOf descendant))
        && !(lib.elem notVisible (codesOf descendant))
    );
    kiro-workflow-emits-stranded-verify =
      emits "stranded-verify"
      (wrap [
        {
          parallel = {
            id = "p";
            joinPolicy = "allSettled";
            branches = [
              {
                repeat = {
                  id = "r";
                  maxIterations = 2;
                  onMaxIterations = "abort";
                  steps = [(step "s" {})];
                };
              }
            ];
          };
        }
        (step "verify" {})
      ]) "W-ABORT-BRANCH-STRANDS-DOWNSTREAM";

    # A step inside a parallel IS referenceable by a later sibling of the
    # whole parallel — divergence happens at the ordered segment, not the
    # concurrent one. This is the aggregation-after-fan-out shape, and a
    # `precedes` that got it wrong would silently break every real workflow.
    kiro-workflow-silent-aggregate-after-fanout =
      silentOn "aggregate-after-fanout"
      (wrap [
        {
          parallel = {
            id = "p";
            joinPolicy = "allSettled";
            branches = [(step "l" {}) (step "r" {})];
          };
        }
        (step "fold" {prompt = "see {{l.output}} and {{r.output}}";})
      ]) "E-TEMPLATE-REF-NOT-PRECEDING";

    # ── Emission coverage for the remaining diagnostic codes ───────────────
    #
    # Every code `analyze.nix` can emit needs a fixture that provokes exactly
    # it, because a rule with no fixture can be DELETED with the gate staying
    # green — which was measured, not feared: three whole rule blocks were
    # removed and all assertions still passed.
    #
    # A positive alone is not enough either. It cannot tell "the rule fires on
    # this" from "the rule fires on everything", so each family below pairs its
    # positive with a `silent-` control that differs in the one field the rule
    # reads. Where a rule is a disjunction (`unsafePath`) or has several
    # emission sites (`W-CONTAINER-EMPTY`), each arm gets its own positive:
    # one arm can be dropped without the others noticing.

    # {{previous.output}} in a PROMPT. The two errors are mutually exclusive by
    # construction — the analyzer branches on the enclosing container's kind —
    # so `silent-previous-ordered` doubles as the control for both.
    kiro-workflow-emits-previous-in-parallel =
      emits "previous-in-parallel"
      (wrap [(parallel "p" {branches = [(step "l" {}) (step "r" {prompt = "{{previous.output}}";})];})])
      "E-TEMPLATE-PREVIOUS-IN-PARALLEL";
    kiro-workflow-emits-previous-no-producer =
      emits "previous-no-producer"
      (wrap [(step "a" {prompt = "{{previous.output}}";})])
      "E-TEMPLATE-PREVIOUS-NO-PRODUCER";
    # An earlier sibling is not enough — it has to PRODUCE. This is the only
    # fixture that forces the sibling-producer predicate, which reads the
    # bare sibling attrset rather than a flattened entry.
    kiro-workflow-emits-previous-prior-sibling-not-producer =
      emits "previous-prior-sibling-not-producer"
      (wrap [(step "l" {captureOutput = false;}) (step "r" {prompt = "{{previous.output}}";})])
      "E-TEMPLATE-PREVIOUS-NO-PRODUCER";
    kiro-workflow-silent-previous-ordered =
      silentOn "previous-ordered"
      (wrap [(step "l" {}) (step "r" {prompt = "{{previous.output}}";})])
      "E-TEMPLATE-PREVIOUS-NO-PRODUCER";
    kiro-workflow-silent-previous-ordered-not-in-parallel =
      silentOn "previous-ordered-not-in-parallel"
      (wrap [(step "l" {}) (step "r" {prompt = "{{previous.output}}";})])
      "E-TEMPLATE-PREVIOUS-IN-PARALLEL";

    # Artifact references from a PROMPT. `artifactBefore` is the control for
    # both, so a rule that fired unconditionally would break it.
    kiro-workflow-emits-artifact-ref-unknown =
      emits "artifact-ref-unknown"
      (wrap [(step "a" {prompt = "see {{artifacts.ghost}}";})])
      "E-ARTIFACT-REF-UNKNOWN";
    kiro-workflow-silent-artifact-ref-declared =
      silentOn "artifact-ref-declared" artifactBefore "E-ARTIFACT-REF-UNKNOWN";
    kiro-workflow-emits-artifact-ref-not-preceding =
      emits "artifact-ref-not-preceding" artifactAfter "E-ARTIFACT-REF-NOT-PRECEDING";
    kiro-workflow-silent-artifact-ref-preceding =
      silentOn "artifact-ref-preceding" artifactBefore "E-ARTIFACT-REF-NOT-PRECEDING";

    # Stop-context references. Every fixture here is `stopWhenTemplate` or a
    # one-field variant of it, so the family is its own control set.
    #
    # `stop-context-previous` is the case the analyzer's own comment calls
    # "never legal there" and the one the mutation probe found unguarded.
    kiro-workflow-emits-stop-context-previous =
      emits "stop-context-previous" (stopWhenTemplate "previous.output") "E-STOP-CONTEXT-PREVIOUS";
    kiro-workflow-silent-stop-context-non-previous =
      silentOn "stop-context-non-previous" (stopWhenTemplate "s.output") "E-STOP-CONTEXT-PREVIOUS";
    kiro-workflow-emits-stop-context-ref-unknown =
      emits "stop-context-ref-unknown" (stopWhenTemplate "ghost.output") "E-STOP-CONTEXT-REF-UNKNOWN";
    kiro-workflow-silent-stop-context-ref-known =
      silentOn "stop-context-ref-known" (stopWhenTemplate "s.output") "E-STOP-CONTEXT-REF-UNKNOWN";
    kiro-workflow-emits-stop-context-ref-not-producer =
      emits "stop-context-ref-not-producer"
      (wrap [
        (repeat "r" {
          steps = [(step "s" {captureOutput = false;})];
          stop.when.contains = {
            template = "s.output";
            text = "DONE";
          };
        })
      ])
      "E-STOP-CONTEXT-REF-NOT-PRODUCER";
    kiro-workflow-silent-stop-context-ref-producer =
      silentOn "stop-context-ref-producer" (stopWhenTemplate "s.output") "E-STOP-CONTEXT-REF-NOT-PRODUCER";
    # A repeat reaches its OWN body and anything earlier, but not a later
    # sibling of the repeat itself. The two fixtures differ only in which side
    # of the repeat the referenced step sits on.
    kiro-workflow-emits-stop-context-ref-not-visible =
      emits "stop-context-ref-not-visible"
      (wrap [
        (repeat "r" {
          stop.when.contains = {
            template = "other.output";
            text = "DONE";
          };
        })
        (step "other" {})
      ])
      "E-STOP-CONTEXT-REF-NOT-VISIBLE";
    kiro-workflow-silent-stop-context-ref-earlier =
      silentOn "stop-context-ref-earlier"
      (wrap [
        (step "other" {})
        (repeat "r" {
          stop.when.contains = {
            template = "other.output";
            text = "DONE";
          };
        })
      ])
      "E-STOP-CONTEXT-REF-NOT-VISIBLE";
    kiro-workflow-silent-stop-context-ref-inside-body =
      silentOn "stop-context-ref-inside-body" (stopWhenTemplate "s.output") "E-STOP-CONTEXT-REF-NOT-VISIBLE";

    # W-CONTAINER-EMPTY has three emission sites, one per container kind, and
    # dropping one of them is invisible to the other two.
    kiro-workflow-emits-empty-repeat = emits "empty-repeat" emptyRepeat "W-CONTAINER-EMPTY";
    kiro-workflow-emits-empty-parallel = emits "empty-parallel" emptyParallel "W-CONTAINER-EMPTY";
    kiro-workflow-emits-empty-sequence =
      emits "empty-sequence"
      (wrap [
        {
          sequence = {
            id = "q";
            steps = [];
          };
        }
      ])
      "W-CONTAINER-EMPTY";
    # One control for all three sites: every container kind, each populated.
    kiro-workflow-silent-populated-containers =
      silentOn "populated-containers"
      (wrap [
        {
          sequence = {
            id = "q";
            steps = [(step "a" {}) (parallel "p" {}) (repeat "r" {})];
          };
        }
      ])
      "W-CONTAINER-EMPTY";

    # The joinPolicy and onMaxIterations lints. Each fires on ONE enum member,
    # so its control is the same node carrying the neighbouring member.
    kiro-workflow-emits-join-policy-any =
      emits "join-policy-any" (wrap [(parallel "p" {joinPolicy = "any";})]) "W-JOIN-POLICY-ANY";
    kiro-workflow-emits-join-policy-all =
      emits "join-policy-all" (wrap [(parallel "p" {joinPolicy = "all";})]) "W-JOIN-POLICY-ALL";
    kiro-workflow-silent-join-policy-all-settled-any =
      silentOn "join-policy-all-settled-any" (wrap [(parallel "p" {})]) "W-JOIN-POLICY-ANY";
    kiro-workflow-silent-join-policy-all-settled-all =
      silentOn "join-policy-all-settled-all" (wrap [(parallel "p" {})]) "W-JOIN-POLICY-ALL";
    kiro-workflow-emits-on-max-iterations-continue =
      emits "on-max-iterations-continue"
      (wrap [(repeat "r" {onMaxIterations = "continue";})])
      "W-ON-MAX-ITERATIONS-CONTINUE";
    kiro-workflow-emits-on-max-iterations-pause =
      emits "on-max-iterations-pause"
      (wrap [(repeat "r" {onMaxIterations = "pause";})])
      "W-ON-MAX-ITERATIONS-PAUSE";
    kiro-workflow-silent-on-max-iterations-abort-continue =
      silentOn "on-max-iterations-abort-continue"
      (wrap [(repeat "r" {})])
      "W-ON-MAX-ITERATIONS-CONTINUE";
    kiro-workflow-silent-on-max-iterations-abort-pause =
      silentOn "on-max-iterations-abort-pause"
      (wrap [(repeat "r" {})])
      "W-ON-MAX-ITERATIONS-PAUSE";

    # The stop-form lint. `accept-repeat-no-stop-form` above already pins that
    # this definition EVALUATES — the engine runs it, and the vendor's own
    # `autoresearch` recipe ships it — which is a different claim from the
    # warning being emitted.
    kiro-workflow-emits-repeat-no-stop-form =
      emits "repeat-no-stop-form" (wrap [(repeat "r" {})]) "W-REPEAT-NO-STOP-FORM";
    kiro-workflow-silent-repeat-with-stop-form =
      silentOn "repeat-with-stop-form" (stopWhenTemplate "DONE") "W-REPEAT-NO-STOP-FORM";

    # `unsafePath` is a four-way disjunction and each arm is separately
    # deletable, so each gets its own positive. The plain relative path is the
    # control for all four.
    kiro-workflow-emits-file-check-path-templated =
      emits "file-check-path-templated" (fileCheckPath "{{out}}/state.json") "W-FILE-CHECK-PATH-UNSAFE";
    kiro-workflow-emits-file-check-path-absolute =
      emits "file-check-path-absolute" (fileCheckPath "/tmp/state.json") "W-FILE-CHECK-PATH-UNSAFE";
    kiro-workflow-emits-file-check-path-tilde =
      emits "file-check-path-tilde" (fileCheckPath "~/state.json") "W-FILE-CHECK-PATH-UNSAFE";
    kiro-workflow-emits-file-check-path-escaping =
      emits "file-check-path-escaping" (fileCheckPath "../state.json") "W-FILE-CHECK-PATH-UNSAFE";
    kiro-workflow-silent-file-check-path-relative =
      silentOn "file-check-path-relative" (fileCheckPath "state.json") "W-FILE-CHECK-PATH-UNSAFE";
    kiro-workflow-emits-file-check-value-array =
      emits "file-check-value-array" (fileCheckValue [true]) "W-FILE-CHECK-VALUE-ARRAY";
    kiro-workflow-silent-file-check-value-scalar =
      silentOn "file-check-value-scalar" (fileCheckValue true) "W-FILE-CHECK-VALUE-ARRAY";
  }
