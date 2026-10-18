# The generated settings type, its render and Manager Plus's own loader agree:
# a sample that sets every leaf loads through internal/config's
# LoadWithoutCreatingDefault, with the rendered environment set and each
# redact reference in it replaced by a dummy value. The environment is also
# accepted by redact.types.environment, the type a service's environment has.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (import ../lib/default.nix {inherit lib;}) cpa-manager-plus;
  inherit (import ../../../lib/extracted/render.nix {inherit lib;}) fill;
  redact = import ../../../lib/redact {inherit lib;};
  # Values the loader parses beyond their node type: config.go,
  # resolveUsageArchiveRetentionDays, refuses a variable that is not an
  # integer.
  overrides."environment.USAGE_ARCHIVE_RETENTION_DAYS" = "30";
  evaluated = lib.evalModules {
    modules = [
      {
        options = {
          environment = lib.mkOption {type = redact.types.environment;};
          settings = lib.mkOption {type = cpa-manager-plus.settingsType;};
        };
        config.settings = cpa-manager-plus.sample {inherit overrides;};
      }
      ({config, ...}: {inherit (cpa-manager-plus.render config.settings) environment;})
    ];
  };
  rendered = cpa-manager-plus.render evaluated.config.settings;
  dummy = name: "dummy-${name}";
in {
  checks.cpa-manager-plus-settings = (extractedLib {inherit pkgs;}).goTest {
    sources = {
      "nat_config.json" = pkgs.writeText "cpa-manager-plus-settings-sample.json" (fill (lib.mapAttrs (name: _: dummy name) rendered.secrets) rendered.content);
      "nat_environment.json" = pkgs.writeText "cpa-manager-plus-settings-environment.json" (builtins.toJSON (lib.mapAttrs (name: value:
        if builtins.isString value
        then value
        else dummy name)
      evaluated.config.environment));
      "nat_load_test.go" = ./settings_test.go;
    };
    name = "cpa-manager-plus-settings";
    package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cpa-manager-plus;
    packagePath = "internal/config";
    postTest = ''echo "ok — CPA Manager Plus loads the rendered settings sample" >"$out"'';
    run = "TestNatLoad";
  };
}
