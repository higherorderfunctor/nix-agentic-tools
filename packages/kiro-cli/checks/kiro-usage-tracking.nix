# Module and generated-launcher checks use only synthetic local processes.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows mkTest rejectsChange;
  fake = pkgs.writeScript "kiro-usage-fake" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ./usage-fake.py}
  '';
  package = pkgs.runCommand "kiro-usage-fakes" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/bin"
    for name in kiro-cli mitmdump; do
      ln -s ${fake} "$out/bin/$name"
    done
  '';
  # Inject where both modules read the proxy. A fallback to raw pkgs.mitmproxy
  # would miss the fake and could test the wrong interpreter.
  withMitmproxy = mitmproxy: pkgs // {ai = pkgs.ai // {generic = pkgs.ai.generic // {inherit mitmproxy;};};};
  testPkgs = withMitmproxy package;
  configuration = {
    ai.kiro = {
      cli = {
        enable = true;
        inherit package;
        usageTracking = {
          enable = true;
          port = 18091;
          summary = {
            border = "rounded";
            styles.total = "bold #ffaf00";
          };
          upstreamCaFile = "/etc/nix/macos-ca.pem";
        };
      };
    };
  };
  evalDev = pkgs': harness.evalDevenvWithSpecialArgs {pkgs = pkgs';};
  hm = harness.evalHmWithSpecialArgs {pkgs = testPkgs;} configuration;
  dev = evalDev testPkgs configuration;
  disabled = evalDev testPkgs {
    ai.kiro = {
      cli = {
        enable = true;
        inherit package;
      };
    };
  };
  wrapped = ev: lib.findFirst (p: p.name == "kiro-cli-wrapped") (throw "missing managed Kiro launcher") (ev.config.packages or ev.config.home.packages);
  usage = import ../lib/usageTracking.nix {inherit lib pkgs;};
  withChange = change: evalDev testPkgs (lib.recursiveUpdate configuration change);
  tracking = evaluated: evaluated.config.ai.kiro.cli.usageTracking;
  service = evaluated: evaluated.config.ai.services.kiro-usage;
  caPath = value: {ai.kiro.cli.usageTracking.upstreamCaFile = value;};
  border = value: {ai.kiro.cli.usageTracking.summary.border = value;};

  # These module assertions are data: pin the named assertion and its state,
  # rather than counting any unrelated failure as a rejection.
  assertionState = message: evaluated:
    map (a: a.assertion) (lib.filter (a: lib.hasInfix message a.message) evaluated.config.assertions);
  rejectsAssertion = message: evaluated:
    assertionState message dev == [true] && assertionState message evaluated == [false];
  ownsProxyEnv = rejectsAssertion "usageTracking owns HTTP(S)/ALL/NO_PROXY";
  needsZstd = rejectsAssertion "compression.zstd";

  # Only set summary keys reach the theme file, and only a set theme adds the flag.
  hasThemeFlag = cfg: lib.elem "--summary-theme" (usage.toolArgs cfg);
  themed = evaluated: let
    cfg = tracking evaluated;
  in
    usage.summaryTheme cfg
    == {
      border = "rounded";
      styles.total = "bold #ffaf00";
    }
    && hasThemeFlag cfg;
in {
  checks = {
    module-kiro-usage-tracking = mkTest "kiro-usage-tracking" (
      checkRows "Kiro usage tracking" {
        "Home Manager emits the same service command as devenv" = (service hm).command == (service dev).command;
        "an enabled service without a CA override leaves upstream verification at its default" =
          !(lib.elem "--upstream-ca-file" (service (withChange (caPath null))).command);
        "devenv passes only configured summary fields and emits the theme flag" = themed dev;
        "disabled tracking does not register a service" = !(disabled.config.ai.services ? kiro-usage);
        "disabled tracking does not set HTTPS_PROXY" = !(disabled.config.env ? HTTPS_PROXY);
        "the configured proxy port is claimed by the Kiro usage service" = dev.config.ai.claims.port."18091" == ["kiro:kiro-usage.ports.proxy"];
        "the default summary does not add a theme flag" = !(hasThemeFlag (tracking disabled));
      }
      && checkRows "Kiro usage tracking restrictions" {
        "a relative CA file string is not an absolute runtime path" = rejectsChange (value: (tracking (withChange (caPath value))).upstreamCaFile) {
          valid = "/etc/nix/macos-ca.pem";
          invalid = "macos-ca.pem";
          expected = "/etc/nix/macos-ca.pem";
        };
        "a source path is not a runtime CA file string" = rejectsChange (value: (tracking (withChange (caPath value))).upstreamCaFile) {
          valid = "/etc/nix/macos-ca.pem";
          invalid = ./usage-fake.py;
          expected = "/etc/nix/macos-ca.pem";
        };
        "a summary border outside the supported enum is rejected" = rejectsChange (value: (tracking (withChange (border value))).summary.border) {
          valid = "rounded";
          invalid = "dashed";
          expected = "rounded";
        };
        "an older CLI interpreter lacks compression.zstd even if mitmdump is a fake" = needsZstd (evalDev (testPkgs // {python3 = pkgs.python313;}) configuration);
        "an older mitmdump interpreter lacks compression.zstd even if the CLI interpreter supports it" = needsZstd (evalDev (withMitmproxy pkgs.python313Packages.mitmproxy) configuration);
        "tracking rejects a competing CA variable from the Kiro environment" = ownsProxyEnv (withChange {ai.kiro.cli.environmentVariables.NODE_EXTRA_CA_CERTS = "/another.pem";});
        "tracking rejects a competing HTTPS_PROXY from the shared environment" = ownsProxyEnv (withChange {ai.environmentVariables.HTTPS_PROXY = "http://another:1234";});
        "tracking requires a managed Kiro package" = rejectsAssertion "requires a managed ai.kiro.cli.package" (withChange {ai.kiro.cli.package = null;});
      }
    );
    kiro-usage-launchers = pkgs.runCommand "kiro-usage-launchers" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 ${./usage-integration.py} \
        ${wrapped hm} ${dev.config.processes.kiro-usage.exec} \
        ${wrapped disabled}
      touch "$out"
    '';
  };
}
