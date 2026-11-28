# Synthetic catalog contracts catch lost owner merges, weak typing and policy leaking into core.
{
  harness,
  lib,
  ...
}: let
  inherit (harness) checkRows mkTest rejectsChange;
  # Evaluate only core, so owner imports cannot be needed for catalog definitions.
  evaluate = modules: (lib.evalModules {modules = [../modules/catalog.nix] ++ modules;}).config.ai.catalog;
  # Compare list-valued facts as sets, never module declaration order.
  sorted = values: lib.sort builtins.lessThan (lib.unique values);
  # Two owners deliberately disagree on evidence text, not identity.
  owner = evidence: {
    ai.catalog = {
      models.shared = {
        maker = lib.mkDefault "maker";
        source = lib.mkDefault [evidence];
      };
      vendors.vendor.models = lib.mkDefault ["shared"];
    };
  };
  # This is the ordinary cross-owner merge with no registry or precedence assignment.
  owners = [(owner "owner-a:evidence") (owner "owner-b:different-evidence")];
  # Default evidence lists concatenate rather than producing scalar conflicts.
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
  # Read only the option bearing the restriction. For unknown fields, read
  # the containing submodule so its option-name check is forced as well.
  rejectsField = path: valid: invalid:
    rejectsChange (value: lib.attrByPath path null (evaluate [{ai.catalog = lib.setAttrByPath path value;}])) {
      inherit invalid valid;
      expected = valid;
    };
  source = ["fixture"];
  finiteOffer = {models = [];};
  model = {inherit source;};
  modelField = rejectsChange (value: (evaluate [{ai.catalog.models.x = value;}]).models.x) {
    valid = model;
    invalid = model // {aliases.vendor = ["forbidden"];};
    expected = {
      inherit source;
      maker = null;
    };
  };
  evidence = rejectsField ["models" "x" "source"] source;
  vendorField = field:
    rejectsChange (value: (evaluate [{ai.catalog.vendors.x = value;}]).vendors.x) {
      valid = finiteOffer;
      invalid = finiteOffer // {${field} = "unused";};
      expected = finiteOffer // {maker = null;};
    };
  vendorKind = rejectsChange (modules: (evaluate modules).vendors.x.models);
  finite = {ai.catalog.vendors.x.models = [];};
  wide = {ai.catalog.vendors.x.maker = "maker";};
  # These files are the complete core catalog; owner and resolver dependencies are forbidden.
  coreText = builtins.readFile ../lib/catalog/types.nix + builtins.readFile ../modules/catalog.nix;
  # Every case names the incorrect implementation it detects.
  cases = {
    "core imports an owner, extraction or resolver" = lib.all (word: !(lib.hasInfix word coreText)) ["chatgpt-codex" "claude-code" "cliproxyapi" "delegate-routing" "extracted/" "resolve.nix"];
    "default evidence replaced instead of merged" = sorted merged.models.shared.source == ["owner-a:evidence" "owner-b:different-evidence"];
    "default maker conflict hidden" = rejectsChange (modules: (evaluate modules).models.shared.maker) {
      valid = owners;
      invalid = owners ++ [{ai.catalog.models.shared.maker = lib.mkDefault "contradiction";}];
      expected = "maker";
    };
    "empty evidence entry accepted" = evidence [""];
    "empty evidence list accepted" = evidence [];
    "finite unknown maker rejected or ordinary overrides ignored" = overridden.models.extra.maker == null && overridden.models.shared.maker == "replacement" && overridden.vendors.vendor.models == ["extra"] && overridden.vendors.wide.maker == "replacement";
    "model aliases accepted" = modelField;
    "non-string model maker accepted" = rejectsChange (value: (evaluate [{ai.catalog.models.x = model // {maker = value;};}]).models.x.maker) {
      valid = "maker";
      invalid = 1;
      expected = "maker";
    };
    "non-string vendor maker accepted" = rejectsField ["vendors" "x" "maker"] "maker" 1;
    "non-string vendor model accepted" = rejectsField ["vendors" "x" "models"] ["x"] [1];
    "offer kinds combined across definitions" = vendorKind {
      valid = [finite];
      invalid = [finite wide];
      expected = [];
    };
    "offer without a kind accepted" = vendorKind {
      valid = [finite];
      invalid = [{ai.catalog.vendors.x = {};}];
      expected = [];
    };
    "scalar evidence accepted" = evidence "scalar";
    "vendor billing accepted" = vendorField "billing";
    "vendor reader accepted" = vendorField "reader";
  };
  nonStatic = lib.genAttrs ["clientRoutes" "credentials" "pools" "resolved" "runtimeModels" "runtimes"] (name:
    rejectsChange (catalog: evaluate [{ai.catalog = catalog;}]) {
      valid = {};
      invalid = {${name} = {};};
      expected = {
        models = {};
        vendors = {};
      };
    });
in {
  checks.ai-module-catalog = mkTest "ai-module-catalog" (
    checkRows "catalog" (cases // lib.mapAttrs' (name: lib.nameValuePair "non-static option ${name} accepted") nonStatic)
  );
}
