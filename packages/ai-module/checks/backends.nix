# The two backend modules as the matrix and transition checks see them: one
# evaluation function and, per backend, where its generated entries, native
# links and secret edges live. The engine phases are read from the
# evaluated entries, so the modules stay their one definition; the devenv
# observer's snapshot and inspect entries are not engine phases.
{
  harness,
  lib,
  pkgs,
}: let
  sinks = lib.mapAttrs (_: sink:
    sink
    // {
      entry = config: name: (sink.entries config).${sink.prefix + name};
      phases = config: builtins.filter (phase: (sink.entries config) ? ${sink.prefix + phase}) ["apply" "guard" "prune"];
    }) {
    devenv = {
      command = entry: entry.exec;
      entries = config: config.tasks;
      inherit lib;
      module = ../modules/devenv/default.nix;
      native = config: config.files;
      prefix = "ai2:files2-";
      secrets = ["vault:ready"];
      stubs = harness.devenvStubs;
      target = item: "${item.file}";
    };
    hm = {
      command = entry: entry.text;
      entries = config: config.home.activation;
      lib = import ./dag-lib.nix lib;
      module = ../modules/homeManager/default.nix;
      native = config: config.home.file;
      prefix = "ai2-files2-";
      secrets = ["sops-nix" "vault:ready"];
      stubs = harness.hmStubs;
      target = item: "${item.source}";
    };
  };
  evaluate = backend: ai: let
    sink = sinks.${backend};
  in
    (lib.evalModules {
      specialArgs = {
        inherit (sink) lib;
        inherit pkgs;
      };
      modules = [
        sink.stubs
        sink.module
        {ai.activation2Order.secretNodes = ["vault:ready"];}
        {inherit ai;}
      ];
    }).config;
in {
  inherit evaluate sinks;
}
