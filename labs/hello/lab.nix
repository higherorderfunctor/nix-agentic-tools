# Smoke lab — proves the harness works end to end. Not a real experiment.
{
  description = "Smoke test: does a lab materialize a usable fake global?";

  global = {
    ai = {
      claude.enable = true;
      context = "You are running inside the nix-agentic-tools `hello` lab.";
      # Non-empty settings is REQUIRED for settings.json to be emitted at all.
      # Upstream home-manager gates the file behind
      #   cfg.settings != {} || cfg.marketplaces != {} || disabledMcpServerNames != []
      # (home-manager modules/programs/claude-code/default.nix:235), so a lab with
      # no settings produces .claude/CLAUDE.md and nothing else. Task 2 Step 5
      # asserts settings.json exists, and every real lab sets effort or model
      # anyway — so the smoke lab carries one too.
      # Valid values (overlays/claude-code-extracted.json): low medium high xhigh.
      claude.settings.effortLevel = "high";
    };
  };

  project = {
    ai.claude.enable = true;
  };
}
