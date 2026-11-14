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

          Write a closed `--launch-context` JSON file: `taskSummary` (bounded, nonempty), optional nullable `proposerFamily` (your own configured family name, or null when unknown), required `nonInteractive` (true, false or null), `roles` and observed `techniques`. A role takes only optional `effort` (string or null, checked against the package scale) and optional `avoid` and `exclude` lists of exact configured family names (empty by default). Roles are finder, first-check, investigator, judge, mechanical, planner, second-check and writer. Each observed technique gives `runtime`, `technique`, one concrete `model` and its unordered supported `efforts`; `[]` explicitly certifies effort omission support, never unknown availability. Off-scale observed efforts such as ultra or off are ignored. Never supply family essays.

          Get exact configured family names from the helper's invalid-request errors, which list the allowed names, or from returned candidates' `launch.family`; on Claude, generated agent file names are the family names. A refused request exits 2 with `{"status":"invalid-request","errors":[{"path","message"}]}` on stdout listing every problem and allowed values, plus one `delegate-routing-plan: <path>: <message>` line per problem on stderr, before any Reader or picker runs: fix every named path and rerun; a `manifest.` path is a configuration fault to report to the user instead of retrying.

          After hard eligibility the helper runs its own one-shot picker, without tools, that keeps or excludes each role and family pair for this task, then ranks what is kept by pool pace. An unknown non-null proposer is refused; missing or null proposer identity skips the picker. When the picker is unavailable or fails, report `WARNING: model picker unavailable; using tier and pool ranking only. Report this failure to the user.`, followed by ` Unavailable: <reason>.` for each failed entry, or for missing identity/no runnable entry, and use the tier and pool ranking the helper returns. The authorized internal picker may run in nonInteractive contexts, needs no entry in `techniques`, and is skipped when its executable is not on PATH.

          JSON goes to stdout and routing lines to stderr. A line is a specification for your own launch tool, never shell text: bind its technique, model and effort exactly. A role whose first pick is a fallback prints `WARNING: <role>: no non-avoided candidate; using fallback <family> at effort <x>. Report this to the user.` Failed Readers and dropped windows print warnings ending "Report this failure to the user." Exclude wins over avoid and removes every route for that family with reason "excluded by caller"; avoid never removes a route by itself. Avoided families rank after the rest with measured preference and pace ordering within each partition and carry `kind`, `resolvedEffort` and `launchEffort`; list order and duplicates add no preference. Session pace still compares all otherwise fitting measured candidates, including avoided ones. Review callers avoid the writer family; cut judges avoid writer and proposer families; use fresh separate agents with neutral briefs. After a failed launch, rerun with that family added to the role's `exclude` list, retaining other evidence. Planner and review roles require strong or frontier tiers; try shared fallback before reporting no qualified route and never step down a tier. An unknown or headless context cannot certify an external launch. Provider identity is provisional for maker independence; callers still enforce trial and independence rules.
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
            name = "Scope";
            text = ''
              **Scope.** A plan item names the current artifact field or behavior it
              replaces; one that replaces nothing is cut, or is an optional follow-up with
              its own reason. A mechanism is proportional to what it judges: one that fires
              on changes outside its input (a fingerprint wider than the judged spans,
              failing on every unrelated bump) is a finding, not strictness. The planner
              plans to this row; the plan's first reviewer judges scope against the stated
              goal before any row.
            '';
          }
          {
            name = "Fixtures";
            text = ''
              **Fixtures.** Fixtures send what a production client sends: a Host or
              authority without a port on a default-port destination, a plain push and not
              only a forced one. A fixture that cannot reproduce production (a port it
              cannot bind) names the difference and what it hides; a path no fixture
              exercises is a finding. Generated or property tests cover input spaces with
              few literal examples. Each test says which behavior it protects; large
              hand-written fixtures need a stated reason.
            '';
          }
          {
            name = "Naming";
            text = ''
              **Naming.** A comment or doc names behaviors, files and options, never a plan
              phase, review round or finding id whose document is not in the repository;
              write the decision the label stands for. Numbering the artifact itself
              defines (a script's own phase headings) is a name and stays. Names say what a
              thing returns or decides, not just the type it handles.
            '';
          }
          {
            name = "Size";
            text = ''
              **Size.** Estimate while planning and count the final diff while reviewing:
              200-400 lines per PR is the target, and about 500 is where a change counts as
              over. The signal is the added lines of the ready change's line breakdown, its
              hand-written code row plus its docs row; removed lines count separately and
              never raise it. Tests, fixtures and checks fit within about twice the
              change's actual hand-written code unless the brief says why. These are
              steering signals, never caps: being over never stops work, never needs the
              user's approval, and being over on code lines alone does not fail this row;
              the row fails a change that is over on code with neither a split nor a stated
              reason, or whose tests, fixtures and checks run past about twice its code
              with no stated reason. If an estimate is over and a seam exists that a
              reviewer can read alone, split into stacked PRs without asking; each piece
              passes its checks on its own. If no seam exists, make one change and say why
              in the brief and PR summary.

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
          {
            name = "Input boundary";
            text = ''
              **Input boundary.** External input becomes typed structures once at the
              boundary; downstream code uses those structures without revalidating them.
            '';
          }
          {
            name = "Input format";
            text = ''
              **Input format.** Support one documented input format unless a named producer
              sends another.
            '';
          }
          {
            name = "Standard tools";
            text = ''
              **Standard tools.** Use the standard library or an established package before
              a hand-written parser, decoder, depth limiter or validator. A hand-written
              implementation states why none fits.
            '';
          }
          {
            name = "Temporary tools";
            text = ''
              **Temporary tools.** A preview or inspection tool that will be replaced later
              belongs as a runnable snippet in the change description, not in the change.
            '';
          }
        ];
      }
      {
        name = "Subtractive";
        source = ../fragments/review-subtractive.md;
        rows = chain [
          {
            name = "Callers";
            text = ''
              **Callers.** Each added line must name a caller or the concrete input it
              refuses (value, path or environment); otherwise remove it. A guard with a real
              but unstated refused input needs that input named where the guard lives. Flag
              wrappers, shims, compatibility branches and tests kept only to preserve an old
              shape; propose the simpler form when the code can collapse.
            '';
          }
          {
            name = "Same-change caller";
            text = ''
              **Same-change caller.** A caller counts if it already exists or lands in the
              same change. A declaration, option, field or export whose first reader is in a
              later change moves there; one with no reader anywhere is deleted. The warning,
              check or mirroring the declaration itself drags in is not a reader.
            '';
          }
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
          {
            name = "Earliest layer";
            text = ''
              **Earliest layer.** For each refused input, ask which layer first sees it. If
              that layer can refuse it without dropping a supported case, refuse it there
              and delete the later guard. If nothing refuses it yet, add the refusal there
              rather than a guard downstream. Do not size a guard to an input that only a
              fallback or an over-broad argument lets through.
            '';
          }
          {
            name = "Necessity";
            text = ''
              **Necessity.** A missing test is a finding only once the code is shown needed:
              a caller or real input in the repository reaches it. Otherwise the finding is
              to delete the code.
            '';
          }
          {
            name = "One source of truth";
            text = ''
              **One source of truth.** Each behavior is implemented once, and callers use it
              rather than wrapping it.
            '';
          }
          {
            name = "Readable in one pass";
            text = ''
              **Readable in one pass.** A reader can state what the code does in two
              sentences without opening another file. Each file has a short header naming
              its purpose, callers and data flow. Comments explain why; delete comments the
              reader cannot act on.
            '';
          }
          {
            name = "Abstract on the third repeat";
            text = ''
              **Abstract on the third repeat.** Repetition is a defect only when it
              duplicates a decision. If removing it would force a reader to jump between
              files to follow one idea, it stays.
            '';
          }
          {
            name = "Data over control flow";
            text = ''
              **Data over control flow.** Prefer one function driven by a table of cases
              over a chain of special cases. A case-specific branch needs a stated reason.
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
