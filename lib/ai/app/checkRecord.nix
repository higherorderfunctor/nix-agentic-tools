# The runtime record's closed fields, checked where the record is built
# (`mkRuntime.nix`) AND where it is read (`mkBackendTransform.nix`).
#
# Both sites are needed. The records are exported as plain attrsets, so an
# override (`r // {hm = r.hm // {config = …;};}`) or a hand-built record reaches
# `hmTransform` / `devenvTransform` without passing the constructor. The
# transform reads only record-level `config` and `defaults.package`, so a field
# written against the retired per-backend seam would otherwise be dropped with
# no error: the runtime evaluates and delivers nothing.
#
# `poolOptions` is closed the same way. The transform reads it by pool name
# for the pools its `poolOption` declares, and only when the record supports
# that pool, so a misspelt key, an undeclared or unsupported pool, or
# `agentsDir` without the `agents` pool would change nothing.
#
# `record` returns true, or throws naming the offending fields.
# `sharedAgentsMd` checks the value that record callback returns, which exists
# only once the transform calls it: true, or a throw naming stray fields.
{lib}: let
  backendKeys = ["installPackage" "migrationConfig" "options"];
  defaultsKeys = ["package"];
  # The pools whose option `mkBackendTransform.nix` declares through
  # `poolOption`, and so the only ones `poolOptions` can override.
  poolOptionPools = ["agents" "environmentVariables" "lspServers"];
  sharedAgentsMdKeys = ["index" "key" "maxBytes" "rules"];
  unknownIn = allowed: attrs: lib.subtractLists allowed (builtins.attrNames attrs);
  listed = lib.concatStringsSep ", ";
in {
  record = {
    name,
    defaults ? {},
    hm ? {},
    devenv ? {},
    poolOptions ? {},
    supportedPools ? [],
    ...
  }: let
    checkBackend = backend: spec: let
      unknown = unknownIn backendKeys spec;
    in
      lib.assertMsg (unknown == [])
      "ai runtime ${name}: ${backend} spec carries ${listed unknown}; a backend spec takes only ${listed backendKeys}. Describe delivery once in the record-level `config`, which receives `backend`.";
    unknownDefaults = unknownIn defaultsKeys defaults;
    poolOptionKeys =
      lib.intersectLists poolOptionPools supportedPools
      ++ lib.optional (lib.elem "agents" supportedPools) "agentsDir";
    unknownPoolOptions = unknownIn poolOptionKeys poolOptions;
  in
    checkBackend "hm" hm
    && checkBackend "devenv" devenv
    && lib.assertMsg (unknownDefaults == [])
    "ai runtime ${name}: defaults carries ${listed unknownDefaults}; it takes only ${listed defaultsKeys}."
    && lib.assertMsg (unknownPoolOptions == [])
    "ai runtime ${name}: poolOptions carries ${listed unknownPoolOptions}; it takes only a pool the builder declares (${listed poolOptionPools}) that supportedPools names, plus agentsDir when that includes agents.";

  sharedAgentsMd = name: result: let
    unknown = unknownIn sharedAgentsMdKeys result;
  in
    lib.assertMsg (result ? key && unknown == [])
    "ai runtime ${name}: sharedAgentsMd must return {key; index?; rules?; maxBytes?}${lib.optionalString (unknown != []) ", but it also returned ${listed unknown}"}.";
}
