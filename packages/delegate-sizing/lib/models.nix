# Decisions only. Runtime spellings live beside each model, including Claude's
# short Agent/Workflow alias and its distinct headless id.
{
  frontier = {
    astra = {
      avoidFor = "ultra (automatic delegation with unknown cost)";
      effort = "medium sweet spot; high is the operator's config default; xhigh only for named-hard work; flat above medium";
      ids = {
        codex = "gpt-6-astra";
        kiro = "gpt-6-astra";
      };
      name = "Astra (GPT-6)";
      useFor = "hardest coding and agentic work on the Codex pool; long implementation runs, computer use, novel reasoning and debug loops";
      vendor = "openai";
    };
    fable = {
      avoidFor = "routine delegates (twice Opus cost); research at low effort (answers from memory); over-prescriptive prompts";
      effort = "medium for bounded judgment; high for investigation; xhigh only for runs over 30 minutes; max buys nothing over xhigh";
      ids = {
        claude = "fable";
        claudeHeadless = "claude-fable-5-1";
        kiro = "claude-fable-5.1";
      };
      name = "Fable 5.1";
      useFor = "hardest and longest autonomous runs; taste and architecture judgment when it already holds the context; final polish";
      vendor = "anthropic";
    };
  };
  mid = {
    sonnet = {
      avoidFor = "spec or plan synthesis; finding the approach (Opus/medium is the better buy)";
      effort = "medium default; high when the bar is modest; never xhigh or max";
      ids = {
        claude = "sonnet";
        claudeHeadless = "claude-sonnet-5";
        kiro = "claude-sonnet-5";
      };
      name = "Sonnet 5";
      useFor = "code to a spec, tests by analogy, transcription and summaries; cheap writer in a writer/judge loop; give explicit requirements";
      vendor = "anthropic";
    };
    terra = {
      avoidFor = "being the default: Sol/medium and Luna/high beat it on cost at the same quality";
      effort = "medium; more effort rarely pays; never ultra";
      ids = {
        codex = "gpt-5.6-terra";
        kiro = "gpt-5.6-terra";
      };
      name = "Terra (5.6)";
      useFor = "bounded implementation on established patterns; very long reads over 200k tokens and read-heavy exploration";
      vendor = "openai";
    };
  };
  small = {
    haiku = {
      avoidFor = "open judgment, design or spec writing; long transcriptions (empty or truncated); context over 200k";
      effort = "no knob, no thinking; record effort as not applicable";
      ids = {
        claude = "haiku";
        claudeHeadless = "claude-haiku-4-5";
        kiro = "claude-haiku-4.5";
      };
      name = "Haiku 4.5";
      useFor = "grep, read, measure, classify, extract and format; rubric grading with written criteria and several samples";
      vendor = "anthropic";
    };
    luna = {
      avoidFor = "long context (vendor-only recall cliff); spec writing and judging";
      effort = "low or medium for mechanical work; medium to high is the best marginal buy (+7 for twice the cost); no ultra";
      ids = {
        codex = "gpt-5.6-luna";
        kiro = "gpt-5.6-luna";
      };
      name = "Luna (5.6)";
      useFor = "classification, extraction, routing and high-volume mechanical work; cheapest code writer with reliable checks";
      vendor = "openai";
    };
  };
  strong = {
    opus = {
      avoidFor = "mechanical work (ten times Haiku price); unnecessary extra verification or delegation on small tasks";
      effort = "medium sweet spot; high for open-ended investigation; xhigh only for long autonomous runs; flattens after medium";
      ids = {
        claude = "opus";
        claudeHeadless = "claude-opus-5";
        kiro = "claude-opus-5";
      };
      name = "Opus 5";
      useFor = "default reasoning delegate: design, adversarial review, synthesis, judging and multi-file coding";
      vendor = "anthropic";
    };
    sol = {
      avoidFor = "sole grader or judge; ultra; underspecified briefs that leave constraints implicit";
      effort = "low is its Codex default; medium sweet spot; above high rarely pays";
      ids = {
        codex = "gpt-5.6-sol";
        kiro = "gpt-5.6-sol";
      };
      name = "Sol (5.6)";
      useFor = "default OpenAI code writer; long-horizon coding; recall-heavy review (finds more, filters less); written deliverables";
      vendor = "openai";
    };
  };
}
