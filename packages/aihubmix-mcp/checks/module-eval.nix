{
  harness,
  pkgs,
  ...
}: let
  inherit (harness) checkRows hmLib mkTest;
in {
  checks = {
    # The server reads its credential from env, not settings.
    module-aihubmix-factory-call = mkTest "aihubmix-factory-call" (
      let
        mkAihubmix = import ../lib/mkAihubmix.nix;
        result =
          mkAihubmix {
            lib = hmLib;
            inherit pkgs;
          } {
            env.AIHUBMIX_API_KEY = "sentinel";
          };
      in
        checkRows "AIHubMix factory" {
          "consumer API key survives in the server environment" = (result.env.AIHUBMIX_API_KEY or null) == "sentinel";
          "default command names the installed executable" = result.command == "aihubmix-mcp";
          "default transport is stdio rather than inferred" = result.type == "stdio";
        }
    );
  };
}
