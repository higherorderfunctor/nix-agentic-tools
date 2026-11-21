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
              **Review order.** Apply R1-R6 first to each unit of code. If any
              readability row fails, stop for that unit and report only those failures.
              Only after all six pass does the same reviewer apply E1-E4 to that unit.
              This ordering does not change how many independent reviewers the workflow
              requires.
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
              **E4.** Parse each external input once, at the earliest boundary that can
              refuse it, into a typed model. Document one input format; another shape needs
              a named producer that sends it. Typed values flow downstream without
              conversion or revalidation. Choosing by type is acceptable only in a downstream
              unit whose actual job is to choose by type, never as a reason to skip boundary
              validation.
            '';
          }
          {
            name = "Fixtures";
            text = ''
              **Fixtures.** Fixtures send the production client's exact shape, use bounded
              literal cases for contract edges, and cover input spaces with a few named
              properties. Cases that share a setup go in one input and expected pair,
              with each behavior a named entry so a failure names the rule it broke. A
              fixture that cannot reproduce production names the difference; a path no
              fixture exercises is a finding.
            '';
          }
          {
            name = "Size";
            text = ''
              **Size.** Estimate while planning and count the final diff while reviewing:
              200-400 lines per PR is the target, and about 500 is where a change counts as
              over. Measure the line budget on normally formatted code. The signal is the
              added lines of the ready change's line breakdown, its hand-written code row
              plus its docs row; removed lines count separately and never raise it. Tests,
              fixtures and checks fit within about twice the change's actual hand-written
              code unless the brief says why. These are steering signals, never caps: being
              over never stops work, never needs the user's approval, and being over on
              code lines alone does not fail this row; the row fails a change that is over
              on code with neither a split nor a stated reason, or whose tests, fixtures
              and checks run past about twice its code with no stated reason. If an estimate
              is over and a seam exists that a reviewer can read alone, split into stacked
              PRs without asking; each piece passes its checks on its own. If no seam
              exists, make one change and say why in the brief and PR summary.
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
              **Checks.** Each added check names the wrong implementation it fails on. A
              check whose expected value is computed by the expression under test, or read
              back from the input the check itself supplied, fails on none: write the
              expected value by hand or take it from an observed result, or delete the
              check. A check for a race or a regression is shown to fail against the code
              before the fix.
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
