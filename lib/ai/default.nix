# lib.ai namespace — factory primitives + transformers + shared module.
{lib}: let
  dirHelpers = import ./dir-helpers.nix {inherit lib;};
in {
  agent = import ./agent.nix {inherit lib;};
  app = import ./app {inherit lib;};
  apps = import ./apps {inherit lib;};
  hooks = import ./hooks.nix {inherit lib;};
  # Compose an app's single always-on instructions file = context baseline +
  # unnamed instructions (named live in their own per-name files). Consumed by
  # the Claude + Copilot per-app factories; see composeInstructionsFile.nix.
  composeInstructionsFile = import ./composeInstructionsFile.nix {inherit lib;};
  # Strategy-driven file materializer (steering surfaces): symlink
  # entries keep the legacy declarative shapes; copy entries become
  # REAL files via generated HM activation / devenv task writers.
  materialize = import ./materialize.nix {inherit lib;};
  mcpServer = import ./mcpServer {inherit lib;};
  mcpServers = import ./mcpServers {inherit lib;};
  # Module function — imported unevaluated so consumers can pass it directly
  # to `lib.evalModules { modules = [ lib.ai.sharedOptions ... ]; }`.
  sharedOptions = import ./sharedOptions.nix;
  transformers = import ./transformers {inherit lib;};
  # Directory-based ingestion helpers (see lib/ai/dir-helpers.nix).
  # Consumer-facing — let a caller point at a directory without
  # surrendering the whole directory to a single derivation.
  inherit
    (dirHelpers)
    agentsFromDir
    hooksFromDir
    rulesFromDir
    skillsFromDir
    ;
  # Re-export selected mcp helpers under lib.ai.* so per-package factory
  # `lib.extend (...: prev: {ai = ...;})` makes them visible to the
  # module config functions without requiring a separate extend.
  inherit
    (import ../mcp.nix {inherit lib;})
    mkHttpEntry
    mkPackageEntry
    mkStdioEntry
    renderServer
    ;
}
