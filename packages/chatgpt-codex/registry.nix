{
  facetOwner,
  repoPath,
  ...
}: {
  documentation.aiCliDescriptions.chatgpt-codex = "OpenAI Codex CLI";
  # Which package the shared app-server daemon runs, and why devenv runs Codex
  # without it: the selector, its lock and time budget, and what it releases.
  fragments.categories.codex-daemon = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "codex-daemon";
      }
    ];
  };
  update.targets.chatgpt-codex = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/chatgpt-codex/package.nix)];};
}
