{config, ...}: {
  imports = [../../../git-relay/modules/devenv ../common.nix];
  packages = config.ai.internal.sandboxPackages;
}
