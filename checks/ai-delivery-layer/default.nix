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
  inherit (harness) evalDevenv evalHm harnessNames mkTest;
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
      instructions = "probe";
    };
    context.text = "SNAPSHOT-CONTEXT";
    environmentVariables.PROBE = "value";
    hooks.PreToolUse = [{hooks = [{command = "true";}];}];
    lspServers.probe.command = "probe";
    mcpServers.probe.command = "probe";
    rules.probe.text = "SNAPSHOT-RULE";
    settings.reasoningEffort = "high";
    skills.probe = ./fixtures/probe-skill;
  };
  snapshotConfig = runtimes: {
    ai = pools // lib.genAttrs runtimes (_runtime: {enable = true;});
  };
  renderEntry = label: value: "${label} ${builtins.toJSON value}\n";
  renderSink = backend: evaluated: let
    inherit (evaluated) config;
  in
    if backend == "hm"
    then
      lib.concatStrings (lib.mapAttrsToList (path: entry: renderEntry "home.file ${builtins.toJSON path}" entry) config.home.file)
      + lib.concatStrings (lib.mapAttrsToList (name: entry: renderEntry "home.activation ${builtins.toJSON name}" entry) config.home.activation)
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

        # An assignment to one of the four native sinks, at the start of a
        # line. `files` and `tasks` are matched bare because that is how a
        # devenv fragment writes them.
        anchored='^[[:space:]]*(home\.file|home\.activation|files|tasks)([."[]|[[:space:]]*=)'
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
