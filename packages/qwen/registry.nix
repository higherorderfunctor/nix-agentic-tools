{repoPath, ...}: {
  checks.cacheHitParity."qwen3-embedding-0.6b-q8_0" = {
    consumerPath = ["models" "qwen3-embedding-0.6b-q8_0"];
  };
  documentation.modelDescriptions."qwen3-embedding-0.6b-q8_0" = "Qwen3-Embedding-0.6B Q8_0 GGUF embedding weights (about 610 MiB)";
  update.targets."qwen3-embedding-0.6b-q8_0" = {
    file = repoPath ./packages/models/qwen3-embedding-0.6b-q8_0/package.nix;
    flags = ["--use-update-script"];
  };
}
