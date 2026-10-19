# The runtime record's closed fields, checked where the record is built
# (`mkRuntime.nix`) AND where it is read (`mkBackendTransform.nix`).
#
# Both sites are needed. The records are exported as plain attrsets, so an
# override (`r // {hm = r.hm // {config = …;};}`) or a hand-built record reaches
# `hmTransform` / `devenvTransform` without passing the constructor. The
# transform reads only record-level `config` and `defaults`, so a field
# written against the retired per-backend seam would otherwise be dropped with
# no error: the runtime evaluates and delivers nothing.
#
# `poolOptions` is closed the same way. The transform reads it by pool name
# for the pools its `poolOption` declares, and only when the record supports
# that pool, so a misspelt key, an undeclared or unsupported pool, or
# `agentsDir` without the `agents` pool would change nothing. `agents` is not
# among them: a runtime appends its own sentence through
# `agentsDescriptionSuffix`, so a whole override cannot shadow the builder's.
#
# The agent fields are closed too: `agentNativeType` and `agentTransformer`
# come as a pair; they, `agentsDirSuffixes` and `agentsDescriptionSuffix` need
# the `agents` pool; and `agentsDirSuffixes` must be a non-empty list of
# strings, since an empty one makes `agentsDir` expand nothing.
#
# `executables` names the launcher package's binaries for the jail, so a
# record that consumes `jail` must have a launcher and list at least one.
#
# `record` returns true, or throws naming the offending fields.
# `sharedAgentsMd` checks the value that record callback returns, which exists
# only once the transform calls it: true, or a throw naming stray fields.
{lib}: let
  backendKeys = ["installPackage" "migrationConfig" "options"];
  defaultsKeys = ["package" "packageText"];
  # The pools whose option `mkBackendTransform.nix` declares through
  # `poolOption`, and so the only ones `poolOptions` can override.
  poolOptionPools = ["environmentVariables"];
  sharedAgentsMdKeys = ["hasOnDemandIndex" "index" "key" "maxBytes" "rules"];
  supportKeys = ["backends" "gaps" "reason"];
  gapKeys = ["each" "path" "reason" "when"];
  validBackends = backends: builtins.isList backends && lib.all (backend: builtins.elem backend ["devenv" "hm"]) backends;
  validReason = reason: builtins.isString reason || builtins.isFunction reason;
  validGap = gap:
    unknownIn gapKeys gap
    == []
    && gap ? reason
    && validReason gap.reason
    && gap ? path
    && gap.path != []
    && validPath gap.path
    && builtins.isBool (gap.each or false)
    && (!(gap ? when) || builtins.isFunction gap.when);
  validSupport = support:
    unknownIn supportKeys support
    == []
    && validBackends support.backends
    && (!(support ? reason) || builtins.isString support.reason)
    && builtins.isList (support.gaps or [])
    && lib.all validGap (support.gaps or []);
  contentTargetsKeys = ["context" "rules"];
  namespaceGroups = (import ./optionNamespaces.nix {inherit lib;}).groups;
  validPath = path: builtins.isList path && lib.all (part: builtins.isString part && part != "") path;
  unknownIn = allowed: attrs: lib.subtractLists allowed (builtins.attrNames attrs);
  listed = lib.concatStringsSep ", ";
in {
  record = record @ {
    name,
    defaults ? {},
    executables ? [],
    hm ? {},
    devenv ? {},
    optionNamespaces ? {},
    poolOptions ? {},
    surfaceSupport ? {},
    ...
  }: let
    checkBackend = backend: spec: let
      unknown = unknownIn backendKeys spec;
    in
      lib.assertMsg (unknown == [])
      "ai runtime ${name}: ${backend} spec carries ${listed unknown}; a backend spec takes only ${listed backendKeys}. Describe delivery once in the record-level `config`, which receives `backend`.";
    supportedSurfaces = builtins.attrNames (lib.filterAttrs (_: support: support.backends != []) surfaceSupport);
    unknownDefaults = unknownIn defaultsKeys defaults;
    poolOptionKeys =
      lib.intersectLists poolOptionPools supportedSurfaces
      ++ lib.optional (lib.elem "agents" supportedSurfaces) "agentsDir";
    unknownPoolOptions = unknownIn poolOptionKeys poolOptions;
    unknownNamespaces = unknownIn namespaceGroups optionNamespaces;
  in
    lib.assertMsg (lib.all validSupport (builtins.attrValues surfaceSupport))
    "ai runtime ${name}: surfaceSupport entries take backends (hm/devenv), reason and gaps; each gap takes a nonempty relative path, a boolean `each`, a reason and a when predicate."
    && checkBackend "hm" hm
    && checkBackend "devenv" devenv
    && lib.assertMsg (builtins.isAttrs optionNamespaces && unknownNamespaces == [] && lib.all validPath (builtins.attrValues optionNamespaces))
    "ai runtime ${name}: optionNamespaces maps ${listed namespaceGroups} to a list of nonempty strings (an omitted group keeps its options at the runtime root)."
    && lib.assertMsg (builtins.isList executables && lib.all (exe: builtins.isString exe && builtins.match "[^/]+" exe != null) executables)
    "ai runtime ${name}: executables must be a list of bin/ names (strings without `/`)."
    && lib.assertMsg (!(lib.elem "jail" supportedSurfaces) || (defaults ? package && executables != []))
    "ai runtime ${name}: surfaceSupport includes jail, which wraps the launcher package's executables; the record needs defaults.package and a non-empty executables list."
    && lib.assertMsg (unknownDefaults == [])
    "ai runtime ${name}: defaults carries ${listed unknownDefaults}; it takes only ${listed defaultsKeys}."
    && lib.assertMsg (unknownPoolOptions == [])
    "ai runtime ${name}: poolOptions carries ${listed unknownPoolOptions}; it takes only a pool the builder declares (${listed poolOptionPools}) that surfaceSupport consumes, plus agentsDir when that includes agents."
    # Presence only: evaluating a native type can force the factory's `pkgs`.
    && lib.assertMsg (record ? agentNativeType == record ? agentTransformer)
    "ai runtime ${name}: agentNativeType and agentTransformer describe one native agent layer; set both or neither."
    && lib.assertMsg (!(record ? agentNativeType) || lib.elem "agents" supportedSurfaces)
    "ai runtime ${name}: agentNativeType needs the agents pool in surfaceSupport."
    && lib.assertMsg (!(record ? agentsDirSuffixes || record ? agentsDescriptionSuffix) || lib.elem "agents" supportedSurfaces)
    "ai runtime ${name}: agentsDirSuffixes and agentsDescriptionSuffix need the agents pool in surfaceSupport."
    && lib.assertMsg (!(record ? agentsDirSuffixes) || (record.agentsDirSuffixes != [] && lib.all lib.isString record.agentsDirSuffixes))
    "ai runtime ${name}: agentsDirSuffixes must be a non-empty list of strings.";

  contentTargets = name: result: let
    unknown = unknownIn contentTargetsKeys result;
  in
    lib.assertMsg (unknown == [])
    "ai runtime ${name}: contentTargets must return {context?; rules?}, but it also returned ${listed unknown}.";

  sharedAgentsMd = name: result: let
    unknown = unknownIn sharedAgentsMdKeys result;
  in
    lib.assertMsg (result ? key && unknown == [])
    "ai runtime ${name}: sharedAgentsMd must return {key; hasOnDemandIndex?; index?; rules?; maxBytes?}${lib.optionalString (unknown != []) ", but it also returned ${listed unknown}"}.";
}
