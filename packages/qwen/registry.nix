{repoPath, ...}: {
  checks.cacheHitParity."qwen3-embedding-0.6b-q8_0" = {
    consumerPath = ["models" "qwen3-embedding-0.6b-q8_0"];
  };
  update.targets."qwen3-embedding-0.6b-q8_0" = {
    file = repoPath ./packages/models/qwen3-embedding-0.6b-q8_0/package.nix;
    flags = ["--use-update-script"];
  };
}
