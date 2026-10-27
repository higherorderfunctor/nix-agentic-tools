# `ai.airlock.instances.<name>`: Airlock CONNECT proxies, the same on both
# backends apart from the default state root. The final Rust command reads the
# strict JSON document rendered at each start through `ai.services`.
backend: {lib, ...}: let
  instances = import ../../ai-module/lib/instances.nix {inherit lib;};
in {
  imports = [
    (instances.module {
      arguments = _: ''serve --config "$AIRLOCK_CONFIG"'';
      inherit backend;
      defaultPort = 8318;
      derived = {instance, ...}: {listen = "127.0.0.1:${toString instance.port}";};
      owner = "airlock";
      packagePath = "airlock";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "airlock";
      render = settings: {
        content = builtins.toJSON {inherit (settings) listen;};
        secrets = {};
      };
      settingsType = lib.types.submodule {
        options.listen = lib.mkOption {
          type = lib.types.str;
          description = "The strict JSON listen address. The instance fixes it to `127.0.0.1:<port>`.";
        };
      };
      tool = "Airlock";
      variable = "AIRLOCK_CONFIG";
    })
  ];
}
