# cspell:ignore AAAACUSTOM AAAAREPLACEMENT SSHKEYFILE
# Both backends render one placeholder per credential and refuse repository
# settings that cannot select a private key and a pinned SSH host.
{
  harness,
  lib,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  redact = import ../../../lib/redact {inherit lib;};
  forges = import ../lib/forges.nix;
  placeholder = name: "{" + "$" + name + "}";
  keys = {
    first = redact.file "/run/secrets/git-relay-first-key";
    second = redact.file "/run/secrets/git-relay-second-key";
  };
  hosts = {
    first = "github.com";
    second = "gitlab.com";
  };
  keyed = {
    port = 19500;
    settings = {
      credentials =
        lib.mapAttrs (name: sshKeyFile: {
          forges = [hosts.${name}];
          inherit sshKeyFile;
        })
        keys;
      repositories = {
        alpha = {
          credential = "first";
          upstream = "git@github.com:owner/alpha.git";
        };
        beta = {
          credential = "second";
          upstream = "ssh://git@gitlab.com:2222/owner/beta.git";
        };
      };
    };
  };
  sessionOnly = {
    port = 19503;
    settings = {
      credentials = keyed.settings.credentials;
      sessions = true;
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
    customPins = {
      "custom.example.invalid".hostKeys = "custom.example.invalid ssh-ed25519 AAAACUSTOM";
      "github.com".hostKeys = "github.com ssh-ed25519 AAAAREPLACEMENT";
    };
    custom = evaluate backend {
      main = keyed // {settings = keyed.settings // {forges = customPins;};};
    };
    session = evaluate backend {main = sessionOnly;};
    sessionContent = builtins.fromJSON session.config.ai.services.git-relay-main.files.config.content;
  in
    service.files.config.variable
    == "GIT_RELAY_CONFIG"
    && service.files.config.secrets
    == {
      GIT_RELAY_CREDENTIALS_FIRST_SSHKEYFILE = {_redact.asFile = keys.first;};
      GIT_RELAY_CREDENTIALS_SECOND_SSHKEYFILE = {_redact.asFile = keys.second;};
    }
    && builtins.fromJSON service.files.config.content
    == {
      credentials = {
        first = {
          forges = [hosts.first];
          sshKeyFile = placeholder "GIT_RELAY_CREDENTIALS_FIRST_SSHKEYFILE";
        };
        second = {
          forges = [hosts.second];
          sshKeyFile = placeholder "GIT_RELAY_CREDENTIALS_SECOND_SSHKEYFILE";
        };
      };
      inherit forges;
      listen = "127.0.0.1";
      port = 19500;
      inherit (keyed.settings) repositories;
    }
    && sessionContent.sessions == true
    && sessionContent.repositories == {}
    && sessionContent.credentials.first.forges == [hosts.first]
    && failures session == []
    && lib.all (name: !lib.hasInfix "git-relay-${name}-key" service.files.config.content) (builtins.attrNames keys)
    && (builtins.fromJSON custom.config.ai.services.git-relay-main.files.config.content).forges == forges // customPins
    && lib.hasSuffix "/bin/git-relay-main" (lib.head service.command)
    && config.ai.git-relay.instances.main.stateDir == "${stateRoot.${backend}}/git-relay/main"
    && config.ai.claims.port == {"19500" = ["git-relay:git-relay-main.ports.main"];}
    && (evaluate backend {main = {};}).config.ai.git-relay.instances.main.port == 19418
    && failures (evaluate backend {main = keyed;}) == [];

  refusals = backend: let
    # Force files and assertions: missing required options can fail either consumer.
    rejected = settings: let
      result = evaluate backend {main = keyed // {inherit settings;};};
    in
      !succeeds {
        inherit (result.config.ai.services.git-relay-main) files;
        inherit (result.config) assertions;
      }
      || failures result != [];
    changed = settings: rejected (lib.recursiveUpdate keyed.settings settings);
    messageOf = settings:
      lib.head (failures (evaluate backend {
        main = keyed // {settings = lib.recursiveUpdate keyed.settings settings;};
      }));
    named = name:
      failures (evaluate backend {
        main = keyed // {settings = keyed.settings // {repositories.${name} = keyed.settings.repositories.alpha;};};
      });
  in
    # The instance owns its port; credentials accept references, never plaintext.
    changed {port = 19501;}
    && changed {credentials.first.sshKeyFile = "plaintext";}
    && changed {credentials.first.sshKeyFile = null;}
    && rejected (keyed.settings // {credentials.first = {};})
    && changed {repositories.alpha.credential = "missing";}
    && rejected (keyed.settings // {repositories.alpha = builtins.removeAttrs keyed.settings.repositories.alpha ["credential"];})
    && rejected (keyed.settings // {repositories.alpha = builtins.removeAttrs keyed.settings.repositories.alpha ["upstream"];})
    && changed {repositories.alpha.upstream = "git@unpinned.example.invalid:owner/alpha.git";}
    && changed {forges."github.com".hostKeys = "";}
    && lib.all (upstream: changed {repositories.alpha = {inherit upstream;};}) [
      "/srv/upstream.git"
      "ext::echo unwanted"
      "file:///srv/upstream.git"
      "git://github.com/owner/alpha.git"
      "github.com::owner/alpha.git"
      "https://github.com/owner/alpha.git"
    ]
    # A session-only instance refuses static repositories; a credential's
    # allowlist must name each upstream host it serves and only real hosts.
    && changed {sessions = true;}
    && changed {credentials.first.forges = [];}
    && changed {credentials.first.forges = ["github.com/owner"];}
    && lib.hasInfix "settings.sessions" (messageOf {sessions = true;})
    && lib.hasInfix "credentials.first.forges.0" (messageOf {credentials.first.forges = ["github.com/owner"];})
    && named "alpha.git" == []
    && lib.all (name: lib.length (named name) == 1) ["-leading" ".hidden" "a/b" ".."]
    && builtins.all (name: lib.hasInfix "repositories.${name}" (lib.head (named name))) ["a/b" ".."];
in {
  checks.module-git-relay-instances = mkTest "git-relay-instances" (lib.all (backend: contract backend && refusals backend) ["devenv" "hm"]);
}
