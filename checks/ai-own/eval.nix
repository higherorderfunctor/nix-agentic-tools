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
  # The fourth call shape: a document target that STATES the mode its file must
  # carry. kiro's merge target is the only one, because it is the only document
  # whose file a sibling target in the same bundle also writes — see
  # `mkMcpTargets`. The mode is optional everywhere else and absent everywhere
  # else, which `claudeUnpin` above is the control for.
  # A document may name its native writer's lock (Kimchi's trust.json).
  lockedDocument = own (base
    // {
      backend = "hm";
      entryNames.write = "kimchiProjectTrustMerge";
      targets = [
        {
          codec = "json";
          ledger = "json-settings/kimchi-trust-fixture.json";
          lock = ".config/kimchi/harness/trust.json.lock";
          path = ".config/kimchi/harness/trust.json";
          units.run = "printf '{}'";
        }
      ];
    });
  mergeMode = own (base
    // {
      backend = "hm";
      entryNames.write = "kiroMcpJsonMerge";
      targets = [
        {
          codec = "json";
          ledger = "json-settings/kiro-mcp-fixture.json";
          path = ".kiro/settings/mcp.json";
          units = {
            mode = "0600";
            run = "printf '{}'";
          };
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
    # A document MAY state a mode (see `mergeMode` above); it may not state a
    # malformed one. The dir codec's unit modes are policed by the same regex,
    # so keep both refusals or a typo reaches `int(mode, 8)` at activation.
    documentModeMalformed.targets = [
      {
        codec = "json";
        ledger = "json-settings/x.json";
        path = "settings.json";
        units = {
          mode = "rw-";
          text = "{}";
        };
      }
    ];
    # A native writer's lock guards one document's read-modify-write; a
    # directory publishes each unit atomically and has none to share.
    directoryLock.targets = [
      {
        codec = "dir";
        ledger = "materialize/x.manifest";
        lock = "settings.lock";
        path = "settings";
        units."unit.txt".text = "x";
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
    # Two LIVE targets on one path, which the ledger rule above does NOT catch:
    # distinct ledgers, one file. Each publishes over the other and the second
    # backs the first one's bytes up as an unmanaged hand edit, once per
    # generation. Two targets on one path where at most one is live is the
    # legal shape — that is the handover `kiroMcp` above is built from.
    duplicatePath.targets = [
      {
        codec = "json";
        ledger = "json-settings/first.json";
        path = "settings/cli.json";
        units.text = "{}";
      }
      {
        codec = "json";
        ledger = "json-settings/second.json";
        path = "settings/cli.json";
        units.text = "{}";
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
    traversingLock.targets = [
      {
        codec = "json";
        ledger = "json-settings/x.json";
        lock = "../outside.lock";
        path = "settings.json";
        units.text = "{}";
      }
    ];
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

  passed = assert lib.assertMsg (accepted kiroMcp && accepted claudeUnpin && accepted steeringRetirement && accepted mergeMode && accepted lockedDocument)
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
  # Every HM entry mutates, so every one must go through home-manager's `run`
  # helper or a dry run writes settings and ledgers for real. The devenv body
  # must not: devenv defines no `run`, so the task would fail on a missing
  # command.
  assert lib.assertMsg (
    lib.all (lib.hasInfix "\nrun /nix/store/") (bodies kiroMcp ++ bodies claudeUnpin ++ bodies steeringRetirement)
    && !lib.hasInfix "run /nix/store/" (devenvHooks false).config.tasks."ai:kiro:materialize-hooks".exec
  ) "ai.own: an HM activation entry bypasses `run`, so DRY_RUN would not stop it writing";
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
    # A document's declared mode is plan data too, and it is the only mode
    # own.py ever imposes on a file it did not create.
    && (builtins.head mergeMode.plan.targets).units.mode == "0600"
    && !((builtins.head claudeUnpin.plan.targets).units ? mode)
    # The native lock is plan data on the TARGET, where own.py reads it.
    && (builtins.head lockedDocument.plan.targets).lock == ".config/kimchi/harness/trust.json.lock"
  ) "ai.own: the plan is no longer eval-visible data";
  assert lib.assertMsg (lib.all (name: rejected (refuse refusals.${name})) (builtins.attrNames refusals))
  "ai.own: a malformed bundle was accepted: ${lib.concatStringsSep ", " (lib.filter (name: accepted (refuse refusals.${name})) (builtins.attrNames refusals))}"; true;
in {
  checks.ai-own-eval = assert passed;
    pkgs.runCommandLocal "ai-own-eval-check" {} ''
      echo 'PASS: ai.own accepted 7 call shapes and refused ${toString (builtins.length (builtins.attrNames refusals))} malformed bundles' > "$out"
    '';
}
