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
#   VENDOR   the seven recipes inlined in the engine bundle must parse,
#            type-check, analyze clean of engine-basis errors, and RENDER
#            BACK byte-identically. The engine shape-parses these at module init
#            but does not structurally analyze them until launch. They are the
#            highest-fidelity corpus available, but a failure warrants checking
#            both the local rule and the vendor recipe.
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

  step = id: extra: {
    step =
      {
        inherit id;
        agent = "ag";
        prompt = "p";
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
      {
        repeat = {
          id = "r";
          maxIterations = 2;
          onMaxIterations = "abort";
          stop.when.contains = {
            inherit template;
            text = "DONE";
          };
          steps = [(step "s" {})];
        };
      }
    ];

  unicodeWhitespaceWatchId = builtins.fromJSON "\"wait\\u00a0for\\u00a0it\"";

  # ── vendor corpus ─────────────────────────────────────────────────────────
  vendorDir = ./fixtures/kiro-workflows/vendor;
  vendorNames = lib.attrNames (builtins.readDir vendorDir);

  vendorTests = lib.listToAttrs (map (
      entry: let
        stem = lib.removeSuffix ".workflow.json" entry;
        raw = builtins.fromJSON (builtins.readFile (vendorDir + "/${entry}"));
        authored = eval (W.parse.fromAttrs raw);
        analysis = W.analyze.analyze authored;
        # `planRevision` is machine state the authored shape deliberately has
        # no option for, so it is excluded from the round-trip comparison
        # rather than carried.
        expected = lib.filterAttrs (n: _: n != "planRevision") raw;
      in
        lib.nameValuePair "kiro-workflow-vendor-${stem}"
        (mkTest "vendor-${stem}" (
          analysis.engineErrors == [] && W.render.toAttrs authored == expected
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
    kiro-workflow-accept-empty-parallel =
      accept "empty-parallel"
      (wrap [
        {
          parallel = {
            id = "p";
            branches = [];
            joinPolicy = "allSettled";
          };
        }
      ]);
    kiro-workflow-accept-empty-repeat =
      accept "empty-repeat"
      (wrap [
        {
          repeat = {
            id = "r";
            maxIterations = 2;
            onMaxIterations = "abort";
            steps = [];
          };
        }
      ]);

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
    kiro-workflow-parse-normalizes-jsonpath-empty-segments = mkTest "parse-normalizes-jsonpath-empty-segments" (
      let
        parsed = eval (W.parse.fromAttrs {
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
      (wrap [
        (step "a" {
          completion.fileCheck = {
            path = "p.json";
            jsonPath = ["state" "$value"];
            value = true;
          };
        })
      ]);

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
    kiro-workflow-reject-removed-input-field-on-wire = mkTest "reject-removed-input-field-on-wire" (!(builtins.tryEval (builtins.deepSeq (W.parse.fromAttrs {
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
      (wrap [
        (step "a" {
          completion.fileCheck = {
            path = "p.json";
            jsonPath = ["$.drained"];
            value = true;
          };
        })
      ]);
    kiro-workflow-reject-jsonpath-empty =
      reject "jsonpath-empty"
      (wrap [
        (step "a" {
          completion.fileCheck = {
            path = "p.json";
            jsonPath = [];
            value = true;
          };
        })
      ]);
    # The wire spelling of the same rule, and the one the engine really does
    # accept: `".."` filters to no segments at all, so `walkJsonPath` leaves
    # the cursor at the document root and the check deep-equals the whole
    # parsed file. `parse-normalizes-jsonpath-empty-segments` is the
    # shape-matched control — same import path, same fileCheck, one surviving
    # segment.
    kiro-workflow-reject-jsonpath-all-empty-on-wire =
      reject "jsonpath-all-empty-on-wire"
      (W.parse.fromAttrs {
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
      (W.parse.fromAttrs {
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
    # The rule exists because this port's own wire parser throws on this port's
    # own rendered output. Rendering has to be done on a hand-built attrset,
    # since the option type is what now refuses the authored value.
    kiro-workflow-render-of-braced-stop-when-template-is-unparseable = mkTest "render-of-braced-stop-when-template-is-unparseable" (
      let
        wire = W.render.renderStopWhen {
          contains = {
            template = "{{p.output}}";
            text = "DONE";
          };
        };
      in
        wire
        == "{{{{p.output}}}} contains DONE"
        && !(builtins.tryEval (builtins.deepSeq (W.parse.parseStopWhen "probe" wire) true)).success
    );
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
  }
