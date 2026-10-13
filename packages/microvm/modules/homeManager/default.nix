{
  config,
  pkgs,
  ...
}: {
  imports = [../common.nix];
  home.packages = map (config.ai.internal.mkSandbox pkgs) (builtins.attrValues config.ai.sandboxes);
}
