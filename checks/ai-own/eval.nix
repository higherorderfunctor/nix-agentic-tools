# `own.nix`'s own validation check: what the plan assembler accepts, what it
# refuses, and the shape of the entries each backend gets. It stands in for the
# generated-entry-shape check the bash materializer needed, and it reads the
# emitted body directly rather than extracting a heredoc from it.
{
  lib,
  pkgs,
  ...
}: let
  # A DAG stub that RECORDS its dependency list, because the positions are the
  # point: a prune entry that lost `checkLinkTargets` still looks fine in a
  # body diff and aborts activation on the first copy-to-symlink flip.
  ownLib =
    lib
    // {
      hm.dag = {
        entryAfter = after: text: {inherit after text;};
        entryBefore = before: text: {inherit before text;};
      };
    };
  own = import ../../lib/ai/own.nix {lib = ownLib;};
  base = {
    inherit pkgs;
    python = pkgs.python3;
  };

  # The three call shapes of design §8, with the content stubbed.
  kiroMcp = own (base
    // {
      after = ["sops-nix"];
      backend = "hm";
      entryNames = {
        prune = "materialize-kiro-settings-prune";
        write = "kiroMcpJson";
      };
      targets = [
        {
          codec = "dir";
          ledger = "materialize/kiro-settings.manifest";
          path = ".kiro/settings";
          units."mcp.json" = {
            mode = "0400";
            run = "printf '{}'";
          };
        }
        {
          codec = "json";
          ledger = "json-settings/kiro-mcp-fixture.json";
          path = ".kiro/settings/mcp.json";
          units = {};
        }
      ];
    });
  claudeUnpin = own (base
    // {
      backend = "hm";
      entryNames.write = "claudeUnpinLaunchEffort";
      targets = [
        {
          codec = "json";
          ledger = "json-settings/claude-unpin-launch-effort.json";
          path = ".claude.json";
          units.text = builtins.toJSON {env.MAX_THINKING_TOKENS = null;};
        }
      ];
    });
  # §8's retirement sketch, with one correction: a `dir` target MUST have the
  # prune entry, because a retirement's whole job is deleting a real file
  # before checkLinkTargets so link generation can take the path over. §8
  # gives this sketch `entryNames.write` alone, which would place the deletion
  # AFTER linkGeneration — the exact abort the two-phase split exists to
  # avoid. The existing name keeps its prune position; the write entry is what
  # unlinks the ledger.
  steeringRetirement = own (base
    // {
      backend = "hm";
      entryNames = {
        prune = "retire-materialize-kiro-steering";
        write = "retire-materialize-kiro-steering-ledger";
      };
      targets = [
        {
          codec = "dir";
          ledger = "materialize/kiro-steering.manifest";
          path = ".kiro/steering";
          units = {};
        }
      ];
    });
  devenvHooks = hasFiles:
    own (base
      // {
        inherit hasFiles;
        backend = "devenv";
        entryNames.write = "ai:kiro:materialize-hooks";
        targets = [
          {
            codec = "dir";
            ledger = "materialize/kiro-hooks.manifest";
            path = ".kiro/hooks";
            units."hook.json".text = "{}";
          }
        ];
      });

  accepted = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  rejected = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  bodies = result: map (entry: entry.text) (lib.attrValues result.config.home.activation);
  # `exit` would truncate the whole concatenated activation script, so match
  # the WORD: `inherit_errexit` carries the substring and must not trip this.
  usesExit = line: builtins.match "(.*[^_[:alnum:]])?exit([^_[:alnum:]].*)?" line != null;
  strict = body:
    lib.hasInfix "set -euETo pipefail" body
    && lib.hasInfix "shopt -s inherit_errexit 2>/dev/null || :" body
    && !lib.any usesExit (lib.splitString "\n" body);

  # Every rejection below is also a runtime rejection in own.py; this is the
  # half that fails before a single byte is written.
  refusals = {
    absoluteLedger.targets = [
      {
        codec = "json";
        ledger = "/var/lib/x.json";
        path = "settings.json";
        units.text = "{}";
      }
    ];
    absolutePath.targets = [
      {
        codec = "dir";
        ledger = "materialize/x.manifest";
        path = "/etc";
        units."unit.txt".text = "x";
      }
    ];
    # A ledger name is a RELATIVE PATH, not a path segment: the retired
    # `stateName` charset rule policed a single filename, and `own` takes the
    # whole `<dir>/<name>` the caller states. So `json-settings/x.json` is
    # legal and these three are not.
    emptyLedger.targets = [
      {
        codec = "json";
        ledger = "";
        path = "settings.json";
        units.text = "{}";
      }
    ];
    documentMode.targets = [
      {
        codec = "json";
        ledger = "json-settings/x.json";
        path = "settings.json";
        units = {
          mode = "0400";
          text = "{}";
        };
      }
    ];
    dotPrefixedAddress.targets = [
      {
        codec = "dir";
        ledger = "materialize/x.manifest";
        path = "settings";
        units.".hidden".text = "x";
      }
    ];
    duplicateLedger.targets = [
      {
        codec = "dir";
        ledger = "materialize/shared.manifest";
        path = "settings";
        units = {};
      }
      {
        codec = "json";
        ledger = "materialize/shared.manifest";
        path = "settings/cli.json";
        units = {};
      }
    ];
    missingPruneName = {
      entryNames.write = "only-a-write";
      targets = [
        {
          codec = "dir";
          ledger = "materialize/x.manifest";
          path = "settings";
          units."unit.txt".text = "x";
        }
      ];
    };
    traversingAddress.targets = [
      {
        codec = "dir";
        ledger = "materialize/x.manifest";
        path = "settings";
        units."../escape".text = "x";
      }
    ];
    traversingLedger.targets = [
      {
        codec = "dir";
        ledger = "../escape.manifest";
        path = "settings";
        units = {};
      }
    ];
    twoContentTags.targets = [
      {
        codec = "dir";
        ledger = "materialize/x.manifest";
        path = "settings";
        units."unit.txt" = {
          run = "printf x";
          text = "x";
        };
      }
    ];
    unknownBackend = {
      backend = "nixos";
      targets = [
        {
          codec = "json";
          ledger = "json-settings/x.json";
          path = "settings.json";
          units.text = "{}";
        }
      ];
    };
    unknownCodec.targets = [
      {
        codec = "yaml";
        ledger = "json-settings/x.json";
        path = "settings.yaml";
        units.text = "{}";
      }
    ];
    unknownTargetField.targets = [
      {
        codec = "dir";
        ledger = "materialize/x.manifest";
        path = "settings";
        stateSlug = "gone";
        units = {};
      }
    ];
  };
  refuse = overrides:
    own (base
      // {
        backend = "hm";
        entryNames = {
          prune = "fixture-prune";
          write = "fixture-write";
        };
      }
      // overrides);

  passed = assert lib.assertMsg (accepted kiroMcp && accepted claudeUnpin && accepted steeringRetirement)
  "ai.own: a design §8 call shape was rejected";
  assert lib.assertMsg (accepted (devenvHooks false) && accepted (devenvHooks true))
  "ai.own: the devenv call shape was rejected";
  assert lib.assertMsg (
    builtins.attrNames kiroMcp.config.home.activation
    == ["kiroMcpJson" "materialize-kiro-settings-prune"]
    && builtins.attrNames steeringRetirement.config.home.activation
    == ["retire-materialize-kiro-steering" "retire-materialize-kiro-steering-ledger"]
  ) "ai.own: a bundle with a dir target must emit both the prune and the write entry";
  assert lib.assertMsg (builtins.attrNames claudeUnpin.config.home.activation == ["claudeUnpinLaunchEffort"])
  "ai.own: a document-only bundle must emit the write entry alone";
  assert lib.assertMsg (
    kiroMcp.config.home.activation.kiroMcpJson.after
    == ["linkGeneration" "sops-nix"]
    && kiroMcp.config.home.activation.materialize-kiro-settings-prune.before == ["checkLinkTargets"]
    && claudeUnpin.config.home.activation.claudeUnpinLaunchEffort.after == ["linkGeneration"]
  ) "ai.own: an activation entry lost its DAG position";
  assert lib.assertMsg (
    lib.hasInfix "--phase all" kiroMcp.config.home.activation.kiroMcpJson.text
    && lib.hasInfix "--phase prune" kiroMcp.config.home.activation.materialize-kiro-settings-prune.text
    && lib.hasInfix "--phase all" claudeUnpin.config.home.activation.claudeUnpinLaunchEffort.text
  ) "ai.own: an activation entry runs the wrong phase";
  assert lib.assertMsg (lib.all strict (
    bodies kiroMcp
    ++ bodies claudeUnpin
    ++ bodies steeringRetirement
    ++ [(devenvHooks false).config.tasks."ai:kiro:materialize-hooks".exec]
  ))
  "ai.own: an activation body is not strict, or contains `exit`";
  assert lib.assertMsg (
    lib.hasInfix "NAT_OWN_ROOT=\"$HOME\"" kiroMcp.config.home.activation.kiroMcpJson.text
    && lib.hasInfix "NAT_OWN_ROOT=\"$DEVENV_ROOT\"" (devenvHooks false).config.tasks."ai:kiro:materialize-hooks".exec
  ) "ai.own: a backend root export is wrong";
  assert lib.assertMsg (
    (devenvHooks false).config.tasks."ai:kiro:materialize-hooks".after
    == ["devenv:files:cleanup"]
    && (devenvHooks false).config.tasks."ai:kiro:materialize-hooks".before == ["devenv:enterShell"]
    && (devenvHooks true).config.tasks."ai:kiro:materialize-hooks".before == ["devenv:enterShell" "devenv:files"]
  ) "ai.own: the devenv task edges are wrong, or the devenv:files edge stopped being conditional";
  assert lib.assertMsg (lib.hasInfix "--verify" (devenvHooks false).config.enterTest)
  "ai.own: the devenv bundle lost its enterTest verification";
  # The plan is DATA in the result, not only bytes in the store. Module-eval
  # checks read a render command and a unit mode out of it, so an `own` that
  # stopped exposing the value it serializes takes every one of them with it.
  assert lib.assertMsg (
    lib.hasPrefix "/nix/store/" kiroMcp.plan.bash
    && map (target: target.ledger) kiroMcp.plan.targets
    == ["materialize/kiro-settings.manifest" "json-settings/kiro-mcp-fixture.json"]
    && (builtins.head kiroMcp.plan.targets).units."mcp.json"
    == {
      mode = "0400";
      run = "printf '{}'";
    }
    && (builtins.head steeringRetirement.plan.targets).units == {}
  ) "ai.own: the plan is no longer eval-visible data";
  assert lib.assertMsg (lib.all (name: rejected (refuse refusals.${name})) (builtins.attrNames refusals))
  "ai.own: a malformed bundle was accepted: ${lib.concatStringsSep ", " (lib.filter (name: accepted (refuse refusals.${name})) (builtins.attrNames refusals))}"; true;
in {
  checks.ai-own-eval = assert passed;
    pkgs.runCommandLocal "ai-own-eval-check" {} ''
      echo 'PASS: ai.own accepted 5 call shapes and refused ${toString (builtins.length (builtins.attrNames refusals))} malformed bundles' > "$out"
    '';
}
