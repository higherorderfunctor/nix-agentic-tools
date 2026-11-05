{
  harness,
  lib,
  pkgs,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  resolveForges = import ../lib/sandbox/forges.nix {inherit lib;};
  hmModules = modules: harness.evalHmModules ([{ai.codex.pinDaemonToPackage = false;}] ++ modules);
  backends = {
    devenv = {
      eval = harness.evalDevenv;
      evalModules = harness.evalDevenvModules;
      port = 19419;
    };
    hm = {
      eval = config: hmModules [{inherit config;}];
      evalModules = hmModules;
      port = 19418;
    };
  };
  identity = token: forge: {
    push.key = redact.file "/tmp/sandbox-fixture-push-key";
    remotes.${token} = {inherit forge;};
    user = {
      email = "bot@example.invalid";
      name = "Sandbox Bot";
    };
  };
  identities = {
    x = identity "github-alias" "github.com";
    y = identity "git.example.invalid" "git.example.invalid";
  };
  pins = "git.example.invalid ssh-ed25519 fixture";
  fixture.ai = {
    claude = {
      enable = true;
      package = pkgs.hello;
    };
    codex = {
      enable = true;
      package = pkgs.hello;
    };
    sandbox = {
      enable = true;
      git = {
        forges."git.example.invalid" = {
          hostKeys = pins;
          sshPort = 2222;
          sshUser = "bot";
        };
        inherit identities;
      };
    };
  };
  failures = result: map (item: item.message) (builtins.filter (item: !item.assertion) result.config.assertions);
  containsFailure = needle: result: lib.any (lib.hasInfix needle) (failures result);
  succeeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  check = name: predicate:
    lib.mapAttrs' (backend: api:
      lib.nameValuePair "microvm-identities-${name}-${backend}"
      (harness.mkTest "microvm-identities-${name}-${backend}" (predicate api)))
    backends;
