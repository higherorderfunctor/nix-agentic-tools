# A consumer of the published Home Manager module and the devenv wiring.
# These are roots for a dry-run, not derivations to build as checks.
# Darwin cannot run ai.jail, ai.sandboxes, or glab.keyringSync. Beads is a
# devenv service; the legacy services.mcp-servers layer is Home Manager-only.
# Copilot's module writes repository instructions, not a CLI launcher. The
# OpenCode Go catalog is provider data, not an OpenCode runtime module.
{
  inputs,
  repository,
  self,
}: let
  system = "aarch64-darwin";
  inherit (inputs.nixpkgs) lib;
  pkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };
  inherit (self.lib) redact;
  secret = name: redact.file "/run/secrets/darwin-fixture-${name}";
  # Match the service-ordering fixture's Home Manager version without adding a
  # test-only input to every consumer flake's lock.
  hmLock = builtins.fromJSON (builtins.readFile ../../service-secret-ordering/flake.lock);
  homeManager = builtins.fetchTree hmLock.nodes.${hmLock.nodes.root.inputs.home-manager}.locked;
  harness = import ../../../lib/testing/module-harness.nix {
    inherit inputs lib pkgs;
    inherit (repository) moduleImports moduleInternals;
    injectAi = false;
    testing = {};
  };
  inherit (import ../../../lib/testing/mcp-fixtures.nix {inherit lib pkgs;}) proxySampleServer;
  specimen = import ../../runtime-files/specimen.nix {inherit lib;};
  runtimeModules = mode:
  # Shared inputs are declared once; only the backend-specific native
  # options and runtime enable switch come from each runtime's specimen.
    [{ai = removeAttrs (specimen mode "claude").ai ["claude"];}]
    ++ map (runtime: let
      sample = specimen mode runtime;
    in
      sample // {ai.${runtime} = sample.ai.${runtime};})
    harness.harnessNames;
  common = {config, ...}: {
    ai = {
      activation.probe.command = "${lib.getExe pkgs.hello} >/dev/null";
      airlock.instances.egress = {};
      cliproxyapi.instances.inference = {
        port = 8400;
        settings.access.api-keys = [(secret "cpa-client-key")];
      };
      cpa-manager-plus.instances.manager = {
        port = 18400;
        upstream = "inference";
      };
      files.".darwin-fixture".content.text = "Fixture file";
      kiro = {
        cli.usageTracking.enable = true;
        # Tracking owns Kiro's proxy and CA; other launchers use Airlock.
        proxy = {
          http = null;
          https = null;
        };
      };
      mcpServers =
        {
          caddy-probe = proxySampleServer;
          context7-probe = {
            args = ["--transport" "stdio"];
            command = lib.getExe' config.ai.internal.packages.mcpServers.context7-mcp "context7-mcp";
          };
        }
        // config.ai.webex-mcp.mcpServers;
      programs = {
        # Every enabled runtime must select a family; these keep it valid.
        delegate-routing = {
          enable = true;
          runtimes = {
            kimchi.models = [{vendors = ["anthropic"];}];
            kiro.models = [{vendors = ["anthropic"];}];
          };
        };
        peer-communication.enable = true;
        semble.enable = true;
        stacked-workflows.enable = true;
      };
      proxy.instance = "egress";
      settings = {
        inference = {
          key = secret "cpa-client-key";
          url = "http://127.0.0.1:8400";
        };
        reasoningEffort = "high";
      };
      shell = pkgs.bash;
      webex-mcp.instances.probe = {
        enable = true;
        oauth = {
          clientId = secret "oauth-client-id";
          clientSecret = secret "oauth-client-secret";
        };
      };
    };
    git = {
      absorb.enable = true;
      branchless.enable = true;
      revise.enable = true;
    };
    glab = {
      enable = true;
      host = "git.example.invalid";
      token = secret "glab-token";
    };
  };
  # Exercise both the bridge and native HTTP launchers. Discover the server
  # option names from the published module so new additions join the scan.
  hmOptions = {options, ...}: let
    mcp = import ../../../lib/mcp.nix {inherit lib;};
  in {
    home = {
      homeDirectory = "/Users/darwin-fixture";
      stateVersion = "26.11";
      username = "darwin-fixture";
    };
    programs.git.enable = true;
    services.mcp-servers.servers =
      lib.mapAttrs (name: _: {
        enable = true;
        settings =
          lib.mapAttrs (option: _: secret "${name}-${option}") ((mcp.loadServer name).meta.credentialVars or {})
          // lib.optionalAttrs (name == "chrome-devtools-mcp") {browserUrl = "http://127.0.0.1:9222";};
      })
      options.services.mcp-servers.servers;
  };
  hm = import "${homeManager}/lib/eval-config.nix" {
    inherit pkgs;
    modules = [self.homeManagerModules.default common hmOptions] ++ runtimeModules "hm";
  };
  devenv =
    (harness.evalDevenvModules ([
        common
        {
          services.beads = {
            enable = true;
            issuePrefix = "probe";
            ledgerUrl = "ssh://git@example.invalid/probe-ledger.git";
          };
        }
      ]
      ++ runtimeModules "devenv"))
    .config;
  # Devenv's module harness uses the real NAT modules and upstream file
  # resolution, without requiring the CLI. Carry the store string contexts
  # from the delivered sinks, not a parallel list of their dependencies.
  stringsRoot = name: value: pkgs.writeText "darwin-fixture-${name}" (builtins.toJSON value);
  failed = lib.filter (entry: !entry.assertion) devenv.assertions;
in {
  devenv-files = stringsRoot "devenv-files" (lib.mapAttrs (_: entry: toString entry.file) devenv.files);
  devenv-packages = assert lib.assertMsg (failed == []) (lib.concatMapStringsSep "\n" (entry: entry.message) failed);
    stringsRoot "devenv-packages" (map toString devenv.packages);
  devenv-processes = stringsRoot "devenv-processes" (lib.mapAttrs (_: process: process.exec) devenv.processes);
  devenv-tasks = stringsRoot "devenv-tasks" {
    inherit (devenv) enterShell enterTest env;
    tasks = lib.mapAttrs (_: task: task.exec or null) devenv.tasks;
  };
  # Home Manager's eval-config already enforces its config assertions.
  home-activation = hm.activationPackage;
  # This fixture-only writeText root must appear in the scanner's build plan.
  home-services = stringsRoot "home-services" (lib.mapAttrs (_: agent: agent.config.ProgramArguments) (lib.filterAttrs (_: agent: agent.enable) hm.config.launchd.agents));
}
