# Secret readiness for activation and services: each provider's native
# activation nodes and its login-time user unit. Home Manager always carries
# sops-nix, since a module may not define root ai.* defaults; HM's DAG and
# systemd's After= both ignore it when absent. Declaring `sops-nix` replaces it.
{lib}: {
  backend,
  providers,
  secretNodes,
}: let
  resolved =
    (lib.optionalAttrs (backend == "hm" && !(providers ? sops-nix)) {
      sops-nix = {
        nodes = ["sops-nix"];
        unit = "sops-nix.service";
      };
    })
    // providers;
in {
  nodes = lib.unique (lib.concatMap (provider: provider.nodes) (builtins.attrValues resolved) ++ secretNodes);
  units = lib.unique (lib.filter (unit: unit != null) (map (provider: provider.unit) (builtins.attrValues resolved)));
}
