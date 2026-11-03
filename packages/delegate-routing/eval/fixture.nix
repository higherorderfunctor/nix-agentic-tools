# cspell:ignore nemotron zhipu
# cases.nix tests routing delivery without the operator's personal devenv config.
{
  config,
  lib,
  ...
}: {
  imports = [../../../checks/instructions/fixtures/local-runtimes.nix];
  # Acceptance cases exercise Kiro workflows independently of the build probe.
  ai.kiro.cli = {
    v3 = true;
    workflows.enable = true;
  };
  ai.programs.delegate-routing = {
    enable = true;
    # The package ships no Kimchi-served families.
    families = {
      deepseek.deepseek-flash = {
        avoidFor = "review, building code, correctness judgment; knowledge-heavy questions";
        effort = "thinks by default; low for reads, high for tracing; never cap output tokens small (returns empty)";
        match = "deepseek-v*-flash*";
        tier = "small";
        useFor = "codebase exploration, research reads, compaction, trivial re-verification";
      };
      minimax.minimax = {
        avoidFor = "judging or review (abstains, weak abstract reasoning)";
        effort = "no documented knob; expect long reasoning traces";
        match = "minimax-m*";
        tier = "mid";
        useFor = "well-scoped code to a spec; screenshot or image input";
      };
      moonshot = {
        kimi-k2 = {
          avoidFor = "build subagents on a time budget (slow, times out); mixed-goal prompts";
          effort = "always thinks";
          match = "kimi-k2*";
          tier = "mid";
          useFor = "coding with image input";
        };
        kimi-k3 = {
          avoidFor = "simple or latency-bound work (slow, always thinks); ambiguous briefs; mid-session model switches";
          effort = "always thinks; treat effort as fixed";
          match = "kimi-k3*";
          tier = "strong";
          useFor = "orchestration and review; frontend and browsing-heavy agentic work";
        };
      };
      nvidia.nemotron-ultra = {
        avoidFor = "review, building code, multi-file edits, long-horizon planning";
        effort = "keep the reasoning budget low; the value is speed";
        match = "nemotron-*-ultra*";
        tier = "small";
        useFor = "cheapest, fastest long-context reads: exploration, doc ingestion, confirming tests pass";
      };
      zhipu = lib.mapAttrs (_: family:
        family // {pools = lib.genAttrs ["claude" "codex" "kimchi"] (_: "zai-coding");}) {
        glm = {
          avoidFor = "image input (text-only); quick lookups (thinking cannot be turned off)";
          effort = "low, high or max; high default, max for judging";
          match = "glm-[0-9]*.[0-9]";
          tier = "strong";
          useFor = "planning, spec writing, judging; hard multi-file coding";
        };
        glm-flash = {
          avoidFor = "edits near untested working code; flaky tasks (extra time does not help); hard reasoning";
          effort = "token-hungry thinking; keep the default effort";
          match = "glm-*-flash";
          tier = "mid";
          useFor = "code to a spec; image or document input";
        };
      };
    };
    pools = {
      api-allowance = {
        description = "Example monthly allowance without a usage reader.";
        window = {
          limit = 100;
          resetDay = 1;
          unit = "credits";
        };
      };
      zai-coding = {
        description = "Example shared budget for GLM reaches.";
        usage = {
          runtime = "claude";
          technique = "zai-usage";
        };
      };
    };
    routing = {
      "Local limits" = {
        always = true;
        text = ''
          On this machine, run at most two external CLI delegates at once. This is not a
          parallelism limit for native subagents or workflow nodes.
        '';
      };
      "Orchestrator session".enable = true;
    };
    runtimes = {
      claude = {
        extraRuntimes = ["codex"];
        manualExternalDelegates = ["kimchi" "kiro"];
        models = [
          {vendors = ["anthropic"];}
          {families = ["glm" "glm-flash"];}
        ];
        techniques.zai-usage = {
          command = "${lib.getExe config.ai.internal.roots.delegate-routing-content.usageScripts.zai-usage} claude";
          kind = "usage";
        };
      };
      codex = {
        models = [
          {vendors = ["openai"];}
          {families = ["glm" "glm-flash"];}
        ];
        techniques.zai-usage = {
          command = "${lib.getExe config.ai.internal.roots.delegate-routing-content.usageScripts.zai-usage} codex";
          kind = "usage";
        };
      };
      kimchi.models = [{vendors = ["deepseek" "minimax" "moonshot" "nvidia" "zhipu"];}];
      # Operator choice: GPT models cost more credits on Kiro, so select Anthropic
      # only, and not Fable, which this account does not have.
      kiro = {
        models = [{families = ["haiku" "opus" "sonnet"];}];
      };
    };
  };
}
