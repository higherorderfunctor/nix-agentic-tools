{config, ...}: {
  imports = [../common.nix];
  home.packages = config.ai.internal.sandboxPackages;
}
