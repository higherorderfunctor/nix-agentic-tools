# cspell:ignore SSHKEYFILE unkeyed
# `ai.git-relay.instances` on both backends: each instance is the service
# `git-relay-<name>` with a port claim and a rendered config, whose key is a
# placeholder and never a value.
{
  harness,
  lib,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  redact = import ../../../lib/redact {inherit lib;};
  placeholder = name: "{" + "$" + name + "}";
  key = redact.file "/run/secrets/git-relay-key";
  keyed = {
    port = 19500;
    settings = {
      repositories.alpha.upstream = "git@example.invalid:owner/alpha.git";
      sshKeyFile = key;
    };
  };
  evaluate = backend: instances:
    (
      if backend == "hm"
      then evalHm
      else evalDevenv
    ) {ai.git-relay.instances = instances;};
  stateRoot = {
    devenv = "/tmp/devenv-state";
    hm = "/home/test/.local/state";
  };
  succeeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  failures = result: map (item: item.message) (builtins.filter (item: !item.assertion) result.config.assertions);

  contract = backend: let
    inherit (evaluate backend {main = keyed;}) config;
    service = config.ai.services.git-relay-main;
    unkeyed = (evaluate backend {main = lib.recursiveUpdate keyed {settings.sshKeyFile = null;};}).config.ai.services.git-relay-main;
  in
    service.files.config.variable
    == "GIT_RELAY_CONFIG"
    && service.files.config.secrets
    == {GIT_RELAY_SSHKEYFILE = {_redact.asFile = key;};}
    && builtins.fromJSON service.files.config.content
    == {
      knownHosts = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n";
      listen = "127.0.0.1";
      port = 19500;
      repositories.alpha.upstream = "git@example.invalid:owner/alpha.git";
      sshKeyFile = placeholder "GIT_RELAY_SSHKEYFILE";
    }
    && !lib.hasInfix "git-relay-key" service.files.config.content
    && unkeyed.files.config.secrets == {}
    && !(builtins.fromJSON unkeyed.files.config.content ? sshKeyFile)
    && lib.hasSuffix "/bin/git-relay-main" (lib.head service.command)
    && config.ai.git-relay.instances.main.stateDir == "${stateRoot.${backend}}/git-relay/main"
    && config.ai.claims.port == {"19500" = ["git-relay:git-relay-main.ports.main"];}
    && (evaluate backend {main = {};}).config.ai.git-relay.instances.main.port == 19418
    && failures (evaluate backend {main = keyed;}) == [];

  refusals = backend: let
    rejected = settings: let
      result = evaluate backend {main = lib.recursiveUpdate keyed {inherit settings;};};
    in
      !succeeds result.config.ai.services.git-relay-main.files;
    named = name:
      failures (evaluate backend {main.settings.repositories.${name}.upstream = "u";});
  in
    # The port is the instance's.
    rejected {port = 19501;}
    # A reference only: a plaintext key would reach the store.
    && rejected {sshKeyFile = "plaintext";}
    && named "alpha.git" == []
    && lib.all (name: lib.length (named name) == 1) ["-leading" ".hidden" "a/b" ".."]
    && builtins.all (name: lib.hasInfix "repositories.${name}" (lib.head (named name))) ["a/b" ".."];
in {
  checks.module-git-relay-instances = mkTest "git-relay-instances" (lib.all (backend: contract backend && refusals backend) ["devenv" "hm"]);
}
