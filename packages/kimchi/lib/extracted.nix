# Everything the Kimchi factory reads from its drift-checked sidecar,
# `packages/kimchi/extracted.json`.
#
# The sidecar is read as an ordinary committed file. Never read the package's
# `passthru.extracted` derivation here: that is import-from-derivation and
# poisons evaluation for every consumer. Freshness is the update job's and the
# `kimchi-extracted` drift check's problem, not evaluation's.
#
# Three surfaces, each consumed:
#
#   config       → `ai.kimchi.native.settings` (config.json), plus the keys a
#                  project config.json does not honor (devenv rejects them)
#   harness      → `ai.kimchi.native.harnessSettings` (harness/settings.json),
#                  plus the keys a project harness file does not honor
#   environment  → the variables Kimchi overwrites at launch (rejected), and a
#                  lookup that validates every variable the factory sets itself
#
# Option types are GENERATED from the sidecar's type tree. Adding a key
# upstream and re-extracting surfaces a new option; removing one makes a
# consumer that still sets it fail with an unknown-option error instead of
# writing a key nothing reads. Every submodule is closed for the same reason.
#
# Three small hand tables are this generator's only exceptions (the extractor
# keeps hand-written parts of its own; docs/kimchi-factory.md lists them and
# their guards), and each row must name a path the sidecar still has —
# `report.stale*` lists any that do not, and `checks/native-options.nix` fails
# on it:
#
#   exclusions   key → reason it has no native option
#   refinements  path → (node → type), runtime validation the type tree lacks
#   notes        path → prose appended to the generated description
{
  lib,
  pkgs,
  extracted,
}: let
  inherit (lib) types;
  json = (pkgs.formats.json {}).type;

  # Kimchi 1.1.30 reads each modelRoles value as a provider/model string, and
  # for delegable roles also a non-empty list of them. Anything else is
  # discarded with a warning at runtime
  # (src/extensions/orchestration/model-roles.ts:83-91, 117-122 and 144-181),
  # so evaluation rejects it instead. Which roles exist, and which take one
  # string only, both come from the sidecar.
  roleModelType = types.addCheck types.str (value: builtins.match "[[:space:]]*" value == null);
  roleModelsType = types.addCheck (types.listOf roleModelType) (values: values != []);

  surfaces = {
    settings = {
      schema = extracted.config;
      definitions = {};
    };
    harnessSettings = {
      schema = extracted.harness;
      definitions = extracted.harness.definitions or {};
    };
  };

  exclusions = {
    "settings.apiKey" = "a secret; set `ai.kimchi.apiKey`, which reads it from a file at launch instead of writing it into the Nix store";
  };

  refinements = {
    "harnessSettings.modelRoles" = node:
      types.submodule {
        options = lib.mapAttrs (role: roleNode: let
          single = roleNode.type == "string";
          many = roleNode.type == "union" && roleNode.typeExpression == "string | string[]";
        in
          lib.mkOption {
            type = types.nullOr (
              if single
              then roleModelType
              else if many
              then types.either roleModelType roleModelsType
              else throw "ai.kimchi.native.harnessSettings.modelRoles.${role}: packages/kimchi/extracted.json types it as `${roleNode.typeExpression}`, which the role refinement in packages/kimchi/lib/extracted.nix does not handle"
            );
            default = null;
            description =
              (roleNode.description or "Model for the ${role} role.")
              + (
                if single
                then " One provider/model string."
                else " A provider/model string, or a non-empty list of them."
              );
          })
        node.properties;
      };
  };

  notes = {
    "settings.skillPaths" = ''
      Null leaves the key out, so a project config inherits the user's list:
      Kimchi reads `project.skillPaths ?? global.skillPaths`, so an explicit
      list, empty included, replaces it.
    '';
  };

  # Keys with no native option at all: an alias spelling of another key (the
  # one hand annotation left on config keys), and an inert key. The extractor
  # marks a key inert only when upstream tags its KimchiConfig member
  # @deprecated and no Kimchi code consumes it; config.ts still parses it and
  # warns that it is obsolete. A release that consumes it again clears the
  # flag, and the key becomes an option.
  derivedExclusion = node:
    if node ? aliasFor
    then "an alias of `${node.aliasFor}`; set that key instead"
    else if node.inert or false
    then "deprecated upstream and consumed by nothing (Kimchi only warns that it is obsolete): ${node.deprecated}"
    else null;

  scalarTypes = {
    boolean = types.bool;
    inherit (types) number;
    string = types.str;
  };

  # node → { type; untyped = [path]; }
  walkType = definitions: path: node: let
    t = node.type or null;
    leaf = type: {
      inherit type;
      untyped = [];
    };
    fromProperties = properties: let
      children = lib.mapAttrs (name: walkOption definitions "${path}.${name}") properties;
    in {
      type = types.submodule {options = lib.mapAttrs (_: c: c.option) children;};
      untyped = lib.concatMap (c: c.untyped) (builtins.attrValues children);
    };
  in
    if refinements ? ${path}
    then leaf (refinements.${path} node)
    else if t == "enum"
    then leaf (types.enum node.enum)
    else if scalarTypes ? ${toString t}
    then leaf scalarTypes.${t}
    else if t == "array"
    then
      # Elements stay untyped unless they are scalars: aiCommon.filterNulls
      # does not recurse into lists, so a submodule element would write its
      # unset fields as JSON nulls.
      leaf (types.listOf (
        if node ? items && scalarTypes ? ${node.items.type or ""}
        then scalarTypes.${node.items.type}
        else if node ? items && node.items.type or null == "enum"
        then types.enum node.items.enum
        else if !(node ? items) && node.typeExpression or null == "string[]"
        then types.str
        else json
      ))
    else if t == "object" && node ? properties
    then fromProperties node.properties
    else if t == "object" && node ? additionalProperties
    then let
      value = walkType definitions "${path}.*" node.additionalProperties;
    in {
      type = types.attrsOf value.type;
      inherit (value) untyped;
    }
    else if t == "object" && definitions ? ${node.typeExpression or ""}
    then fromProperties definitions.${node.typeExpression}
    else if t == "object"
    then leaf json
    else {
      # A union or a type the extractor grows later. JSON is accepted, but
      # the path is reported so the check fails until someone types it.
      type = json;
      untyped = [path];
    };

  # path → node → { option; untyped; }
  walkOption = definitions: path: node: let
    walked = walkType definitions path node;
    optional = node.optional or false;
    name = lib.last (lib.splitString "." path);
    described = node.description or "Kimchi `${name}` (`${node.typeExpression or node.type}`).";
  in {
    inherit (walked) untyped;
    option = lib.mkOption ({
        type =
          if optional
          then types.nullOr walked.type
          else walked.type;
        description = lib.concatStringsSep " " (
          [described]
          ++ lib.optional (node ? source) "Read by ${node.source}."
          ++ lib.optional (node ? default) "Kimchi's default is `${builtins.toJSON node.default}`."
          ++ lib.optional (notes ? ${path}) notes.${path}
        );
      }
      # Never a non-null default: an unset key must stay out of the file.
      // lib.optionalAttrs optional {default = null;});
  };

  surfaceOf = name: surface: let
    keys = surface.schema.keys;
    excludedReason = key:
      exclusions."${name}.${key}" or (derivedExclusion keys.${key});
    kept = lib.filterAttrs (key: _: excludedReason key == null) keys;
    walked = lib.mapAttrs (key: walkOption surface.definitions "${name}.${key}") kept;
  in {
    options = lib.mapAttrs (_: w: w.option) walked;
    excluded = lib.mapAttrs (key: _: excludedReason key) (lib.filterAttrs (key: _: excludedReason key != null) keys);
    untyped = lib.concatMap (w: w.untyped) (builtins.attrValues walked);
  };

  generated = lib.mapAttrs surfaceOf surfaces;

  # A dotted path the sidecar has, at any depth reachable through properties.
  knownPath = path: let
    segments = lib.splitString "." path;
    surface = surfaces.${builtins.head segments} or null;
    step = node: segment:
      if node == null
      then null
      else node.properties.${segment} or (surface.definitions.${node.typeExpression or ""} or {}).${segment} or null;
  in
    surface
    != null
    && lib.foldl' step {properties = surface.schema.keys;} (builtins.tail segments) != null;

  stale = table: lib.sort (a: b: a < b) (lib.filter (path: !(knownPath path)) (builtins.attrNames table));

  variables = extracted.environment.variables;
  userScopeKeys = keys: builtins.attrNames (lib.filterAttrs (_: node: !(node.project or false)) keys);
in {
  settingsOptions = generated.settings.options;
  harnessSettingsOptions = generated.harnessSettings.options;

  # Keys a project file does not honor, so devenv rejects them rather than
  # writing bytes nothing reads. config.json: Kimchi merges only
  # `config.projectTier.honoredKeys` from `.kimchi/config.json`. Harness
  # settings.json: pi merges the project file only for keys it reads through
  # its merged settings, and Kimchi reads its own additions from the user file.
  userScopeConfigKeys = userScopeKeys extracted.config.keys;
  userScopeHarnessKeys = userScopeKeys extracted.harness.keys;

  # Variables Kimchi's entry point overwrites before anything reads them,
  # with the sidecar's reason. A value set for one of these is never read.
  # The extractor derives `consumerOverridable` from src/entry.ts's top-level
  # assignment order; the annotations carry only descriptions.
  fixedEnvironmentVariables =
    lib.mapAttrs (_: variable: variable.reason or "Kimchi overwrites it at launch")
    (lib.filterAttrs (_: variable: !(variable.consumerOverridable or false)) variables);

  # Every variable the factory sets itself goes through this, so a Kimchi
  # release that stops reading one (the environment census drops it), or
  # starts overwriting it (the entry.ts analysis flips `consumerOverridable`),
  # fails evaluation by name instead of leaving a dead `--set` in the wrapper.
  environmentName = name:
    if (variables.${name}.consumerOverridable or false)
    then name
    else throw "ai.kimchi sets ${name}, which packages/kimchi/extracted.json does not list as a variable Kimchi reads and lets the caller set. Kimchi ${extracted.provenance.kimchiVersion} stopped reading it or overwrites it; update packages/kimchi/lib/mkKimchi.nix.";

  report = {
    excluded = lib.mapAttrs (_: s: s.excluded) generated;
    staleExclusions = stale exclusions;
    staleNotes = stale notes;
    staleRefinements = stale refinements;
    untyped = lib.concatMap (s: s.untyped) (builtins.attrValues generated);
  };
}
