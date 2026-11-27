{lib}: let
  # Every record follows all earlier ones, so disabling any one keeps the rest
  # in order.
  chain = records:
    builtins.listToAttrs (lib.imap0 (index: record: {
        inherit (record) name;
        value =
          {after = map (earlier: earlier.name) (lib.take index records);}
          // lib.getAttrs (builtins.filter (key: record ? ${key}) ["rows" "source" "text"]) record;
      })
      records);
  columns = names:
    chain (map (name: {
        inherit name;
        text = name;
      })
      names);
in {
  routing = {
    "Choose execution" = {
      after = ["Size the work"];
      source = ../fragments/choose-execution.md;
    };
    "Follow the user's request".source = ../fragments/follow-the-users-request.md;
    "Load delegate-routing" = {
      always = true;
      source = ../fragments/load-delegate-routing.md;
    };
    "Orchestrator session" = {
      always = true;
      enable = true;
      source = ../fragments/orchestrator-session.md;
    };
    "Pool drain" = {
      after = ["Size the work"];
      always = true;
      source = ../fragments/pool-drain.md;
    };
    "Size the work" = {
      after = ["Follow the user's request"];
      source = ../fragments/size-the-work.md;
    };
    "Tune these rules" = {
      after = ["Choose execution"];
      source = ../fragments/tune-these-rules.md;
    };
    "Validate the result" = {
      after = ["Choose execution"];
      always = true;
      source = ../fragments/validate-the-result.md;
    };
  };
  skill = {
    columns = {
      families = columns ["Family" "Orchestration" "Use for" "Avoid for" "Effort (delegate)" "Pool" "Launch"];
      pools = columns ["Name" "Reader" "Measure" "Description"];
      techniques = columns ["Technique" "Kind" "Pins model" "Pins effort" "Modes" "Runs own subagents" "Notes" "Command"];
    };
    entries = chain [
      {
        name = "Routing";
        text = "## Routing\n\n{routing}";
      }
      {
        name = "Common workflows";
        text = "## Common workflows\n\n{workflows}";
      }
      {
        name = "Routing helper";
        text = ''
          ## Routing helper

          {helper}

          Use this runtime's rendered command with the requested roles. Leave Reader discovery to the helper. Write a closed `--launch-context` JSON file: `taskSummary` (bounded, nonempty), optional nullable `proposerFamily` (your own configured family name, or null when unknown), required `nonInteractive` (true, false or null), `roles` and observed `techniques`. A role takes only optional `effort` (string or null, checked against the package scale) and optional `avoid` and `exclude` lists of exact configured family names (empty by default). Roles are finder, first-check, investigator, judge, mechanical, planner, second-check and writer. Each observed technique gives `runtime`, `technique`, one concrete `model` and its unordered supported `efforts`; `[]` explicitly certifies effort omission support, never unknown availability. Off-scale observed efforts such as ultra or off are ignored. Never supply family essays.

          Get exact configured family names from the helper's invalid-request errors, which list the allowed names, or from returned candidates' `launch.family`; on Claude, generated agent file names are the family names. A refused request exits 2 with `{"status":"invalid-request","errors":[{"path","message"}]}` on stdout listing every problem and allowed values, plus one `delegate-routing-plan: <path>: <message>` line per problem on stderr, before any Reader or picker runs: fix every named path and rerun; a `manifest.` path is a configuration fault to report to the user instead of retrying.

          After hard eligibility the helper runs its own one-shot picker, without tools, that keeps or excludes each role and family pair for this task, then ranks what is kept by pool pace. An unknown non-null proposer is refused; missing or null proposer identity skips the picker. When the picker is unavailable or fails, report `WARNING: model picker unavailable; using tier and pool ranking only. Report this failure to the user.`, followed by ` Unavailable: <reason>.` for each failed entry, or for missing identity/no runnable entry, and use the tier and pool ranking the helper returns. The authorized internal picker may run in nonInteractive contexts, needs no entry in `techniques`, and is skipped when its executable is not on PATH.

          JSON goes to stdout and routing lines to stderr. A line is a specification for your own launch tool, never shell text: bind its technique, model and effort exactly. A role whose first pick is a fallback prints `WARNING: <role>: no non-avoided candidate; using fallback <family> at effort <x>. Report this to the user.` Failed Readers and dropped windows print warnings ending "Report this failure to the user." Exclude wins over avoid and removes every route for that family with reason "excluded by caller"; avoid never removes a route by itself. Avoided families rank after the rest with measured preference and pace ordering within each partition and carry `kind`, `resolvedEffort` and `launchEffort`; list order and duplicates add no preference. Session pace still compares all otherwise fitting measured candidates, including avoided ones. Review callers avoid the writer family; cut judges avoid writer and proposer families; use fresh separate agents with neutral briefs. After a launch route fails, follow Choose execution’s retry rules; when the failure makes the family unusable, add it to `exclude` and rerun the helper, retaining other evidence. Planner and review roles require strong or frontier tiers; try shared fallback before reporting no qualified route and never step down a tier. For a fit-only selection, report budget and session uncertainty. If no reachable candidate survives, retain the exclusions and report a loop failure. An unknown or headless context cannot certify an external launch. Provider identity is provisional for maker independence; callers still enforce trial and independence rules.
        '';
      }
      {
        name = "Technique notes";
        text = "## Technique notes\n\nBind a launch from its technique's line here. Check model availability with the introspection command. Pass every model the introspection lists and its supported efforts as observed techniques; when several match one family's pattern, the helper chooses the highest version (6.10 over 6.9). Each candidate in the helper's JSON stdout carries `launch` with `guidance` (command, modelArg, notes) and `agent`. Use them to bind the pick, including the generated agent file to name.\n\n{techniqueNotes}";
      }
      {
        name = "Manual-only external delegates";
        text = "## manual-only external delegates\n\n{manual}";
      }
    ];
    phrases = {
      "External reach" = {text = "via {harness}: {launch}{pool}";};
      "Family table heading" = {text = "### {tier}";};
      "Launch fallback" = {text = ", else ";};
      "Launch route" = {text = "`{technique}` with {modelArg} {model}";};
      "Manual delegate heading" = {text = "### {harness}";};
      "Manual delegate note" = {text = "Not a candidate for auto-selection; use only when the user names it.";};
      "Manual pool hint" = {text = "; {pool}";};
      "Model pattern" = {text = "the highest id matching `{match}`";};
      "Native reach" = {text = "{harness}: {launch}{pool}";};
      "OpenCode Go note" = {text = "The opencode-go families come from per-model research: their tiers and effort guidance are provisional, not measured on this workload.";};
      "Pool binding" = {text = " (pool {pool})";};
      "Pool measured" = {text = "measured";};
      "Pool reader missing" = {text = "none";};
      "Pool unmeasured" = {text = "unknown";};
      "Pool window" = {text = "configured: {limit} {unit} per month, resets day {resetDay}; current use unknown";};
      "Technique notes heading" = {text = "### {harness} technique notes";};
      "Technique table heading" = {text = "### {harness} techniques";};
      "Workflow step" = {text = "{index}. **{name}:** {text}";};
    };
  };
  workflows."Work and review" = {
    source = ../fragments/work-and-review.md;
    steps = chain [
      {
        name = "Rubric";
        source = ../fragments/review-rubric.md;
        rows = chain [
          {
            name = "Review order";
            text = ''
              **Review order.** Apply R1-R6 first to each unit. Stop grading that unit
              only for a readability failure of medium severity or higher. Report lower
              readability nits and continue through E1-E4. The reviewer count is unchanged.
            '';
          }
          {
            name = "R1";
            text = ''
              **R1.** State what the unit does, its inputs, its output, and why it exists
              before judging its details.
            '';
          }
          {
            name = "R2";
            text = ''
              **R2.** Mentally remove prose and comments. Names, types, and structure must
              lead the reader to the same conclusion; if they do not, fix them before
              adding prose.
            '';
          }
          {
            name = "R3";
            text = ''
              **R3.** Names say what a thing returns or decides, clearly enough that a reader
              never opens an implementation only to learn what the name means. They never
              name a plan phase, review round, or finding id; write the decision the label
              stands for.
            '';
          }
          {
            name = "R4";
            text = ''
              **R4.** With well-named things and its doc comments, the unit reads line by
              line without jumping around to follow one idea.
            '';
          }
          {
            name = "R5";
            text = ''
              **R5.** Each unit has one short doc comment giving its purpose, inputs,
              output, callers, and reason to exist. Each file states its purpose, callers,
              and how data flows through it.
            '';
          }
          {
            name = "R6";
            text = ''
              **R6.** Comments explain only why code cannot, such as why failures are
              collected instead of raised. They carry no plan labels or narration.
            '';
          }
          {
            name = "E1";
            text = ''
              **E1.** Judge each unit against the program's stated goal. Every part must
              serve that goal proportionally, and each declaration needs an existing or
              same-change caller; a future-only declaration moves later and one with no
              reader is deleted. Before calling a missing test a finding, show that the
              code is needed.
            '';
          }
          {
            name = "E2";
            text = ''
              **E2.** Ask whether a clearer form exists and name it. Prefer an established
              library or package when it fits, and prefer a table of cases over a chain of
              special cases when the table is clearer.
            '';
          }
          {
            name = "E3";
            text = ''
              **E3.** Look for the simpler, cheaper shape. A finding that says a part can go also
              says what breaks if it is removed. Implement each decision once, and abstract
              repeated decisions only when that avoids needless jumping between files.
            '';
          }
          {
            name = "E4";
            text = ''
              **E4.** Types are the contract. Use typed request and response models at
              external boundaries. Parse each external input once at the earliest point that
              can refuse it; a shape change should surface in validation or type checking.
              Document one input format; another shape needs a named producer. Typed values
              flow downstream without conversion or revalidation. Choose by type only in a
              unit whose job is to do so, never instead of boundary validation.
            '';
          }
          {
            name = "Fixtures";
            text = ''
              **Fixtures.** Fixtures keep the shape the code reads; name differences it can
              see. Share setup, never expected results that must stay independent. Use an
              extractor for facts it establishes and test the real code that reads them. A
              mock endpoint shows what a client sends or how it handles a reply, never what
              the live endpoint accepts. A check that only replays a canned answer tests
              nothing and is deleted.
            '';
          }
          {
            name = "Size";
            text = ''
              **Size.** Aim for 200-400 added lines of hand-written code and docs per PR;
              around 500 is over. Split an over-size estimate or draft at a seam a reviewer
              can read alone, with checks in each PR. If no seam fits, say why in the brief
              and PR summary.

              After each unit, report the normally formatted PR diff's cumulative added
              lines against the plan's total for code, docs, tests, fixtures and checks.
              Count deletions and generated lines separately; don't net them against
              additions. When additions reach 1.5x the current estimate, pause before
              the next unit: split, cut scope within the agreed design, or record the
              reason and a new estimate. Judge a unit planned as a cut by each file's
              planned target size, not by added lines. At 2x the original positive
              estimate, report the numbers and options to the operator before more work
              runs.
            '';
          }
          {
            name = "Human prose";
            text = ''
              **Human prose.** Writers and rewriters load and follow `peer-communication`
              when installed for human docs, maintainer comments and change descriptions.
              Without that skill, lead with what the thing does or how to use it in short,
              plain sentences. Reviewers grade prose for a point-first explanation in plain
              words: readers need not unpack the wording or guess its purpose.
            '';
          }
        ];
      }
      {
        name = "Subtractive";
        source = ../fragments/review-subtractive.md;
        rows = chain [
          {
            name = "Checks";
            text = ''
              **Checks.** Skip a test when a surviving guard (evaluation, a linter, a type
              checker or another check) already rejects the same wrong outcome, for the same
              reason, on the same path; the guard under test cannot stand in for its own
              check. Keep one representative bad input per restriction that could be
              loosened, beside a valid control, forced through the real merge or entry
              point. Put a declaration's good and bad inputs in one check over a table so a
              failure names the row; where the stack has a property-testing library,
              generate the inputs instead. Known regression inputs stay as explicit rows.

              For any other wrong outcome that matters (a value, order, side effect, timing,
              attribution or decision), name the input, the wrong outcome and the expected
              result, taken from the requirement. Check the particular failure, never just
              that something failed. When an empty result would pass, pin the expected
              members. A test that recomputes production's logic to get its expectation is
              reworked: use a known answer for a fixed input or an independent observation,
              and keep the behavior it checks. Show a bug-fix, race or regression check
              failing for the intended reason before the fix, or against one plausible
              wrong implementation, and passing after.

              Before pruning a row or assertion, trace every reader of it, including
              symlinks and files selected by name. Prune only when the skip test above still
              holds for each reader after the whole prune, or the outcome is no longer
              required. A missing comment or missing run evidence is a rework, not grounds
              to prune. At planning, list the distinct failures to cover; there is no
              test-to-code target.
            '';
          }
        ];
      }
      {
        name = "Plan";
        source = ../fragments/plan-work.md;
      }
      {
        name = "Work";
        source = ../fragments/review-work.md;
      }
      {
        name = "Describe";
        source = ../fragments/review-describe.md;
      }
      {
        name = "Review";
        source = ../fragments/review-checks.md;
      }
      {
        name = "Loop";
        source = ../fragments/review-loop.md;
      }
    ];
  };
}
