{repoPath, ...}: {
  documentation.mcpServerMeta.chrome-devtools-mcp = {
    description = "Chrome DevTools browser automation (stdio)";
    credentials = "None";
  };
  update.targets.chrome-devtools-mcp = {
    flags = [
      "--use-update-script"
      "--override-filename"
      (repoPath ./packages/ai/mcpServers/chrome-devtools-mcp/package.nix)
    ];
  };
}
