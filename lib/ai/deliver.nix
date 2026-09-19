# The delivery router: the one place where a runtime's delivery description
# becomes backend configuration.
#
# Both adapters call it, so everything that is not literally "which option name
# does this backend use" is decided once, here. It knows nothing about any
# runtime — its inputs are `ai.<runtime>.activation`, `ai.<runtime>.files` and
# the backend name — and no runtime may call it, which is what keeps the four
# sink attribute paths adapter-owned.
{lib}: let
  aiCommon = import ./ai-common.nix {inherit lib;};

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
  }: let
    edges = tokens: names: lib.filter (node: node != null) (map (token: tokens.${backend}.${token} or null) names);
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
  }
