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
  hm = harness.evalHmWithSpecialArgs {pkgs = testPkgs;} configuration;
  dev = harness.evalDevenvWithSpecialArgs {pkgs = testPkgs;} configuration;
  disabled = harness.evalDevenv {
    ai.kiro = {
      cli = {
        enable = true;
        inherit package;
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
  # Whether the deep-forced service command accepts the configured upstream CA path.
  acceptsUpstreamCaFile = value: let
    command =
      (harness.evalDevenv (lib.recursiveUpdate configuration {
        ai.kiro.cli.usageTracking.upstreamCaFile = value;
      })).config.ai.services.kiro-usage.command;
  in
    (builtins.tryEval (builtins.deepSeq command true)).success;
in {
  checks = {
    module-kiro-usage-tracking = harness.mkTest "kiro-usage-tracking" (
      dev.config.ai.services.kiro-usage.ports.proxy
      == 18091
      && hm.config.ai.services.kiro-usage.command == dev.config.ai.services.kiro-usage.command
      && lib.elem "${package}/bin/mitmdump" dev.config.ai.services.kiro-usage.command
      && acceptsUpstreamCaFile "/etc/nix/macos-ca.pem"
      && !(acceptsUpstreamCaFile "macos-ca.pem")
      && !(acceptsUpstreamCaFile ./usage-fake.py)
      && !(lib.elem "--upstream-ca-file" (usage.service disabled.config.ai.kiro.cli.usageTracking).command)
      && dev.config.ai.claims.port."18091" == ["kiro:kiro-usage.ports.proxy"]
      && themed hm
      && themed dev
      && !(lib.elem "--summary-theme" (usage.toolArgs disabled.config.ai.kiro.cli.usageTracking))
      && !(builtins.tryEval (harness.evalDevenv (lib.recursiveUpdate configuration {ai.kiro.cli.usageTracking.summary.border = "dashed";})).config.ai.kiro.cli.usageTracking.summary.border).success
      && !(disabled.config.ai.services ? kiro-usage)
      && !(disabled.config.env ? HTTPS_PROXY)
      && rejected {ai.kiro.cli.package = null;}
      && rejectedWith (withMitmproxy pkgs.python313Packages.mitmproxy)
      && rejectedWith (testPkgs // {python3 = pkgs.python313;})
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
