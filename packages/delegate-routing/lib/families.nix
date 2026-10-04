# Family decisions; resolve concrete ids from each runtime's live list.
{
  anthropic = {
    fable = {
      avoidFor = "routine delegate work (2× Opus cost); research at low effort (answers from memory); over-prescriptive prompts degrade it";
      effort = "medium for bounded judgment, high for investigation, xhigh only for runs over 30 min, max buys nothing over xhigh";
      match = "claude-fable-*";
      tier = "frontier";
      useFor = "hardest and longest autonomous runs; taste and architecture judgment when it already holds the context; final polish";
    };
    haiku = {
      avoidFor = "anything needing judgment; long transcriptions (empty or truncated)";
      effort = "no knob, no thinking";
      match = "claude-haiku-*";
      tier = "small";
      useFor = "grep, read, measure, classify, extract, format; rubric grading with written criteria and several samples";
    };
    opus = {
      avoidFor = "mechanical work (10× Haiku price)";
      effort = "medium default, high when more reasoning is needed; returns flatten after medium";
      match = "claude-opus-*";
      tier = "strong";
      useFor = "adversarial review, judging, design, synthesis; complex reasoning across files";
    };
    sonnet = {
      avoidFor = "spec or plan synthesis; \"find the approach\" work (Opus/medium is the better buy)";
      effort = "medium default, high when the bar is modest, never xhigh or max";
      match = "claude-sonnet-*";
      tier = "mid";
      useFor = "code to a spec, tests, transcription, summaries; the cheap writer in a writer-judge loop";
    };
  };
  openai = {
    astra = {
      avoidFor = "ultra (spawns subagents, cost unknown)";
      effort = "medium sweet spot, high = operator's config default, xhigh only for named-hard; flat above medium";
      match = "gpt-*-astra";
      tier = "frontier";
      useFor = "hardest coding and agentic work on the Codex pool; long implementation runs; computer use; novel reasoning";
    };
    luna = {
      avoidFor = "long context (vendor-only cliff); spec writing; judging";
      effort = "medium→high is the best marginal buy in the set (+7 for 2×); no ultra";
      match = "gpt-*-luna";
      tier = "small";
      useFor = "classification, extraction, routing, high-volume mechanical work; cheapest code writer";
    };
    sol = {
      avoidFor = "sole grader or judge; ultra";
      effort = "medium default, high when the task needs more reasoning";
      match = "gpt-*-sol";
      tier = "strong";
      useFor = "code writer; long-horizon coding; recall-heavy code review (finds more, filters less); written deliverables";
    };
    terra = {
      avoidFor = "being the default when Sol or Luna is reachable: they beat it on cost at the same quality";
      effort = "medium; more effort rarely pays";
      match = "gpt-*-terra";
      tier = "mid";
      useFor = "bounded implementation on established patterns; very long reads over 200k tokens";
    };
  };
}
