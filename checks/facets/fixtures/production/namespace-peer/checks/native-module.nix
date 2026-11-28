{
  config,
  lib,
  options,
  pkgs,
  ...
}: {
  checks = lib.mkIf (config.testing.moduleProbes != []) {
    native-check-module = assert lib.assertMsg (config.testing.moduleProbes == [{nativeCheckProbe = true;}]) "the imported check must see the merged probe from another owner";
    # The declaration also exists in the isolated module; only the combined
    # options carry the probe definition from alpha.
    assert lib.assertMsg (map (definition: definition.value) options.testing.moduleProbes.definitionsWithLocations == [[{nativeCheckProbe = true;}]]) "the imported check must see another owner's option definition, not the isolated default";
      pkgs.writeTextDir "passed" "";
  };
}
