# Synthetic catalog contracts catch lost owner merges, weak typing and policy leaking into core.
{
  lib,
  pkgs,
  ...
}: let
  # Evaluate only core, so owner imports cannot be needed for catalog definitions.
  evaluate = modules: (lib.evalModules {modules = [../modules/catalog.nix] ++ modules;}).config.ai.catalog;
  # Compare list-valued facts as sets, never module declaration order.
  sorted = values: lib.sort builtins.lessThan (lib.unique values);
  # Two owners deliberately disagree on evidence text, not identity.
  owner = evidence: alias: {
    ai.catalog = {
      models.shared = {
        aliases.vendor = lib.mkDefault [alias];
        maker = lib.mkDefault "maker";
        source = lib.mkDefault [evidence];
      };
      vendors.vendor.models = lib.mkDefault ["shared"];
    };
  };
  # This is the ordinary cross-owner merge with no registry or precedence assignment.
  owners = [(owner "owner-a:evidence" "first") (owner "owner-b:different-evidence" "second")];
  # Force every field so malformed data cannot pass through laziness.
  refuses = modules: !(builtins.tryEval (builtins.deepSeq (evaluate modules) true)).success;
  # Default evidence and aliases concatenate rather than producing scalar conflicts.
  merged = evaluate owners;
  # Normal user definitions replace defaults and can add unknown-maker finite identities.
  overridden = evaluate (owners
    ++ [
      {
        ai.catalog = {
          models.extra.source = ["configured"];
          models.shared.maker = "replacement";
          vendors.vendor.models = ["extra"];
          vendors.wide.maker = "replacement";
        };
      }
    ]);
  # Invalid values cover each field and both ambiguous and absent vendor offer kinds.
  malformed = [
    {
      models.x = {
        maker = 1;
        source = ["fixture"];
      };
    }
    {
      models.x = {
        aliases.vendor = [1];
        source = ["fixture"];
      };
    }
    {models.x.source = "scalar";}
    {models.x.source = [];}
    {models.x.source = [""];}
    {vendors.x.models = [1];}
    {vendors.x.maker = 1;}
    {vendors.x = {};}
    {
      vendors.x = {
        maker = "maker";
        models = [];
      };
    }
  ];
  # These files are the complete core catalog; owner and resolver dependencies are forbidden.
  coreText = builtins.readFile ../lib/catalog/types.nix + builtins.readFile ../modules/catalog.nix;
  # Every case names the incorrect implementation it detects.
  cases = {
    "core imports an owner, extraction or resolver" = lib.all (word: !(lib.hasInfix word coreText)) ["chatgpt-codex" "claude-code" "cliproxyapi" "delegate-routing" "extracted/" "resolve.nix"];
    "default aliases or evidence replaced instead of merged" = sorted merged.models.shared.aliases.vendor == ["first" "second"] && sorted merged.models.shared.source == ["owner-a:evidence" "owner-b:different-evidence"];
    "default maker conflict hidden" = refuses (owners ++ [{ai.catalog.models.shared.maker = lib.mkDefault "contradiction";}]);
    "finite unknown maker rejected or ordinary overrides ignored" = overridden.models.extra.maker == null && overridden.models.shared.maker == "replacement" && overridden.vendors.vendor.models == ["extra"] && overridden.vendors.wide.maker == "replacement";
    "invalid fields or offer kinds accepted" = lib.all (catalog: refuses [{ai.catalog = catalog;}]) malformed;
    "non-static options accepted" = lib.all (name: refuses [{ai.catalog.${name} = {};}]) ["clientRoutes" "credentials" "pools" "resolved" "runtimeModels" "runtimes"];
    "offer kinds combined across definitions" = refuses [{ai.catalog.vendors.x.models = [];} {ai.catalog.vendors.x.maker = "maker";}];
    "vendor billing or Reader accepted" = lib.all (field:
      refuses [
        {
          ai.catalog.vendors.x = {
            models = [];
            ${field} = "unused";
          };
        }
      ]) ["billing" "reader"];
  };
  # Report each violated contract at evaluation, before the trivial check derivation.
  failures = builtins.attrNames (lib.filterAttrs (_: ok: !ok) cases);
in {
  # Evaluate synthetic contracts before producing the check result.
  checks.ai-module-catalog = assert lib.assertMsg (failures == []) "catalog: ${lib.concatStringsSep "; " failures}";
    pkgs.runCommandLocal "ai-module-catalog" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      echo 'PASS: static catalog merge, override and refusal contracts' > "$out"
    '';
}
