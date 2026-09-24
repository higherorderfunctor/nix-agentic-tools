# lib.ai namespace — factory primitives + transformers + shared module.
{lib}: let
  dirHelpers = import ./dir-helpers.nix {inherit lib;};
in {
  agent = import ./agent.nix {inherit lib;};
  app = import ./app {inherit lib;};
  # The delivery method vocabulary and the rule that picks one from a file's
  # stated consumer facts. Exported because `ai.<runtime>.methodFor` documents
  # it as its default and a replacement delegates back to it.
  deliveryMethod = import ./deliveryMethod.nix {inherit lib;};
  hooks = import ./hooks.nix {inherit lib;};
  # `mkLauncher pkgs {package, name, exe, …}`: the shared launcher wrapper.
  mkLauncher = import ./launcher.nix;
  mcpServer = import ./mcpServer {inherit lib;};
  # ONE reconciler for everything a generation owns: whole files in a
  # directory and owned leaves in a shared document, as one plan. It replaced
  # the generated-bash materializer that used to sit beside it here.
  own = import ./own.nix {inherit lib;};
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
