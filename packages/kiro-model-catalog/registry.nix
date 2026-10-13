{
  facetOwner,
  repoPath,
  ...
}: {
  fragments.categories.kiro-model-catalog = {
    scopes = [
      "dev/tasks/check.nix"
      "packages/kiro-cli/checks/module-eval.nix"
      "packages/kiro-cli/lib/mkKiro.nix"
      "packages/${facetOwner}/**"
    ];
    sources = [
      {
        location = "package";
        name = "model-catalog";
        dir = facetOwner;
      }
    ];
  };
  update.targets.kiro-model-catalog = {
    flags = ["--use-update-script" "--override-filename" (repoPath ./packages/docs/kiro-model-catalog/package.nix)];
  };
}
