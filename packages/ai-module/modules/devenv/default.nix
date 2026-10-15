{
  config,
  lib,
  ...
}: let
  nativeFiles = builtins.attrNames config.files != [];
in {
  imports = [../common.nix];
  config = {
    tasks = import ../../lib/lower-devenv.nix {inherit lib;} {
      entries = config.ai.activation2;
      inherit nativeFiles;
      secretNodes = config.ai.activation2Order.secretNodes;
    };
  };
}
