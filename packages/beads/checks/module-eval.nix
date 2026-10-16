# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv mkTest;
in {
  checks = {
    module-beads-credential-url-rejected = mkTest "beads-credential-url-rejected" (
      let
        ev = evalDevenv {
          services.beads = {
            enable = true;
            issuePrefix = "fixture";
            ledgerUrl = "https://embedded-token@example.invalid/ledger.git";
          };
        };
        beadsAssertions = lib.filter (assertion: lib.hasPrefix "services.beads" assertion.message) ev.config.assertions;
      in
        lib.any (assertion: !assertion.assertion) beadsAssertions
        && ev.config.packages == []
    );

    module-beads-default-disabled = mkTest "beads-default-disabled" (
      let
        ev = evalDevenv {};
      in
        !ev.config.services.beads.enable
        && ev.config.packages == []
        && ev.config.processes == {}
        && !(ev.config.tasks ? "ai2:beads-prepare")
    );

    module-beads-devenv-wiring = mkTest "beads-devenv-wiring" (
      let
        ev = evalDevenv {
          services.beads = {
            enable = true;
            issuePrefix = "fixture";
            ledgerUrl = "file:///tmp/beads-ledger.git";
          };
        };
        assertionsPass = lib.all (assertion: assertion.assertion) (
          lib.filter (assertion: lib.hasPrefix "services.beads" assertion.message) ev.config.assertions
        );
      in
        assertionsPass
        && builtins.length ev.config.packages == 1
        && builtins.attrNames ev.config.processes == ["beads-publisher" "beads-server"]
        && builtins.filter (lib.hasPrefix "beads:") (builtins.attrNames ev.config.tasks)
        == ["beads:bootstrap" "beads:checkpoint" "beads:diagnostics" "beads:status"]
        && ev.config.tasks."ai2:beads-prepare".before == ["devenv:enterShell"]
        && lib.hasInfix " publisher" ev.config.processes.beads-publisher.exec
        && lib.hasInfix " server" ev.config.processes.beads-server.exec
    );

    module-beads-invalid-dolt-passthru-rejected = mkTest "beads-invalid-dolt-passthru-rejected" (
      let
        ev = evalDevenv {
          services.beads = {
            enable = true;
            issuePrefix = "fixture";
            ledgerUrl = "file:///tmp/beads-ledger.git";
            package = pkgs.runCommand "bd-with-invalid-dolt" {passthru.dolt = null;} "mkdir -p $out/bin";
          };
        };
        beadsAssertions = lib.filter (assertion: lib.hasPrefix "services.beads" assertion.message) ev.config.assertions;
      in
        lib.any (assertion: !assertion.assertion) beadsAssertions
        && ev.config.packages == []
        && ev.config.processes == {}
    );

    module-beads-missing-required-options-rejected = mkTest "beads-missing-required-options-rejected" (
      let
        ev = evalDevenv {services.beads.enable = true;};
        beadsAssertions = lib.filter (assertion: lib.hasPrefix "services.beads" assertion.message) ev.config.assertions;
      in
        builtins.length (lib.filter (assertion: !assertion.assertion) beadsAssertions)
        == 2
        && ev.config.packages == []
        && ev.config.processes == {}
    );

    module-beads-package-without-dolt-rejected = mkTest "beads-package-without-dolt-rejected" (
      let
        ev = evalDevenv {
          services.beads = {
            enable = true;
            issuePrefix = "fixture";
            ledgerUrl = "file:///tmp/beads-ledger.git";
            package = pkgs.writeShellScriptBin "bd" "exit 0";
          };
        };
        beadsAssertions = lib.filter (assertion: lib.hasPrefix "services.beads" assertion.message) ev.config.assertions;
      in
        lib.any (assertion: !assertion.assertion) beadsAssertions
        && ev.config.packages == []
        && ev.config.processes == {}
    );
  };
}
