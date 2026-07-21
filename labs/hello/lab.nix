# Smoke lab — proves the harness works end to end. Not a real experiment.
{
  description = "Smoke test: does a lab materialize a usable fake global?";

  global = {
    ai.claude.enable = true;
    ai.context = "You are running inside the nix-agentic-tools `hello` lab.";
  };

  project = {
    ai.claude.enable = true;
  };
}
