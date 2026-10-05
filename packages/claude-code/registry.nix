{facetOwner, ...}: {
  # This key names the bot's branch (`update/claude-code`), and
  # .github/workflows/ci.yml gates the heron_brook reminder step on exactly
  # that branch. Rename it here and you must rename it there too, or the
  # reminder silently never fires — packages/claude-code/checks/claude-heron-brook.nix asserts the
  # two agree.
  documentation.aiCliDescriptions.claude-code = "Claude Code CLI";
  # claude-code: package and plugin delivery plus the heron_brook
  # delegation-clamp evidence and its review tripwire. Spans the claude-code
  # overlay package and the factory-built module.
  fragments.categories.claude-code = {
    scopes = [
      "packages/${facetOwner}/packages/ai/claude-code/package.nix"
      "packages/${facetOwner}/**"
    ];
    sources = [
      {
        location = "package";
        name = "claude-code-wrapper";
        dir = facetOwner;
      }
      {
        location = "package";
        name = "heron-brook-clamp";
        dir = facetOwner;
      }
    ];
  };
  update.targets.claude-code = {flags = ["--use-update-script"];};
}
