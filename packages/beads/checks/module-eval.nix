# cspell:ignore passthru unwired
# End-to-end module contracts; the shared harness discovers every backend.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows evalDevenv mkTest;
  base = {
    enable = true;
    issuePrefix = "fixture";
    ledgerUrl = "file:///tmp/beads-ledger.git";
  };
  evaluate = settings: let
    inherit ((evalDevenv {services.beads = settings;}).config) assertions packages processes tasks;
  in {
    inherit packages processes tasks;
    failures = map (assertion: assertion.message) (lib.filter (assertion:
      lib.hasPrefix "services.beads." assertion.message && !assertion.assertion)
    assertions);
  };
  packageFixture = name: attrs:
    pkgs.runCommand name attrs ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out/bin"
    '';
  taskNames = config: builtins.filter (lib.hasPrefix "beads:") (builtins.attrNames config.tasks);
  unwired = config:
    config.packages
    == []
    && config.processes == {}
    && taskNames config == []
    && !(config.tasks ? "ai:beads-prepare");
  # These are deferred module assertions, not merge exceptions. Read the exact
  # failed diagnostics as well as the outputs that must stay unwired.
  rejects = settings: expected: let
    result = evaluate settings;
  in
    lib.sort builtins.lessThan result.failures == expected && unwired result;
  packageRejects = package:
    rejects (base // {inherit package;}) ["services.beads.package must expose its exact Dolt derivation as passthru.dolt"];
in {
  checks = {
    module-beads-default-disabled = mkTest "beads-default-disabled" (
      let
        inherit ((evalDevenv {}).config) packages processes services tasks;
      in
        !services.beads.enable && unwired {inherit packages processes tasks;}
    );

    module-beads-devenv-wiring = mkTest "beads-devenv-wiring" (
      let
        active = evaluate base;
      in
        checkRows "Beads lifecycle configuration" {
          "guarded publisher and server are registered as separate native processes" =
            builtins.attrNames active.processes
            == ["beads-publisher" "beads-server"]
            && lib.hasSuffix "/bin/ai-service-beads-publisher" active.processes.beads-publisher.exec
            && lib.hasSuffix "/bin/ai-service-beads-server" active.processes.beads-server.exec;
          "HTTP userinfo without a password is rejected" = rejects (base // {ledgerUrl = "https://embedded-token@example.invalid/ledger.git";}) [
            "services.beads.ledgerUrl must be nonempty, single-line, and contain no embedded HTTP userinfo or URL password"
          ];
          "manual entry points are not dropped from native tasks" =
            taskNames active == ["beads:bootstrap" "beads:checkpoint" "beads:diagnostics" "beads:status"];
          "package missing Dolt cannot provision a lifecycle" = packageRejects (packageFixture "bd-without-dolt" {});
          "package with a non-derivation Dolt cannot provision a lifecycle" =
            packageRejects (packageFixture "bd-with-invalid-dolt" {passthru.dolt = null;});
          "prepare runs before the shell starts" = active.tasks."ai:beads-prepare".before == ["devenv:enterShell"];
          "required options cannot be omitted when enabled" = rejects {enable = true;} [
            "services.beads.issuePrefix is required when services.beads.enable is true"
            "services.beads.ledgerUrl is required when services.beads.enable is true"
          ];
          "valid settings pass assertions and install one package" =
            active.failures == [] && builtins.length active.packages == 1;
        }
    );
  };
}
