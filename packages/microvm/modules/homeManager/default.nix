{config, ...}: {
  imports = [../../../git-relay/modules/homeManager ../common.nix];
  home.packages = config.ai.internal.sandboxPackages;
}
