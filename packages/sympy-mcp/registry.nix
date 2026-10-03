{repoPath, ...}: {
  documentation.mcpServerMeta.sympy-mcp = {
    description = "Symbolic mathematics";
    credentials = "None";
  };
  update.targets.sympy-mcp = {
    file = repoPath ./packages/ai/mcpServers/sympy-mcp/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/sdiehl/sympy-mcp.git";
  };
}
