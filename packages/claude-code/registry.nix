{facetOwner, ...}: {
  documentation.aiCliDescriptions.claude-code = "Claude Code CLI";
  # claude-code: package and plugin delivery plus heron_brook evidence.
  # Spans the claude-code overlay package and the factory-built module.
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
