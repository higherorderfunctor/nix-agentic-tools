{
  facetOwner,
  repoPath,
  ...
}: {
  documentation.devToolDescriptions."codeql.codeql-<engine>" = "GitHub CodeQL CLI: `bare`, `full`, or one language's bundle (unfree, x86_64-linux, never published)";
  fragments.categories.codeql = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        location = "package";
        name = "codeql";
        dir = facetOwner;
      }
      {
        location = "package";
        name = "customize";
        dir = facetOwner;
      }
    ];
  };
  # One target: every engine's script bumps every asset from the same tag.
  update.targets.codeql-full = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/devTools/codeql/codeql-full/package.nix)];};
}
