{lib}: let
  entry = source: overrides:
    {
      after = [];
      always = false;
      before = [];
      enable = true;
      inherit source;
    }
    // overrides;
  workflow = steps: (entry null {
    enable = false;
    text = "";
    inherit steps;
  });
  steps = records:
    builtins.listToAttrs (lib.imap0 (index: record: {
        inherit (record) name;
        value = entry record.source {after = lib.optional (index > 0) (builtins.elemAt records (index - 1)).name;};
      })
      records);
  rubric = {
    name = "Rubric";
    source = ../fragments/review-rubric.md;
  };
in {
  routing = {
    "Choose execution" = entry ../fragments/choose-execution.md {after = ["Size the work"];};
    "Follow the request" = entry ../fragments/follow-the-request.md {};
    "Load delegate-routing" = entry ../fragments/load-delegate-routing.md {always = true;};
    "Orchestrator session" = entry ../fragments/orchestrator-session.md {
      always = true;
      enable = false;
    };
    "Size the work" = entry ../fragments/size-the-work.md {after = ["Follow the request"];};
    "Verify the result" = entry ../fragments/verify-the-result.md {
      after = ["Choose execution"];
      always = true;
    };
  };
  workflows = {
    "Review: one reviewer" = workflow (steps [
      rubric
      {
        name = "Review";
        source = ../fragments/review-one-reviewer.md;
      }
      {
        name = "Judge findings";
        source = ../fragments/review-judge-findings.md;
      }
      {
        name = "Rounds";
        source = ../fragments/review-one-reviewer-rounds.md;
      }
    ]);
    "Review: prosecute, defend, judge" = workflow (steps [
      rubric
      {
        name = "Prosecute";
        source = ../fragments/review-prosecute.md;
      }
      {
        name = "Defend";
        source = ../fragments/review-defend.md;
      }
      {
        name = "Judge";
        source = ../fragments/review-judge.md;
      }
      {
        name = "Rounds";
        source = ../fragments/review-disputed-rounds.md;
      }
    ]);
  };
}
