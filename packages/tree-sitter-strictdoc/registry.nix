{repoPath, ...}: {
  checks.cacheHitParity.tree-sitter-strictdoc.consumerPath = ["ai" "generic" "tree-sitter-strictdoc"];
  update.targets.tree-sitter-strictdoc = {
    file = repoPath ./packages/ai/generic/tree-sitter-strictdoc/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/manueldiagostino/tree-sitter-strictdoc.git";
  };
}
