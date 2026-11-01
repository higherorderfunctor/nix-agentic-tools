{config, ...}: {
  imports = [../common.nix];
  packages = config.ai.internal.sandboxPackages;
}
