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
# Returns true, or throws naming the offending fields.
{lib}: let
  backendKeys = ["installPackage" "migrationConfig" "options"];
  defaultsKeys = ["package"];
  unknownIn = allowed: attrs: lib.subtractLists allowed (builtins.attrNames attrs);
  listed = lib.concatStringsSep ", ";
in
  {
    name,
    defaults ? {},
    hm ? {},
    devenv ? {},
    ...
  }: let
    checkBackend = backend: spec: let
      unknown = unknownIn backendKeys spec;
    in
      lib.assertMsg (unknown == [])
      "ai runtime ${name}: ${backend} spec carries ${listed unknown}; a backend spec takes only ${listed backendKeys}. Describe delivery once in the record-level `config`, which receives `backend`.";
    unknownDefaults = unknownIn defaultsKeys defaults;
  in
    checkBackend "hm" hm
    && checkBackend "devenv" devenv
    && lib.assertMsg (unknownDefaults == [])
    "ai runtime ${name}: defaults carries ${listed unknownDefaults}; it takes only ${listed defaultsKeys}."
