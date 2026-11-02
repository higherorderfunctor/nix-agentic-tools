{config, ...}: {
  imports = [../../../git-relay/modules/devenv (import ../common.nix {backend = "devenv";})];
  packages = config.ai.internal.sandboxPackages;
}
