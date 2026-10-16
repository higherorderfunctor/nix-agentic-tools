# lib.ai namespace — factory primitives + transformers + shared module.
{lib}: let
  dirHelpers = import ./dir-helpers.nix {inherit lib;};
in {
  agent = import ./agent.nix {inherit lib;};
  app = import ./app {inherit lib;};
  # `extracted {pkgs}`: the shared extraction builders (lib/extracted).
  extracted = import ../extracted;
  # One builder for generated Markdown and structured files.
  generated = import ../generated.nix {inherit lib;};
  # `guards pkgs`: the generated-file guards as programs and a check builder
  # for a consumer's own files (lib/markdown/guards.nix).
  guards = (import ../markdown/guards.nix {inherit lib;}).consumer;
  hooks = import ./hooks.nix {inherit lib;};
  # `linkDirectory pkgs name source`: a directory of top-level links into
  # source (lib/link-directory.nix).
  linkDirectory = import ../link-directory.nix;
  # `mkLauncher pkgs {package, name, exe, …}`: the shared launcher wrapper.
  mkLauncher = import ./launcher.nix;
  mcpServer = import ./mcpServer {inherit lib;};
  program = import ./program.nix {inherit lib;};
  # Module function — imported unevaluated so consumers can pass it directly
  # to `lib.evalModules { modules = [ lib.ai.sharedOptions ... ]; }`.
  sharedOptions = import ./sharedOptions.nix;
  transformers = import ./transformers {inherit lib;};
  # Directory-based ingestion helpers (see lib/ai/dir-helpers.nix).
  # Consumer-facing — let a caller point at a directory without
  # surrendering the whole directory to a single derivation.
  inherit
    (dirHelpers)
    agentsFromDirWith
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
