{config, ...}: {
  imports = [../../../git-relay/modules/homeManager (import ../common.nix {backend = "hm";})];
  home.packages = config.ai.internal.sandboxPackages;
}
