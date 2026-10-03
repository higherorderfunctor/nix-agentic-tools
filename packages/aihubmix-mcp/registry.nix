_: {
  # The npm build-output patch needs manual re-authoring when upstream changes.
  # update.yml reports new releases without putting this persistent blocker in
  # the automatic update queue. Remove both exclusions once the patch is gone.
  documentation.mcpServerMeta.aihubmix-mcp = {
    description = "AIHubMix image and video generation";
    credentials = "Required";
  };
  update.excludePatterns = ["^aihubmix-mcp$"];
}