in {
  checks =
    check "copy-down" (api: let
      result = api.eval fixture;
      replaced = api.eval (lib.recursiveUpdate fixture {ai.codex.sandbox.git.identities = {inherit (identities) x;};});
      defaultReplaced = api.eval (lib.recursiveUpdate fixture {ai.codex.sandbox.git.identities = lib.mkDefault {};});
      opted = api.evalModules [fixture ({config, ...}: {ai.codex.sandbox.git.identities = {inherit (config.ai.sandbox.git.identities) x;};})];
      forgesReplaced = api.eval (lib.recursiveUpdate fixture {ai.codex.sandbox.git.forges."git.example.invalid".sshPort = 2200;});
    in
      lib.all (runtime:
        result.config.ai.${runtime}.sandbox.git.identities
        == result.config.ai.sandbox.git.identities
        && result.options.ai.${runtime}.sandbox.git.identities.highestPrio == 1500
        # Runtimes inherit endpoints but never the root's pins.
        && result.config.ai.${runtime}.sandbox.git.forges
        == {
          "git.example.invalid" = {
            sshPort = 2222;
            sshUser = "bot";
          };
        })
      ["claude" "codex"]
      && forgesReplaced.config.ai.codex.sandbox.git.forges
      == {
        "git.example.invalid" = {
          sshPort = 2200;
          sshUser = null;
        };
      }
      && forgesReplaced.config.ai.claude.sandbox.git.forges."git.example.invalid".sshPort == 2222
      && builtins.attrNames replaced.config.ai.codex.sandbox.git.identities == ["x"]
      && defaultReplaced.config.ai.codex.sandbox.git.identities == {}
      && builtins.attrNames opted.config.ai.codex.sandbox.git.identities == ["x"]
      && opted.config.ai.codex.sandbox.git.identities.x == result.config.ai.sandbox.git.identities.x
      && failures result == [])
    // check "refusals" (api: let
      changed = change: api.eval (lib.recursiveUpdate fixture change);
      duplicate = changed {
        ai.codex.sandbox.git.identities = {
          first = identities.x;
          second = identities.x;
        };
      };
      runtimePins = changed {ai.codex.sandbox.git.forges."git.example.invalid".hostKeys = "git.example.invalid ssh-ed25519 rotated";};
      # Validate invalid identity inputs without lowering them into the relay's
      # stricter lines option, which rejects absent pins before assertions run.
      invalid = change: changed (lib.recursiveUpdate change {ai.sandbox.enable = false;});
      plaintext = changed {ai.sandbox.git.identities.x.push.key = "plaintext";};
    in
      containsFailure "Sandbox remote token github-alias: claimed by ai.codex.sandbox.git.identities.first and ai.codex.sandbox.git.identities.second" duplicate
      && containsFailure "ai.sandbox.git.forges.\"unpinned.invalid\".hostKeys" (invalid {ai.codex.sandbox.git.identities.x = identity "unpinned.invalid" "unpinned.invalid";})
      && containsFailure "remotes.\"bad/token\"" (invalid {ai.codex.sandbox.git.identities.x = identity "bad/token" "github.com";})
      && containsFailure "remotes.\"valid\".forge" (invalid {ai.codex.sandbox.git.identities.x = identity "valid" "bad/forge";})
      && containsFailure "forges.\"bad/forge\"" (invalid {ai.codex.sandbox.git.forges."bad/forge".sshPort = 22;})
      # An inherited bad entry fails once, at the root, and not again per runtime.
      && builtins.length (builtins.filter (lib.hasInfix "remotes.\"bad/token\"") (failures (invalid {ai.sandbox.git.identities.x = identity "bad/token" "github.com";}))) == 1
      && containsFailure "ai.codex.sandbox.git.identities.x.remotes.\"bad/token\"" (invalid {ai.codex.sandbox.git.identities.x = identity "bad/token" "github.com";})
      && containsFailure "forges.\"github.com\".hostKeys" (invalid {ai.sandbox.git.forges."github.com".hostKeys = " \n";})
      # The relay keeps one pin set per host, so a runtime cannot declare pins.
      && !succeeds runtimePins.config.ai.codex.sandbox.git.forges
      && !succeeds plaintext.config.ai.sandbox.git.identities.x.push.key
      && !succeeds (api.eval {ai.sandbox.git.identities.missing = {};}).config.ai.sandbox.git.identities.missing
      && failures (changed {
        ai.codex.sandbox.enable = false;
        ai.codex.sandbox.git.identities = {
          first = identities.x;
          second = identities.x;
        };
      })
      == [])
    // check "relay" (api: let
      result = api.evalModules [
        fixture
        {
          options.devenv.reviewFixture = lib.mkOption {
            default = false;
            type = lib.types.bool;
          };
        }
      ];
      instance = result.config.ai.git-relay.instances.sandbox;
      native = api.eval (lib.recursiveUpdate fixture {
        ai.git-relay.instances.sandbox = {
          port = 20123;
          settings = {
            credentials.claude-x = {
              forges = ["gitlab.com"];
              sshKeyFile = redact.file "/tmp/native-push-key";
            };
            forges."github.com".hostKeys = "github.com ssh-ed25519 native";
          };
        };
      });
      rendered = builtins.fromJSON result.config.ai.services.git-relay-sandbox.files.config.content;
      overriddenPins = api.eval (lib.recursiveUpdate fixture {ai.sandbox.git.forges."github.com".hostKeys = "github.com ssh-ed25519 custom";});
      runtimeEndpoint = api.eval (lib.recursiveUpdate fixture {ai.codex.sandbox.git.forges."git.example.invalid".sshPort = 2200;});
    in
      builtins.attrNames instance.settings.credentials
      == ["claude-x" "claude-y" "codex-x" "codex-y"]
      && lib.all (runtime:
        instance.settings.credentials."${runtime}-x".forges
        == ["github.com"]
        && instance.settings.credentials."${runtime}-y".forges == ["git.example.invalid"]
        && instance.settings.credentials."${runtime}-x".sshKeyFile == result.config.ai.${runtime}.sandbox.git.identities.x.push.key) ["claude" "codex"]
      && instance.settings.forges."git.example.invalid".hostKeys == pins
      && runtimeEndpoint.config.ai.git-relay.instances.sandbox.settings.forges."git.example.invalid".hostKeys == pins
      && failures runtimeEndpoint == []
      && instance.settings.sessions == true
      && instance.settings.repositories == {}
      && instance.port == api.port
      && instance.settings.port == api.port
      && rendered.sessions
      && rendered.repositories == {}
      && native.config.ai.git-relay.instances.sandbox.port == 20123
      && native.config.ai.git-relay.instances.sandbox.settings.credentials.claude-x.forges == ["gitlab.com"]
      && native.config.ai.git-relay.instances.sandbox.settings.credentials.claude-x.sshKeyFile == {_redact.asFile = redact.file "/tmp/native-push-key";}
      && native.config.ai.git-relay.instances.sandbox.settings.forges."github.com".hostKeys == "github.com ssh-ed25519 native"
      && overriddenPins.config.ai.git-relay.instances.sandbox.settings.forges."github.com".hostKeys == "github.com ssh-ed25519 custom"
      && containsFailure "sandbox.settings.sessions must be true" (api.eval (lib.recursiveUpdate fixture {ai.git-relay.instances.sandbox.settings.sessions = false;}))
      && containsFailure "session-only instance serves no repositories" (api.eval (lib.recursiveUpdate fixture {
        ai.git-relay.instances.sandbox.settings.repositories.static = {
          credential = "claude-x";
          upstream = "git@github.com:owner/repo";
        };
      }))
      && failures native == []
      && failures result == [])
    // check "empty" (api:
      (api.eval {}).config.ai.git-relay.instances
      == {}
      && (api.eval {
        ai.sandbox.enable = true;
        ai.claude.enable = true;
      }).config.ai.git-relay.instances
      == {}
      && (api.eval {
        ai.sandbox = fixture.ai.sandbox;
        ai.kiro.cli.enable = true;
      }).config.ai.git-relay.instances
      == {}
      && (api.eval (lib.recursiveUpdate fixture {ai.sandbox.enable = false;})).config.ai.git-relay.instances == {})
    // {
      microvm-identities-forges = harness.mkTest "microvm-identities-forges" (let
        resolved = resolveForges {
          "git.example.invalid" = {
            hostKeys = pins;
            sshPort = null;
            sshUser = "bot";
          };
          "github.com" = {
            hostKeys = null;
            sshPort = 2222;
            sshUser = null;
          };
        };
      in
        # A null field retains the built-in fact; a non-null field overrides only itself.
        lib.hasPrefix "github.com ssh-ed25519 " resolved."github.com".hostKeys
        && resolved."github.com".sshPort == 2222
        && resolved."github.com".sshUser == "git"
        && resolved."git.example.invalid"
        == {
          hostKeys = pins;
          sshPort = 22;
          sshUser = "bot";
        });
    };
}
