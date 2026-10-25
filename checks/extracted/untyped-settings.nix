# Exercise option merging before each owner's renderer. Manager Plus has no
# `any` node today; its fixture adds one to test that renderer's config boundary.
{
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
    refuses = value: !(builtins.tryEval (builtins.deepSeq (render value) true)).success;
    plain = {nested = [1 "two" {three = true;}];};
  in {
    "${name}-any-lifts-a-reference" = let
      result = render {nested = [file];};
    in
      caller.output (builtins.fromJSON result.content)
      == {nested = [("{" + "$" + caller.placeholder + "}")];}
      && result.secrets == {${caller.placeholder} = file;};
    "${name}-any-preserves-json" = let
      result = render plain;
    in
      caller.output (builtins.fromJSON result.content) == plain && result.secrets == {};
    "${name}-any-refuses-malformed-markers" = lib.all (marker: refuses {nested = [marker];}) [
      {_redact.concat = ["literal"];}
      {
        _redact.file = "/run/secrets/probe";
        extra = true;
      }
    ];
    "${name}-any-refuses-non-json" = refuses (value: value);
  })
  callers
