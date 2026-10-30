# cases.nix tests routing delivery without the operator's personal devenv config.
{
  imports = [../../../checks/instructions/fixtures/local-runtimes.nix];
  ai.programs.delegate-routing = {
    enable = true;
    families.moonshot.kimi-k3 = {
      avoidFor = "simple or latency-bound work; ambiguous briefs; mid-session model switches";
      effort = "always thinks; treat effort as fixed";
      match = "kimi-k3*";
      tier = "strong";
      useFor = "orchestration and review; frontend and browsing-heavy agentic work";
    };
    runtimes = {
      claude = {
        extraRuntimes = ["codex"];
        # The headroom cases compare this policy with the same policy disabled.
        routing."Pool drain" = {
          after = ["Size the work"];
          always = true;
          text = "Before each batch of delegates, run every usage command the skill lists. When Claude has less remaining headroom than Codex, use an external Codex delegate for the implementation.";
        };
      };
      kimchi.models = [{vendors = ["moonshot"];}];
      kiro.models = [{families = ["haiku" "opus" "sonnet"];}];
    };
  };
}
