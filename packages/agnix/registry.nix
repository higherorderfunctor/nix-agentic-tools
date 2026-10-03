{repoPath, ...}: {
  documentation.gitToolDescriptions.agnix = "Linter, LSP, and MCP for AI config files";
  update = {
    excludePatterns = ["^agnix-lsp$" "^agnix-mcp$"];
    targets.agnix = {
      file = repoPath ./packages/ai/agnix/package.nix;
      flags = ["--version" "skip"];
      git = "https://github.com/agent-sh/agnix.git";
      dependsOn = ["rust-overlay"];
    };
  };
}
