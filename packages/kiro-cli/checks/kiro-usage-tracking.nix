# Module and generated-launcher checks use only synthetic local processes.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  fake = pkgs.writeScript "kiro-usage-fake" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ./usage-fake.py}
  '';
  package = pkgs.runCommand "kiro-usage-fakes" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/bin"
    for name in kiro-cli kiro-cli-chat mitmdump; do
      ln -s ${fake} "$out/bin/$name"
    done
  '';
  testPkgs = pkgs // {mitmproxy = package;};
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
        };
        v3 = true;
      };
    };
  };
  hm = harness.evalHmWithSpecialArgs {pkgs = testPkgs;} configuration;
  dev = harness.evalDevenvWithSpecialArgs {pkgs = testPkgs;} configuration;
  disabled = harness.evalDevenv {
    ai.kiro = {
      cli = {
        enable = true;
        inherit package;
        v3 = false;
      };
    };
  };
  wrapped = ev: lib.findFirst (p: p.name == "kiro-cli-wrapped") (throw "missing managed Kiro launcher") (ev.config.packages or ev.config.home.packages);
  usage = import ../lib/usageTracking.nix {inherit lib pkgs;};
  # Only set summary keys reach the theme file, and only a set theme adds the flag.
  themed = ev:
    usage.summaryTheme ev.config.ai.kiro.cli.usageTracking
    == {
      border = "rounded";
      styles.total = "bold #ffaf00";
    }
    && lib.elem "--summary-theme" (usage.toolArgs ev.config.ai.kiro.cli.usageTracking);
  rejected = change: lib.any (a: !a.assertion) (harness.evalDevenv (lib.recursiveUpdate configuration change)).config.assertions;
  # An interpreter without compression.zstd fails evaluation, whichever of the two carries it.
  rejectedWith = pkgs': lib.any (a: !a.assertion && lib.hasInfix "compression.zstd" a.message) (harness.evalDevenvWithSpecialArgs {pkgs = pkgs';} configuration).config.assertions;
  directWrapper = v3:
    (import ../lib/wrapPackage.nix {inherit lib pkgs;}).wrapPackage {
      inherit package v3;
      trustedMcpTools = [];
      usageTracking = dev.config.ai.kiro.cli.usageTracking;
    };
in {
  checks = {
    module-kiro-usage-tracking = harness.mkTest "kiro-usage-tracking" (
      dev.config.ai.services.kiro-usage.ports.proxy
      == 18091
      && hm.config.ai.services.kiro-usage.command == dev.config.ai.services.kiro-usage.command
      && dev.config.ai.claims.port."18091" == ["kiro:kiro-usage.ports.proxy"]
      && themed hm
      && themed dev
      && !(lib.elem "--summary-theme" (usage.toolArgs disabled.config.ai.kiro.cli.usageTracking))
      && !(builtins.tryEval (harness.evalDevenv (lib.recursiveUpdate configuration {ai.kiro.cli.usageTracking.summary.border = "dashed";})).config.ai.kiro.cli.usageTracking.summary.border).success
      && !(disabled.config.ai.services ? kiro-usage)
      && !(disabled.config.env ? HTTPS_PROXY)
      && rejected {ai.kiro.cli.package = null;}
      && rejected {ai.kiro.cli.v3 = false;}
      && rejectedWith (testPkgs // {mitmproxy = pkgs.python313Packages.mitmproxy;})
      && rejectedWith (testPkgs // {python3 = pkgs.python313;})
      && !(builtins.tryEval (directWrapper false).drvPath).success
      && (builtins.tryEval (directWrapper true).drvPath).success
      && rejected {ai.environmentVariables.HTTPS_PROXY = "http://another:1234";}
      && rejected {ai.kiro.cli.environmentVariables.NODE_EXTRA_CA_CERTS = "/another.pem";}
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
