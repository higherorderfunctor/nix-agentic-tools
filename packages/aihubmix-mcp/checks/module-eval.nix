# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  pkgs,
  harness,
  ...
}: let
  redact = import ../../../lib/redact {lib = harness.hmLib;};
  inherit (harness) hmLib mkTest;
in {
  checks = {
    # Keeps the aihubmix factory from shipping dormant. Asserts more than its
    # context7 sibling below: that the defaults reach the result AND that a
    # consumer override merges on top — `env` is the live surface for
    # AIHUBMIX_API_KEY, since the server has no other config knobs.
    module-aihubmix-factory-call = mkTest "aihubmix-factory-call" (
      let
        mkAihubmix = import ../lib/mkAihubmix.nix;
        result =
          mkAihubmix {
            lib = hmLib;
            pkgs = pkgs // {ai = pkgs.ai or {};};
          } {
            env.AIHUBMIX_API_KEY = redact.file {path = "/run/secrets/aihubmix";};
          };
      in
        result.type
        == "stdio"
        && result.command == "aihubmix-mcp"
        && result.env.AIHUBMIX_API_KEY == redact.file {path = "/run/secrets/aihubmix";}
    );
  };
}
