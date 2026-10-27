# Helpers the Airlock checks share: pick a backend's evaluator, list failed
# assertions, report conditions by name, and find a service's launcher.
{
  harness,
  lib,
  pkgs,
}: let
  strictShellApplication = import ../../../lib/strict-shell-application.nix;
in {
  evaluate = backend:
    if backend == "hm"
    then harness.evalHm
    else harness.evalDevenv;
  evaluateModules = backend:
    if backend == "hm"
    then harness.evalHmModules
    else harness.evalDevenvModules;
  failures = evaluated: map (item: item.message) (lib.filter (item: !item.assertion) evaluated.config.assertions);
  # A check that fails with the names of every false condition, not just one.
  namedTest = name: conditions: let
    failing = builtins.attrNames (lib.filterAttrs (_: passed: !passed) conditions);
  in
    harness.mkTest name (lib.assertMsg (failing == []) "failing: ${lib.concatStringsSep ", " failing}");
  # A redact command reading the token file the runtime check names in
  # `$AIRLOCK_TEST_TOKEN`, so the token never enters the store.
  tokenReader = strictShellApplication pkgs {
    name = "airlock-test-token-reader";
    text = ''exec ${pkgs.coreutils}/bin/cat "$AIRLOCK_TEST_TOKEN"'';
  };
  serviceLauncher = backend: config: service:
    if backend == "hm"
    then config.systemd.user.services.${service}.Service.ExecStart
    else config.processes.${service}.exec;
  # PYTHONPATH for the runtime checks' shared `airlock_service` module.
  pythonPath = pkgs.linkFarm "airlock-check-python" [
    {
      name = "airlock_service.py";
      path = ./airlock_service.py;
    }
  ];
}
