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
      enable = false;
      source = ../fragments/orchestrator-session.md;
    };
    "Size the work" = {
      after = ["Follow the user's request"];
      source = ../fragments/size-the-work.md;
    };
    "Validate the result" = {
      after = ["Choose execution"];
      always = true;
      source = ../fragments/validate-the-result.md;
    };
  };
  workflows."Work and review" = {
    source = ../fragments/work-and-review.md;
    steps = steps [
      {
        name = "Rubric";
        source = ../fragments/review-rubric.md;
      }
      {
        name = "Subtractive";
        source = ../fragments/review-subtractive.md;
      }
      {
        name = "Work";
        source = ../fragments/review-work.md;
      }
      {
        name = "Review";
        source = ../fragments/review-one-reviewer.md;
      }
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
        name = "Loop";
        source = ../fragments/review-loop.md;
      }
    ];
  };
}
