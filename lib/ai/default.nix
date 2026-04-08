# lib.ai namespace — factory primitives + transformers + shared module.
{lib}: {
  app = import ./app {inherit lib;};
  apps = import ./apps {inherit lib;};
  mcpServer = import ./mcpServer {inherit lib;};
  mcpServers = import ./mcpServers {inherit lib;};
  sharedOptions = import ./sharedOptions.nix;
  transformers = import ./transformers {inherit lib;};
}
