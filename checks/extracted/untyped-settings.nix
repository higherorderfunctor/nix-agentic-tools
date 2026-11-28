# Exercise option merging before each owner's renderer. Manager Plus has no
# `any` node today; its fixture adds one to test that renderer's config boundary.
{
  harness,
  lib,
  self,
}: let
  redact = self.lib.redact;
  file = redact.file "/run/secrets/probe";
  callers = {
    cliproxyapi = {
      inherit (self.lib.cliproxyapi) render settingsType;
      input = value: {plugins.configs.probe = value;};
      output = value: value.plugins.configs.probe;
      placeholder = "CLIPROXYAPI_PLUGINS_CONFIGS_PROBE_NESTED_0";
    };
    cpa-manager-plus = {
      inherit (self.lib.cpa-manager-plus) render;
      input = value: {config.probe = value;};
      output = value: value.probe;
      placeholder = "CPA_MANAGER_PLUS_PROBE_NESTED_0";
      settingsType =
        (import ../../lib/extracted/options.nix {inherit lib;} {
          nodes = {
            config.type = "object";
            "config.probe".type = "any";
            environment.type = "object";
          };
          tool = "CPA Manager Plus fixture";
        }).type;
    };
  };
in
  lib.concatMapAttrs (name: caller: let
    render = value:
      caller.render
      (lib.evalModules {
        modules = [
          {
            options.value = lib.mkOption {type = caller.settingsType;};
            config.value = caller.input value;
          }
        ];
      }).config.value;
    inspect = value: let
      result = render value;
    in {
      inherit (result) secrets;
      value = caller.output (builtins.fromJSON result.content);
    };
    plain = {nested = [1 "two" {three = true;}];};
    refuses = invalid:
      harness.rejectsChange inspect {
        inherit invalid;
        valid = plain;
        expected = {
          secrets = {};
          value = plain;
        };
      };
  in
    {
      "${name}-any-lifts-a-reference" =
        inspect {nested = [file];}
        == {
          secrets.${caller.placeholder} = file;
          value.nested = [("{" + "$" + caller.placeholder + "}")];
        };
      "${name}-any-refuses-a-concat-without-a-reference" = refuses {nested = [{_redact.concat = ["literal"];}];};
      "${name}-any-refuses-a-reference-with-extra-fields" = refuses {
        nested = [
          {
            _redact.file = "/run/secrets/probe";
            extra = true;
          }
        ];
      };
    }
    # The shared JSON type rejects functions before either renderer runs.
    // lib.optionalAttrs (name == "cliproxyapi") {
      "${name}-any-refuses-non-json" = refuses (value: value);
    })
  callers
