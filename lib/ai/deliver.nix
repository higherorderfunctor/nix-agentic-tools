# The delivery router: the one place where a runtime's delivery description
# becomes backend configuration.
#
# Both adapters call it, so everything that is not literally "which option name
# does this backend use" is decided once, here. It knows nothing about any
# runtime — its inputs are `ai.<runtime>.activation`, `ai.<runtime>.files` and
# the backend name — and no runtime may call it, which is what keeps the four
# sink attribute paths adapter-owned.
{
  lib,
  pkgs,
}: let
  aiCommon = import ./ai-common.nix {inherit lib;};
  deliveryMethod = import ./deliveryMethod.nix {inherit lib;};
  formats = import ./formats.nix {inherit lib pkgs;};
  runtimeFiles = import ./runtime-files.nix {inherit lib;};

  # The methods this layer delivers today. `upstream` is declared and not yet
  # routed: it is how a surface another module owns stays visible in the
  # delivery description, and it lands with the factory that needs it.
  routed = ["symlink"];

  # Abstract ordering tokens → the node each backend actually has. A token with
  # no node on this backend is DROPPED rather than translated into a name that
  # backend's runner would reject: devenv has no secret-provider node at all,
  # and a dangling task reference is a hard error there.
  afterTokens = {
    devenv.files = "devenv:files:cleanup";
    hm = {
      files = "linkGeneration";
      secrets = "sops-nix";
    };
  };
  beforeTokens = {
    devenv.shell = "devenv:enterShell";
    hm.linkCheck = "checkLinkTargets";
  };
in
  {
    backend,
    cfg,
    config,
    runtime,
  }: let
    edges = tokens: names: lib.filter (node: node != null) (map (token: tokens.${backend}.${token} or null) names);

    # An entry a consumer suppressed with `null` is not a file; everything
    # below sees live entries only.
    live = lib.filterAttrs (_path: entry: entry != null) cfg.files;

    # The ONE place a method is resolved. Not at type level and not in an
    # `apply`: both would read a sibling option while the option they belong to
    # is still merging, and `ai.<runtime>.files` carries an `apply` of its own.
    # Here `cfg` is finished, so `mkForce` on `method` and on `methodFor` both
    # work and compose.
    resolve = path: entry:
      entry
      // {
        inherit path;
        method =
          if entry.method != null
          then entry.method
          else
            cfg.methodFor {
              inherit backend path;
              inherit (entry) facts;
              default = deliveryMethod.byRule;
            };
        # Structured content becomes bytes once, here, in whichever of the two
        # content tags the sinks and the reconciler both understand.
        content =
          if entry.content ? value
          then
            formats.render {
              inherit (entry) format;
              inherit path;
              inherit (entry.content) value;
            }
          else entry.content;
      };
    resolved = lib.mapAttrs resolve live;
    bucket = method: lib.filterAttrs (_path: entry: entry.method == method) resolved;
  in {
    afterEdges = writer: edges afterTokens writer.after ++ writer.afterNodes.${backend};
    beforeEdges = writer: edges beforeTokens writer.before;

    # A bespoke body is spliced into one script the backend also fills with
    # other people's code — home-manager concatenates every activation entry —
    # so the flags it sets must not outlive it. The subshell is that boundary,
    # and it is also why a failing body ends non-zero for the caller's `set -e`
    # instead of running `exit`, which would truncate the whole script.
    commandBody = writer:
      aiCommon.scopedActivation ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${writer.command}
      '';

    # Writers that own no files at all: their whole product is the body.
    commands = lib.filterAttrs (_name: writer: writer.command != null) cfg.activation;

    # `tasks."devenv:files"` exists only when the project declares files, and
    # devenv's runner hard-errors on a dangling reference, so that edge stays
    # conditional. It is read here, in a value the file buckets never consult,
    # because a fragment that decided WHETHER to write `config.files` by
    # reading `config.files` is a genuine cycle.
    hasFiles = (config.files or {}) != {};

    # A writer's entry name may differ per backend, and both spellings are
    # literals a consumer orders against.
    nameFor = value:
      if builtins.isString value
      then value
      else value.${backend};

    # The backend's own store-symlink primitive, in the shape both file sinks
    # take. Home Manager recurses a directory source itself; devenv has no such
    # primitive, so the router walks the tree and emits one entry per leaf —
    # the leaves are ordinary entries, so `recursive` is off for each of them.
    symlinkEntries =
      lib.concatMapAttrs (
        path: entry:
          if entry.recursive && backend == "devenv"
          then
            lib.mapAttrs (
              _leaf: source:
                runtimeFiles.sinkEntry (entry
                  // {
                    content = {inherit source;};
                    recursive = false;
                  })
            ) (formats.walk path entry.content.source)
          else {${path} = runtimeFiles.sinkEntry entry;}
      )
      (bucket "symlink");

    # A method the layer does not deliver yet must say so. Silently dropping
    # the file is the one outcome that looks like success.
    assertions =
      lib.mapAttrsToList (path: entry: {
        assertion = lib.elem entry.method routed;
        message = ''
          ai.${runtime}.files."${path}" resolves to method `${entry.method}`,
          which the delivery layer does not route yet. Until it does, state
          `method = "symlink"` or deliver the file from the factory.
        '';
      })
      resolved;
  }
