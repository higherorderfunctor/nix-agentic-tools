{
  lib,
  pkgs,
  ...
}: let
  fileLib = import ../lib/files/default.nix {inherit lib pkgs;};
  runtimeModule = import ../lib/runtime.nix;
  path = "settings.json";
  source = ./fixtures/a/b/c.md;
  # A fragment is one definition of a files map; `at` places it in an option.
  entry = field: value: lib.setAttrByPath ([path] ++ field) value;
  at = option: fragment: lib.setAttrByPath option fragment;
  direct = ["ai" "files"];
  runtime = ["ai" "sample" "files"];
  # A non-AI program module declares layer 2 directly beside every runtime.
  program = {
    config,
    lib,
    ...
  }: {
    options.programs.sample.enable = lib.mkEnableOption "sample program";
    config = lib.mkIf config.programs.sample.enable {
      ai.files."program.txt".content.text = "program";
    };
  };
  evaluate = runtimes: modules:
    (lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules =
        [../modules/common.nix program {programs.sample.enable = true;}]
        ++ lib.mapAttrsToList (name: args: runtimeModule ({inherit name;} // args)) runtimes
        ++ modules;
    }).config;
  sample = evaluate {sample.enabled = true;};
  plan = config:
    fileLib.normalize {
      backend = "hm";
      files = config.ai.files;
      namespace = "ai";
      owners = config.ai.filesOwners;
    };
  selected = config: lib.findFirst (item: item.path == path) null (plan config);
  # Compare only what a case states; `rendered` is a derivation of `value`.
  project = item:
    if item == null
    then null
    else {
      inherit (item) method;
      content = removeAttrs item.content ["rendered"];
    };
  # `low` and `high` are definitions at the priorities each case names. Every
  # case runs with layer 1 low and layer 2 high, and swapped; both must match
  # the same declarations made directly at layer 2.
  cases = [
    {
      name = "default source, ordinary text";
      low = [(entry ["content" "source"] (lib.mkDefault source))];
      high = [(entry ["content" "text"] "override")];
      expected.content.text = "override";
    }
    {
      name = "default text, ordinary source";
      low = [(entry ["content" "text"] (lib.mkDefault "fallback"))];
      high = [(entry ["content" "source"] source)];
      expected.content.source = source;
    }
    {
      name = "discarded source stays lazy";
      low = [(entry ["content" "source"] (lib.mkDefault (throw "discarded source was evaluated")))];
      high = [(entry ["content" "text"] "override")];
      expected.content.text = "override";
    }
    {
      name = "forced source";
      low = [(entry ["content" "text"] "fallback")];
      high = [(entry ["content" "source"] (lib.mkForce source))];
      expected.content.source = source;
    }
    {
      name = "enable";
      low = [(entry [] {content.text = "fallback";})];
      high = [(entry ["enable"] false)];
      expected = null;
    }
    {
      name = "method";
      low = [
        (entry [] {
          content.text = "content";
          method = lib.mkDefault "symlink";
        })
      ];
      high = [(entry ["method"] "ro")];
      expected = {
        content.text = "content";
        method = "ro";
      };
    }
    {
      name = "structured leaf";
      low = [
        (entry [] {
          content.value = {
            owned = lib.mkDefault 1;
            sibling = 3;
          };
          format = "json";
          method = "rw";
        })
      ];
      high = [(entry ["content" "value" "owned"] 2)];
      expected = {
        content.value = {
          owned = 2;
          sibling = 3;
        };
        method = "rw";
      };
    }
    {
      name = "whole-entry default";
      low = [
        (entry [] (lib.mkDefault {
          content.text = "fallback";
          method = "ro";
        }))
      ];
      high = [(entry ["content" "text"] "override")];
      expected = {
        content.text = "override";
        method = "symlink";
      };
    }
    {
      name = "option-wide default";
      low = [
        (lib.mkDefault {
          ${path}.content.text = "fallback";
          "other.txt".content.text = "dropped";
        })
      ];
      high = [(entry ["content" "text"] "override")];
      expected = {
        content.text = "override";
        method = "symlink";
      };
    }
  ];
  checkCase = row: let
    reference = plan (sample (map (at direct) (row.low ++ row.high)));
    run = label: forwarded: let
      config = sample forwarded;
    in
      lib.optional (builtins.toJSON (plan config) != builtins.toJSON reference) "${row.name} (${label}): plan differs from layer 2"
      ++ lib.optional (project (selected config) != expected) "${row.name} (${label}): winner";
    expected =
      if row.expected == null
      then null
      else {method = "symlink";} // row.expected;
  in
    run "runtime low" (map (at runtime) row.low ++ map (at direct) row.high)
    ++ run "runtime high" (map (at direct) row.low ++ map (at runtime) row.high);
  # A disabled runtime contributes nothing, not even an evaluated source.
  disabled = evaluate {sample.enabled = false;} [(at runtime (entry ["content" "source"] (throw "disabled source was evaluated")))];
  twoRuntimes = beta:
    evaluate {
      alpha.enabled = true;
      beta.enabled = beta;
    } [
      {ai.alpha.files.${path}.content.text = "same";}
      {ai.beta.files.${path}.content.text = "same";}
    ];
  collision = twoRuntimes true;
  gated = twoRuntimes false;
  collisionIssue = ''files."${path}": runtime owners alpha and beta claim one destination'';
  # Commands and old ledgers forward in either owner state; a command's
  # `enable` follows the owner unless its producer sets it. `wrap` repeats the
  # commands under an option-wide default, which must not drop them.
  ledger = {
    codec = "dir";
    ledger = "materialize/sample.manifest";
    path = ".";
  };
  owner = enabled: wrap:
    evaluate {sample = {inherit enabled;};} [
      {
        ai.sample = {
          activation = wrap {
            forced = {
              command = "forced";
              enable = true;
            };
            plain.command = "plain";
            release = {
              command = "release";
              runWhenDisabled = true;
            };
          };
          files.${path}.content.text = "owned";
          legacyLedgers = [ledger];
        };
      }
    ];
  commands = config: lib.mapAttrs (_: entry: {inherit (entry) command enable runWhenDisabled;}) config.ai.activation;
  expectedCommands = enabled:
    lib.genAttrs ["forced" "plain" "release"] (key: {
      command = key;
      enable = key == "forced" || enabled;
      runWhenDisabled = key == "release";
    });
  ownerCase = {
    enabled,
    wrap,
  }: let
    config = owner enabled wrap;
    state =
      (
        if enabled
        then "enabled owner"
        else "disabled owner"
      )
      + lib.optionalString (wrap {} != {}) " under an option-wide default";
  in
    lib.optional (commands config != expectedCommands enabled) "${state}: commands"
    ++ lib.optional (config.ai.legacyLedgers != [ledger]) "${state}: ledgers"
    ++ lib.optional ((config.ai.files ? ${path}) != enabled) "${state}: files";
  # A shared key forwards with its priorities but only the composer claims it.
  sharedKey = "AGENTS.md";
  composed =
    evaluate {
      alpha = {
        enabled = true;
        shared = [sharedKey];
      };
      internal.enabled = true;
    } [
      {ai.internal.files.${sharedKey}.content.text = lib.mkDefault "composed";}
      {
        ai.alpha.files = {
          ${path}.content.text = "alpha";
          ${sharedKey}.content.text = "replaced";
        };
      }
    ];
  sharedEntry = lib.findFirst (item: item.path == sharedKey) null (plan composed);
  failures =
    lib.concatMap checkCase cases
    ++ lib.optional (map (item: item.path) (plan disabled) != ["program.txt"] || disabled.ai.filesOwners != {}) "disabled runtime"
    ++ lib.optional (gated.ai.filesOwners != {${path} = ["alpha"];} || (selected gated).content != {text = "same";}) "disabled runtime owner"
    ++ lib.optional (fileLib.validateOwners collision.ai.filesOwners != collisionIssue || (builtins.tryEval (builtins.deepSeq (plan collision) true)).success) "runtime collision"
    ++ lib.concatMap ownerCase (lib.cartesianProduct {
      enabled = [false true];
      wrap = [lib.id lib.mkDefault];
    })
    ++ lib.optional (
      composed.ai.filesOwners
      != {
        ${path} = ["alpha"];
        ${sharedKey} = ["internal"];
      }
      || sharedEntry.content.text or null != "replaced"
    ) "unclaimed shared key";
in {
  checks.ai-module-runtime-forward = assert lib.assertMsg (failures == []) "runtime forwarding: ${lib.concatStringsSep ", " failures}";
    pkgs.runCommandLocal "ai-module-runtime-forward" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      printf 'PASS: runtime forwarding, priorities, gating, owners, commands, ledgers, shared keys\n' > "$out"
    '';
}
