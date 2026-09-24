# The delivery layer's own module contracts: what `ai.<runtime>.activation`
# lowers to on each backend, and what the adapters do with it.
#
# The gate next door proves that a writer the POLICY names survives a populated
# and an emptied declaration. This proves the layer underneath it: that a
# writer declared once reaches both backends with the ordering it asked for,
# that a token without a node on this backend is dropped instead of emitted as
# a name the runner would reject, and that the body is spliced in a shape that
# cannot leak shell options into the script it joins.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalHm harnessNames hasLiteral mkTest ownPlan;
  deliveryMethod = import ../../lib/ai/deliveryMethod.nix {inherit lib;};

  # A file that states no fact at all takes both defaults, which is the shape
  # the rule answers `symlink` for.
  plainFacts = {
    harnessWrites = false;
    symlinkReadable = true;
  };
  resolve = args: deliveryMethod.byRule ({facts = plainFacts;} // args);

  # ── The delivered-surface snapshot ──────────────────────────────────
  # Everything the delivery layer puts on disk, rendered as sorted text. It is
  # not an assertion: it is the EVIDENCE that a refactor of the layer changed
  # nothing. Build it before and after the change and diff the two outputs —
  # `nix build .#checks.x86_64-linux.ai-delivery-snapshot --print-out-paths`.
  # A committed golden would be a merge conflict on every content change and
  # would say nothing the diff does not.
  #
  # One eval per runtime attributes a change to its runtime; the combined one
  # covers the cross-runtime AGENTS.md arbitration, which only happens when
  # two AGENTS.md-standard runtimes are enabled together.
  pools = {
    agents.probe = {
      description = "probe";
      instructions.text = "probe";
    };
    context.text = "SNAPSHOT-CONTEXT";
    environmentVariables.PROBE = "value";
    hooks.PreToolUse = [{hooks = [{command = "true";}];}];
    lspServers.probe.command = "probe";
    mcpServers.probe.command = "probe";
    rules.probe.text = "SNAPSHOT-RULE";
    settings.reasoningEffort = "high";
    skills.probe = ./fixtures/probe-skill;
    # A skill that comes from a PACKAGE: an interpolated string holding a
    # store path, and a single file rather than a tree. Both properties are
    # the branch the snapshot missed while `mkSkillFiles` routed it to
    # `content.text`.
    skills.probe-file = "${./fixtures/probe-skill}/SKILL.md";
  };
  # Each runtime's native-file options, set to a value no default can produce.
  # The pools above never reach them, so without this a reader left on a
  # renamed option path would still evaluate — to the default `{}` — and the
  # snapshot would show no change while a consumer's native settings were
  # dropped. With it, a lost reader shows in the before/after diff: either
  # `SNAPSHOT-NATIVE` leaves an inline entry, or the store path of a file that
  # embeds it (a TOML config, an activation's ownership plan) changes. Kiro's
  # `chat.defaultModel` is in the pinned workspace allowlist, so devenv writes
  # it too.
  native = {
    claude.native.settings.model = "SNAPSHOT-NATIVE";
    codex.native.settings.model = "SNAPSHOT-NATIVE";
    copilot.native.settings.model = "SNAPSHOT-NATIVE";
    kimchi = {
      native.harnessSettings.resources.SNAPSHOT-NATIVE = true;
      native.settings.llmEndpoint = "SNAPSHOT-NATIVE";
    };
    kiro.native.settings.chat.defaultModel = "SNAPSHOT-NATIVE";
  };
  snapshotConfig = runtimes: {
    ai = pools // lib.genAttrs runtimes (runtime: {enable = true;} // native.${runtime});
  };
  renderEntry = label: value: "${label} ${builtins.toJSON value}\n";
  renderSink = backend: evaluated: let
    inherit (evaluated) config;
  in
    if backend == "hm"
    then
      lib.concatStrings (lib.mapAttrsToList (path: entry: renderEntry "home.file ${builtins.toJSON path}" entry) config.home.file)
      + lib.concatStrings (lib.mapAttrsToList (name: entry: renderEntry "home.activation ${builtins.toJSON name}" entry) config.home.activation)
      # Claude's HM settings.json is written by upstream's programs.claude-code
      # module, so the factory's delivery ends at this option, not home.file.
      + lib.optionalString (config.programs.claude-code ? settings) (renderEntry "programs.claude-code.settings" config.programs.claude-code.settings)
    else
      lib.concatStrings (lib.mapAttrsToList (path: entry: renderEntry "files ${builtins.toJSON path}" entry) config.files)
      + lib.concatStrings (lib.mapAttrsToList (name: task: renderEntry "tasks ${builtins.toJSON name}" task) config.tasks)
      + renderEntry "enterTest" config.enterTest;
  snapshotSection = backend: label: runtimes:
    "== ${backend} ${label} ==\n"
    + renderSink backend ((
      if backend == "hm"
      then evalHm
      else evalDevenv
    ) (snapshotConfig runtimes));
  snapshot = lib.concatStrings (lib.concatMap (backend:
    map (runtime: snapshotSection backend runtime [runtime]) harnessNames
    ++ [(snapshotSection backend "<all>" harnessNames)])
  ["devenv" "hm"]);

  # The factories that still write a native sink themselves, with the step of
  # the migration that takes each one off the list. This is keyed by PATH and
  # not by a count: the anchored patterns below see 33 of today's 36 sites, and
  # the other three live inside codex's nested `home = {` block, which the
  # second pattern flags as a whole rather than line by line.
  #
  # An entry is removed when its factory stops writing sinks directly, and the
  # check fails in BOTH directions — a new writer anywhere under
  # `packages/*/lib/` fails it, and so does an entry the scan can no longer
  # reproduce. The list is empty when the migration is done, and then this
  # check is what keeps it empty.
  #
  # What the scan CANNOT see is a bundle a helper returns —
  # `lib.mkMerge [(helpers.mkOwnedDocument …)]` writes `home.activation`,
  # `tasks` and `enterTest` from inside `lib/ai/own.nix`, and no anchored
  # pattern over the caller's text will ever match it. That is not a hole to
  # regex around: every factory that does it is on the list below for its
  # other writes, and the direct-`own` call is exactly what the router's
  # `copy-ro`/`shared` bucket replaces, one factory at a time. When a factory
  # leaves this list it has stopped calling `own` directly too, and
  # `ai.<runtime>._ownPlans` is where a check reads what its writers do.
  sinkWriters = {
    "packages/chatgpt-codex/lib/mkCodex.nix" = "skill/agent/execpolicy/hooks entries and the two skill-link migrators";
    "packages/claude-code/lib/mkClaude.nix" = "the devenv settings.json deep merges and the skill walker";
    "packages/copilot-cli/lib/mkCopilot.nix" = "lsp, mcp and settings documents, rules, agents and skills";
    "packages/kimchi/lib/mkKimchi.nix" = "config.json, harness settings and mcp.json, and skills";
    "packages/kiro-cli/lib/mkKiro.nix" = "permissions, lsp, cli.json, agents, the agents-dir walker and skills";
  };

  # One writer, both backends, every ordering feature: a backend-keyed entry
  # name, a token with no devenv node (`secrets`), the literal-node escape
  # hatch, and both ends of the position.
  migrator = runtime: {
    ai.${runtime} = {
      enable = true;
      activation.probeMigrate = {
        after = ["secrets"];
        afterNodes.hm = ["probeSecretProvider"];
        before = ["linkCheck" "shell"];
        command = "printf 'probe'";
        entry = {
          devenv = "ai:probe:migrate";
          hm = "probeMigrate";
        };
      };
    };
  };
  # `exit` would truncate the whole concatenated activation script, so match
  # the WORD: `inherit_errexit` carries the substring and must not trip this.
  usesExit = line: builtins.match "(.*[^_[:alnum:]])?exit([^_[:alnum:]].*)?" line != null;
  strict = body:
    lib.hasInfix "set -euETo pipefail" body
    && lib.hasInfix "shopt -s inherit_errexit 2>/dev/null || :" body
    && lib.hasPrefix "(" body
    && !lib.any usesExit (lib.splitString "\n" body);
in {
  checks = {
    module-delivery-command-writer-lowers-to-both-backends = mkTest "delivery-command-writer-lowers-to-both-backends" (
      let
        # Kiro declares no devenv files when bare-enabled, so the task's edge
        # list here is exactly what the writer asked for.
        hm = (evalHm (migrator "kiro")).config;
        devenv = (evalDevenv (migrator "kiro")).config;
        entry = hm.home.activation.probeMigrate;
        task = devenv.tasks."ai:probe:migrate";
      in
        # Home Manager gets both ends of the position, the abstract `secrets`
        # token resolved to its node, and the literal escape hatch appended
        # rather than substituted.
        entry.after
        == ["sops-nix" "probeSecretProvider"]
        && entry.before == ["checkLinkTargets"]
        && strict entry.text
        && lib.hasInfix "printf 'probe'" entry.text
        # devenv has no secret-provider node, so that token lowers to nothing
        # instead of a dangling task reference its runner would reject.
        && task.after == []
        && task.before == ["devenv:enterShell"]
        && strict task.exec
        && lib.hasInfix "printf 'probe'" task.exec
    );

    module-delivery-command-writer-default-edges = mkTest "delivery-command-writer-default-edges" (
      let
        config = {
          ai.claude = {
            enable = true;
            activation.probeDefaults.command = "printf 'probe'";
          };
        };
        hm = (evalHm config).config;
        devenv = (evalDevenv config).config;
      in
        # The default tokens are `after = ["files"]` and `before = ["shell"]`,
        # and the writer's own attribute name is its default entry name.
        # `shell` has no Home Manager node, so it lowers to nothing there.
        hm.home.activation.probeDefaults.after
        == ["linkGeneration"]
        && hm.home.activation.probeDefaults.before == []
        && devenv.tasks.probeDefaults.after == ["devenv:files:cleanup"]
        && lib.elem "devenv:enterShell" devenv.tasks.probeDefaults.before
    );

    # `tasks."devenv:files"` exists only when the project declares files, and
    # devenv's runner hard-errors on a dangling reference — so this edge is
    # conditional, and both arms of the condition are pinned.
    module-delivery-devenv-files-edge-is-conditional = mkTest "delivery-devenv-files-edge-is-conditional" (
      let
        # Kiro is the one runtime that declares no devenv files when it is
        # bare-enabled, so it is the only one that can show the edge ABSENT.
        base = {
          ai.kiro = {
            enable = true;
            activation.probeDefaults.command = "printf 'probe'";
          };
        };
        withFiles =
          (evalDevenv (lib.recursiveUpdate base {
            ai.kiro.files."probe.txt".content.text = "probe";
          })).config;
        withoutFiles = (evalDevenv base).config;
      in
        withFiles.tasks.probeDefaults.before
        == ["devenv:enterShell" "devenv:files"]
        && withoutFiles.files == {}
        && withoutFiles.tasks.probeDefaults.before == ["devenv:enterShell"]
    );

    module-delivery-method-rule = mkTest "delivery-method-rule" (
      # The rule is stated once and read by the router; these are its four
      # answers and the shape of the fact that produces each.
      resolve {backend = "hm";}
      == "symlink"
      && resolve {
        backend = "hm";
        facts = plainFacts // {harnessWrites = true;};
      }
      == "shared"
      && resolve {
        backend = "hm";
        facts = plainFacts // {symlinkReadable = false;};
      }
      == "copy-ro"
      # A harness-written file is `shared` whether or not it is also
      # symlink-readable: the first arm wins, because owning leaves inside a
      # file the CLI rewrites is the only way to keep both sides' edits.
      && resolve {
        backend = "hm";
        facts = {
          harnessWrites = true;
          symlinkReadable = false;
        };
      }
      == "shared"
      # A backend-keyed fact is the operator's own claude case: one
      # declaration, a store symlink under $HOME and a real file in the
      # project. A consumer module has no `backend` in scope, so stating the
      # FACT per backend is what lets it reach both without replacing the rule.
      && resolve {
        backend = "hm";
        facts =
          plainFacts
          // {
            symlinkReadable = {
              devenv = false;
              hm = true;
            };
          };
      }
      == "symlink"
      && resolve {
        backend = "devenv";
        facts =
          plainFacts
          // {
            symlinkReadable = {
              devenv = false;
              hm = true;
            };
          };
      }
      == "copy-ro"
      && lib.all (method: lib.elem method deliveryMethod.methods) [
        (resolve {backend = "hm";})
        (resolve {
          backend = "hm";
          facts = plainFacts // {harnessWrites = true;};
        })
        (resolve {
          backend = "hm";
          facts = plainFacts // {symlinkReadable = false;};
        })
      ]
    );

    module-delivery-method-for-delegates-to-the-rule = mkTest "delivery-method-for-delegates-to-the-rule" (
      let
        ask = evaluated: path:
          evaluated.config.ai.kiro.methodFor {
            backend = "hm";
            default = deliveryMethod.byRule;
            facts = plainFacts;
            inherit path;
          };
        standard = evalHm {ai.kiro.enable = true;};
        # Two definitions at ORDINARY priority are not a merge error:
        # `functionTo` merges the RESULTS, per call, through the enum. Two
        # that agree answer; two that disagree fail where the router calls
        # the function rather than where they were written.
        agreeing = evalHm {
          ai.kiro = lib.mkMerge [
            {enable = true;}
            {methodFor = _: "copy-ro";}
            {methodFor = _: "copy-ro";}
          ];
        };
        disagreeing = evalHm {
          ai.kiro = lib.mkMerge [
            {enable = true;}
            {methodFor = _: "copy-ro";}
            {methodFor = _: "shared";}
          ];
        };
        # The exotic case: replace the lambda, override ONE path, and hand
        # every other case back to the rule that was passed in.
        replaced = evalHm {
          ai.kiro = {
            enable = true;
            methodFor = lib.mkForce ({
              backend,
              default,
              facts,
              path,
            }:
              if lib.hasPrefix ".kiro/steering/" path
              then "copy-ro"
              else default {inherit backend facts path;});
          };
        };
      in
        ask standard ".kiro/steering/orientation.md"
        == "symlink"
        && ask replaced ".kiro/steering/orientation.md" == "copy-ro"
        && ask replaced ".kiro/settings/lsp.json" == "symlink"
        && ask agreeing ".kiro/settings/lsp.json" == "copy-ro"
        && !(builtins.tryEval (ask disagreeing ".kiro/settings/lsp.json")).success
    );

    ai-delivery-snapshot = pkgs.writeText "ai-delivery-snapshot" snapshot;

    # The point of moving the generators' priority onto `content`: a consumer
    # who changes HOW a generated file lands keeps WHAT is in it. One case per
    # generator family, because each one contributes its entry differently.
    module-delivery-sibling-definition-keeps-generated-content = mkTest "delivery-sibling-definition-keeps-generated-content" (
      let
        base = runtime: {
          ai =
            {
              context.text = "GENERATED-CONTEXT";
              rules.probe.text = "GENERATED-RULE";
            }
            // {${runtime}.enable = true;};
        };
        withSibling = {
          evaluate,
          path,
          runtime,
          sibling,
        }:
          (evaluate (lib.recursiveUpdate (base runtime) {
            ai.${runtime}.files.${path} = sibling;
          }))
          .config
          .ai
          .${
            runtime
          }
          .files
          .${
            path
          };
        # A pure consumer FACT: it changes the method the rule resolves, and
        # implies nothing about ownership.
        fact.facts.symlinkReadable = false;
        claudeContext = withSibling {
          evaluate = evalHm;
          path = ".claude/CLAUDE.md";
          runtime = "claude";
          sibling = fact;
        };
        claudeRule = withSibling {
          evaluate = evalHm;
          path = ".claude/rules/probe.md";
          runtime = "claude";
          # `mkForce` on a sibling is the same shape and must behave the same.
          sibling.method = lib.mkForce "copy-ro";
        };
        copilotRule = withSibling {
          evaluate = evalDevenv;
          path = ".github/instructions/probe.instructions.md";
          runtime = "copilot";
          sibling = fact;
        };
        kimchiContext = withSibling {
          evaluate = evalDevenv;
          path = ".config/kimchi/harness/AGENTS.md";
          runtime = "kimchi";
          sibling = fact;
        };
        kiroRule = withSibling {
          evaluate = evalHm;
          path = ".kiro/steering/probe.md";
          runtime = "kiro";
          sibling = fact;
        };
      in
        claudeContext.content.text
        == "GENERATED-CONTEXT"
        && claudeContext.facts.symlinkReadable == false
        && lib.hasInfix "GENERATED-RULE" claudeRule.content.text
        && claudeRule.method == "copy-ro"
        && lib.hasInfix "GENERATED-RULE" copilotRule.content.text
        && copilotRule.facts.symlinkReadable == false
        && kimchiContext.content.text == "GENERATED-CONTEXT"
        && kimchiContext.facts.symlinkReadable == false
        && lib.hasInfix "GENERATED-RULE" kiroRule.content.text
        && kiroRule.facts.symlinkReadable == false
    );

    # How a `value` document may be defaulted, and how it may NOT. Measured,
    # not reasoned: the two shapes that look equivalent to the whole-entry
    # `mkDefault` this layer replaced both lose every generated leaf as soon
    # as a consumer adds one of its own.
    module-delivery-value-content-merges-per-leaf = mkTest "delivery-value-content-merges-per-leaf" (
      let
        merged = generated:
          (evalHm {
            ai.kiro = lib.mkMerge [
              {enable = true;}
              {files.".kiro/probe.json" = {format = "json";} // generated;}
              {files.".kiro/probe.json".content.value.consumer = true;}
            ];
          })
          .config
          .ai
          .kiro
          .files
          .".kiro/probe.json"
          .content
          .value;
        both = {
          consumer = true;
          generated = true;
        };
      in
        # Ordinary priority and a per-LEAF default both merge leaf-wise.
        merged {content.value.generated = true;}
        == both
        && merged {content.value.generated = lib.mkDefault true;} == both
        # A default on the whole value, or on the whole content, is dropped
        # outright: `filterOverrides` keeps the priority-100 definition, and
        # every generated leaf leaves with the definition it discards.
        && merged {content.value = lib.mkDefault {generated = true;};} == {consumer = true;}
        && merged {content = lib.mkDefault {value.generated = true;};} == {consumer = true;}
    );

    # Structured content is rendered once, by the router, in whichever shape
    # the sink takes: literal bytes for json, a generated store path for toml
    # and yaml — reading one of those back at evaluation would be
    # import-from-derivation, which this repository does not do.
    module-delivery-renders-structured-content = mkTest "delivery-renders-structured-content" (
      let
        value.probe = {
          enabled = true;
          name = "probe";
        };
        entryFor = format:
          (evalHm {
            ai.kiro = {
              enable = true;
              files.".kiro/rendered" = {
                inherit format;
                content = {inherit value;};
              };
            };
          })
          .config
          .home
          .file
          .".kiro/rendered";
        json = entryFor "json";
        toml = entryFor "toml";
        withoutRenderer = builtins.tryEval (builtins.deepSeq (entryFor "markdown") true);
      in
        json.text
        == builtins.toJSON value
        && !(json ? source)
        && lib.hasPrefix builtins.storeDir (toString toml.source)
        && !(toml ? text)
        # A format with no renderer says so instead of delivering nothing.
        && !withoutRenderer.success
    );

    # A method the layer does not route yet must fail loudly. Dropping the file
    # is the one outcome that looks like success.
    module-delivery-unsupported-method-asserts = mkTest "delivery-unsupported-method-asserts" (
      let
        evaluated = evalHm {
          ai.kiro = {
            enable = true;
            files.".kiro/settings/probe.json" = {
              # The harness rewrites it, so the rule answers `shared`.
              content.text = "{}";
              facts.harnessWrites = true;
            };
          };
        };
        failed = lib.filter (assertion: !assertion.assertion) evaluated.config.assertions;
      in
        lib.length failed
        == 1
        && lib.hasInfix ''ai.kiro.files.".kiro/settings/probe.json"'' (lib.head failed).message
        && lib.hasInfix "`shared`" (lib.head failed).message
    );

    # One walk, two backends: Home Manager expands a directory source itself,
    # the router expands it for devenv, and the leaves are the same either way.
    module-delivery-recursive-entry-walks-for-devenv = mkTest "delivery-recursive-entry-walks-for-devenv" (
      let
        tree = {
          content.source = ./fixtures/probe-skill;
          # A tree of source files keeps its own modes; stating one here would
          # clear the executable bit on anything the tree ships.
          executable = null;
          recursive = true;
        };
        config = {
          ai.kiro = {
            enable = true;
            files.".kiro/tree" = tree;
          };
        };
        hm = (evalHm config).config;
        devenv = (evalDevenv config).config;
        notADirectory = builtins.tryEval (builtins.deepSeq
          (evalDevenv {
            ai.kiro = {
              enable = true;
              files.".kiro/leaf" =
                tree
                // {content.source = ./fixtures/probe-skill/SKILL.md;};
            };
          })
          .config
          .files
          true);
      in
        hm.home.file.".kiro/tree"
        == {
          recursive = true;
          source = ./fixtures/probe-skill;
        }
        && devenv.files.".kiro/tree/SKILL.md" == {source = ./fixtures/probe-skill/SKILL.md;}
        && devenv.files.".kiro/tree/references/nested.md"
        == {source = ./fixtures/probe-skill/references/nested.md;}
        && !(devenv.files ? ".kiro/tree")
        # `recursive` with a file source is a declaration error, not a file
        # whose leaves silently never appear.
        && !notADirectory.success
    );

    # The router builds the reconciler's input and never its behavior: one
    # bundle per writer, one TARGET per declared ledger — not per file that
    # exists this generation, which is what makes releasing a path ordinary.
    module-delivery-owned-methods-build-one-bundle-per-writer = mkTest "delivery-owned-methods-build-one-bundle-per-writer" (
      let
        config = {
          ai.kiro = {
            enable = true;
            activation.probeMaterialize = {
              entry = {
                devenv = "ai:probe:materialize";
                hm = "probeMaterialize";
              };
              ledgers = {
                # Claimed by the document below.
                "json-settings/probe-doc.json" = {
                  codec = "json";
                  path = ".kiro/probe-doc.json";
                };
                # Claimed by two files.
                "materialize/probe.manifest" = {
                  codec = "dir";
                  path = ".kiro/probe";
                };
                # Claimed by NOTHING this generation: a previous one owned it.
                "materialize/probe-retired.manifest" = {
                  codec = "dir";
                  path = ".kiro/probe-retired";
                };
              };
              pruneEntry.hm = "probeMaterializePrune";
            };
            files = {
              # The scanner keeps only regular files, so the rule answers
              # copy-ro and the writer above owns both.
              ".kiro/probe/alpha.json" = {
                content.text = "{}";
                entry = "probeMaterialize";
                facts.symlinkReadable = false;
                ledger = "materialize/probe.manifest";
                mode = "0400";
              };
              ".kiro/probe/beta.json" = {
                content.source = ./fixtures/probe-skill/SKILL.md;
                entry = "probeMaterialize";
                facts.symlinkReadable = false;
                ledger = "materialize/probe.manifest";
              };
              # The harness rewrites this one, so the rule answers shared and
              # the declaration travels as JSON whatever the container is.
              ".kiro/probe-doc.json" = {
                content.value.probe = true;
                entry = "probeMaterialize";
                facts.harnessWrites = true;
                format = "json";
                ledger = "json-settings/probe-doc.json";
              };
            };
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        plan = ownPlan "kiro" "probeMaterialize" hm;
        targetOf = ledger: lib.head (lib.filter (target: target.ledger == ledger) plan.targets);
        task = devenv.config.tasks."ai:probe:materialize";
      in
        lib.length plan.targets
        == 3
        && (targetOf "materialize/probe.manifest").units
        == {
          "alpha.json" = {
            mode = "0400";
            text = "{}";
          };
          "beta.json".store = ./fixtures/probe-skill/SKILL.md;
        }
        && (targetOf "json-settings/probe-doc.json").units
        == {text = builtins.toJSON {probe = true;};}
        # The release: a declared ledger nothing claims lowers to an EMPTY
        # target, which is what retracts whatever the last generation wrote.
        && (targetOf "materialize/probe-retired.manifest").units == {}
        && (targetOf "materialize/probe-retired.manifest").path == ".kiro/probe-retired"
        # The value the document declares cannot be read back out of the plan,
        # so it rides beside it.
        && hm.config.ai.kiro._ownPlans.probeMaterialize.declared.".kiro/probe-doc.json"
        == {probe = true;}
        # A directory target needs both phases on Home Manager: a real file has
        # to be gone before checkLinkTargets, and a new one may only appear
        # after linkGeneration.
        && hm.config.home.activation ? probeMaterialize
        && hm.config.home.activation ? probeMaterializePrune
        && devenv.config.tasks ? "ai:probe:materialize"
        && !(devenv.config.tasks ? probeMaterializePrune)
        # Every owned file is written by the writer, not linked beside it.
        && !(hm.config.home.file ? ".kiro/probe/alpha.json")
        && !(devenv.config.files ? ".kiro/probe-doc.json")
        # devenv's backstop verifies THIS plan at shell entry. The needle is a
        # regex to `hasLiteral`, and a regex may not carry string context, so
        # the plan path the task names is stripped of it before the search.
        && hasLiteral (builtins.unsafeDiscardStringContext (lib.head (
          lib.filter (argument: lib.hasPrefix builtins.storeDir argument)
          (lib.splitString " " task.exec)
        )))
        devenv.config.enterTest
    );

    # Every way an owned file can be described wrongly, said where the option
    # path is still known rather than as a reconciler error about a target.
    module-delivery-owned-file-descriptions-are-checked = mkTest "delivery-owned-file-descriptions-are-checked" (
      let
        base = {
          ai.kiro = {
            enable = true;
            activation.probeMaterialize.ledgers."materialize/probe.manifest" = {
              codec = "dir";
              path = ".kiro/probe";
            };
            activation.probeMaterialize.pruneEntry.hm = "probeMaterializePrune";
          };
        };
        owned = {
          content.text = "{}";
          entry = "probeMaterialize";
          facts.symlinkReadable = false;
          ledger = "materialize/probe.manifest";
        };
        document = {
          ai.kiro = {
            enable = true;
            activation.probeDocument.ledgers."json-settings/probe-doc.json" = {
              codec = "json";
              path = ".kiro/probe-doc.json";
            };
          };
        };
        claimsDocument = {
          entry = "probeDocument";
          facts.harnessWrites = true;
          format = "json";
          ledger = "json-settings/probe-doc.json";
        };
        failures = overlay: let
          evaluated = evalHm (lib.recursiveUpdate base overlay);
        in
          map (assertion: assertion.message)
          (lib.filter (assertion: !assertion.assertion) evaluated.config.assertions);
        documentFailures = overlay: let
          evaluated = evalHm (lib.recursiveUpdate document overlay);
        in
          map (assertion: assertion.message)
          (lib.filter (assertion: !assertion.assertion) evaluated.config.assertions);
        says = needle: messages: lib.any (message: lib.hasInfix needle message) messages;
        noWriter = failures {
          ai.kiro.files.".kiro/probe/alpha.json" = removeAttrs owned ["entry"];
        };
        unknownWriter = failures {
          ai.kiro.files.".kiro/probe/alpha.json" = owned // {entry = "probeAbsent";};
        };
        unknownLedger = failures {
          ai.kiro.files.".kiro/probe/alpha.json" = owned // {ledger = "materialize/absent.manifest";};
        };
        # NESTED, not elsewhere: the container is still a prefix of the path,
        # which is exactly what the old containment test accepted while the
        # unit landed one level up from where it was declared.
        outsideContainer = failures {
          ai.kiro.files.".kiro/probe/a/alpha.json" = owned;
        };
        duplicateUnit = failures {
          ai.kiro.files.".kiro/probe/a/alpha.json" = owned;
          ai.kiro.files.".kiro/probe/b/alpha.json" = owned;
        };
        sharedYaml = failures {
          ai.kiro.files.".kiro/probe/alpha.json" =
            owned
            // {
              facts.harnessWrites = true;
              format = "yaml";
            };
        };
        emptyWriter = failures {
          ai.kiro.activation.probeNothing = {};
        };
        commandAndLedgers = failures {
          ai.kiro.activation.probeMaterialize.command = "printf 'probe'";
        };
        ledgerWriterBefore = failures {
          ai.kiro.activation.probeMaterialize.before = ["linkCheck"];
        };
        recursiveFile = failures {
          ai.kiro.files.".kiro/tree" = {
            content.source = ./fixtures/probe-skill/SKILL.md;
            recursive = true;
          };
        };
        runWithoutOwner = failures {
          ai.kiro.files.".kiro/probe/written.json".content.run = "printf '{}' > \"$1\"";
        };
        documentText = documentFailures {
          ai.kiro.files.".kiro/probe-doc.json" = claimsDocument // {content.text = "{}";};
        };
        documentClaimedTwice = documentFailures {
          ai.kiro.files.".kiro/probe-doc.json" = claimsDocument // {content.value.probe = true;};
          ai.kiro.files.".kiro/probe-doc-too.json" = claimsDocument // {content.value.probe = false;};
        };
      in
        says "needs the writer that materializes it" noWriter
        && says "which ai.kiro.activation does not declare" unknownWriter
        && says "which does not declare it" unknownLedger
        && says "whose container is `.kiro/probe`" outsideContainer
        && says "at one unit address" duplicateUnit
        && says "alpha.json" duplicateUnit
        && says "names no container leaves can be owned in" sharedYaml
        && says "declares neither a `command` nor a" emptyWriter
        && says "declares both a `command` and" commandAndLedgers
        && says "so this value would be ignored" ledgerWriterBefore
        && says "delivers the\nleaves of a DIRECTORY" recursiveFile
        && says "has a write step" runWithoutOwner
        && says "literal bytes name no leaves to own" documentText
        && says "claiming it twice writes" documentClaimedTwice
        # The control: the same declaration, described correctly, asserts
        # nothing at all — on both shapes.
        && failures {ai.kiro.files.".kiro/probe/alpha.json" = owned;} == []
        && documentFailures {
          ai.kiro.files.".kiro/probe-doc.json" = claimsDocument // {content.value.probe = true;};
        }
        == []
    );

    # The two per-backend declarations that used to fail as a bare
    # `attribute 'devenv' missing`, naming neither the option nor the fix. Nix
    # gives no way to read a caught message back, so the messages themselves
    # are recorded in the commit; what is pinned here is that a HALF-stated
    # declaration fails at all, and that the complete one does not.
    module-delivery-partial-backend-declarations-fail = mkTest "delivery-partial-backend-declarations-fail" (
      let
        fact = value:
          builtins.tryEval (builtins.deepSeq
            (evalDevenv {
              ai.kiro = {
                enable = true;
                files.".kiro/probe.json" = {
                  content.text = "{}";
                  facts.symlinkReadable = value;
                };
              };
            })
            .config
            .files
            true);
        writer = {
          ai.kiro = {
            enable = true;
            activation.probeMigrate = {
              command = "printf 'probe'";
              entry.hm = "probeMigrate";
            };
          };
        };
      in
        # A fact keyed by backend states BOTH backends or neither: the rule
        # reads the key for the backend it is running on, and there is no
        # honest default for the other one.
        (fact {
          devenv = true;
          hm = true;
        })
        .success
        && !(fact {hm = true;}).success
        && (fact true).success
        # An entry name keyed by backend, on the backend it names.
        && (builtins.tryEval (builtins.deepSeq (evalHm writer).config.home.activation true)).success
        && !(builtins.tryEval (builtins.deepSeq (evalDevenv writer).config.tasks true)).success
    );

    # `upstream` hands the bytes to the option `sink` names and delivers no
    # file for them. The path stays in the delivery description — with its
    # facts, its enable gate and its override boundary — while another module
    # does the writing.
    module-delivery-upstream-lowers-to-its-sink = mkTest "delivery-upstream-lowers-to-its-sink" (
      let
        delegated = sink: {
          ai.kiro = {
            enable = true;
            files.".kiro/delegated.json" = {
              content.value.probe = true;
              format = "json";
              method = "upstream";
              inherit sink;
            };
          };
        };
        hm = (evalHm (delegated ["programs" "claude-code" "probeDelegated"])).config;
        devenv = (evalDevenv (delegated ["files" ".kiro/delegated.json" "json"])).config;
        # A sink is read by `upstream` and by nothing else, and an upstream
        # entry with no sink has nowhere to put its bytes.
        failures = overlay:
          map (assertion: assertion.message)
          (lib.filter (assertion: !assertion.assertion) (evalHm overlay).config.assertions);
        says = needle: messages: lib.any (message: lib.hasInfix needle message) messages;
      in
        # The VALUE reaches the option, not the rendered bytes: the sink owns
        # the rendering from here.
        hm.programs.claude-code.probeDelegated
        == {probe = true;}
        && !(hm.home.file ? ".kiro/delegated.json")
        # devenv's deep-merge sink: the same path, handed to devenv's own
        # JSON merge instead of written as a store symlink.
        && devenv.files.".kiro/delegated.json" == {json = {probe = true;};}
        && failures (delegated ["programs" "claude-code" "probeDelegated"]) == []
        && says "it needs the `sink`" (failures {
          ai.kiro = {
            enable = true;
            files.".kiro/delegated.json" = {
              content.text = "{}";
              method = "upstream";
            };
          };
        })
        && says "which only `method = \"upstream\"` reads" (failures {
          ai.kiro = {
            enable = true;
            files.".kiro/delegated.json" = {
              content.text = "{}";
              sink = ["programs" "claude-code" "probeDelegated"];
            };
          };
        })
    );

    # What the adapter puts in `tasks` is exactly the runtime's writers, and
    # nothing when it declares none. The other half of the claim — that the
    # DEFINITION is only made where the backend declares the option — is
    # proven by `lib/testing/factory-harness.nix`, which declares neither
    # `tasks` nor `enterTest` and used to need a stub for both.
    module-delivery-adapter-adds-only-its-writers = mkTest "delivery-adapter-adds-only-its-writers" (
      let
        bare = (evalDevenv {ai.copilot.enable = true;}).config;
        withWriter =
          (evalDevenv {
            ai.copilot = {
              enable = true;
              activation.probeWriter.command = "printf 'probe'";
            };
          })
          .config;
      in
        !(bare.tasks ? probeWriter)
        && withWriter.tasks ? probeWriter
        && lib.attrNames (removeAttrs withWriter.tasks (lib.attrNames bare.tasks)) == ["probeWriter"]
        # A command writer owns no files, so it contributes no verification.
        && withWriter.enterTest == bare.enterTest
    );

    # A corpus scan, not a changed-files scan: a gate that only looks at the
    # diff cannot notice that the tree behind it grew a new direct write.
    module-delivery-no-new-direct-sink-writes =
      pkgs.runCommandLocal "delivery-no-new-direct-sink-writes" {
        src = ../..;
        nativeBuildInputs = [pkgs.coreutils pkgs.diffutils pkgs.findutils pkgs.gnugrep];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        # The source is a read-only store path, so artifacts land in the build
        # directory while the scan itself runs with repo-relative paths.
        work="$PWD"
        cd "$src"

        # An assignment to one of the native sinks, at the start of a line.
        # `files`, `tasks` and `enterTest` are matched bare because that is how
        # a devenv fragment writes them. `enterTest` is here because a writer's
        # verification is as much a sink write as the writer itself: a factory
        # that emitted one directly would keep a second way, outside the router, to make
        # `devenv test` fail.
        anchored='^[[:space:]]*(home\.file|home\.activation|files|tasks|enterTest)([."[]|[[:space:]]*=)'
        # The nested form: a `home = {` block whose body writes `file` and
        # `activation` at a depth the anchored pattern cannot see. Flagging the
        # block is enough, because this list is keyed by file.
        nested='^[[:space:]]*home[[:space:]]*=[[:space:]]*\{'

        find packages -mindepth 3 -path 'packages/*/lib/*' -type f -name '*.nix' -print0 \
          | sort -z > "$work/corpus"
        # A scan of nothing exits 0 and is indistinguishable from a pass.
        test -s "$work/corpus"
        echo "scanned $(tr -d -c '\0' < "$work/corpus" | wc -c) factory library files"

        xargs -0 -r grep -lE -e "$anchored" -e "$nested" < "$work/corpus" | sort > "$work/actual" || true
        {
          ${lib.concatMapStringsSep "\n          " (path: "echo ${lib.escapeShellArg path}") (lib.attrNames sinkWriters)}
        } | sort > "$work/allowed"

        if ! diff -u "$work/allowed" "$work/actual" > "$work/sink-writers.diff"; then
          echo "delivery: the set of files writing a native sink directly has changed." >&2
          echo "A '+' line writes home.file/home.activation/files/tasks itself; route it" >&2
          echo "through ai.<runtime>.files or ai.<runtime>.activation instead. A '-' line" >&2
          echo "no longer does; drop it from sinkWriters in this check." >&2
          cat "$work/sink-writers.diff" >&2
          exit 1
        fi

        echo "PASS: ${toString (lib.length (lib.attrNames sinkWriters))} recorded factories write a native sink directly; no others do" > "$out"
      '';

    # A single-file skill whose source is a package-interpolated STRING. Both
    # backends must deliver the file's CONTENTS; routing it to `content.text`
    # writes the store PATH as the body of SKILL.md instead — the upstream
    # helper's bug, reached through the single-file branch. Modelled on
    # `module-kiro-path-agent-both-backends`, which pins the same property for
    # a path-valued agent.
    module-delivery-single-file-skill-is-a-source = mkTest "delivery-single-file-skill-is-a-source" (
      let
        source = "${./fixtures/probe-skill}/SKILL.md";
        config = {
          ai.kiro = {
            enable = true;
            skills.probe-file = source;
          };
        };
        path = ".kiro/skills/probe-file/SKILL.md";
        hm = (evalHm config).config.home.file.${path};
        devenv = (evalDevenv config).config.files.${path};
        delivers = entry: entry.source == source && !(entry ? text);
      in
        delivers hm && delivers devenv
    );

    module-delivery-writers-reach-every-runtime = mkTest "delivery-writers-reach-every-runtime" (
      lib.all (runtime: let
        hm = (evalHm (migrator runtime)).config;
        devenv = (evalDevenv (migrator runtime)).config;
        disabled = evalHm (lib.recursiveUpdate (migrator runtime) {
          ai.${runtime}.enable = false;
        });
      in
        hm.home.activation
        ? probeMigrate
        && devenv.tasks ? "ai:probe:migrate"
        # Delivery is inside the runtime's sole enable gate, exactly like the
        # file sink beside it.
        && !(disabled.config.home.activation ? probeMigrate))
      harnessNames
    );
  };
}
