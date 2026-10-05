{lib}: let
  steps = records:
    builtins.listToAttrs (lib.imap0 (index: record: {
        inherit (record) name;
        value = {
          after = lib.optional (index > 0) (builtins.elemAt records (index - 1)).name;
          inherit (record) source;
        };
      })
      records);
  rubric = {
    name = "Rubric";
    source = ../fragments/review-rubric.md;
  };
in {
  routing = {
    "Choose execution" = {
      after = ["Size the work"];
      source = ../fragments/choose-execution.md;
    };
    "Follow the request".source = ../fragments/follow-the-request.md;
    "Load delegate-routing" = {
      always = true;
      source = ../fragments/load-delegate-routing.md;
    };
    "Orchestrator session" = {
      always = true;
      enable = false;
      source = ../fragments/orchestrator-session.md;
    };
    "Size the work" = {
      after = ["Follow the request"];
      source = ../fragments/size-the-work.md;
    };
    "Verify the result" = {
      after = ["Choose execution"];
      always = true;
      source = ../fragments/verify-the-result.md;
    };
  };
  workflows = {
    "Review: one reviewer" = {
      enable = false;
      steps = steps [
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
      ];
    };
    "Review: prosecute, defend, judge" = {
      enable = false;
      steps = steps [
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
      ];
    };
  };
}
