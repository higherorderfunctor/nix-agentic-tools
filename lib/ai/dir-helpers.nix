# Directory-based ingestion helpers for the ai.* factory.
#
# Helpers in this file map a source directory (or
# `{ path, filter? }` submodule) into an attrset shape that
# conforms to the per-file ai.* pool types (rules, skills,
# agents, hooks). They are pure — no `home.file` / `files.*`
# emission here — so the same helpers are shared between HM
# and devenv backends and may be called from consumer code
# that isn't participating in the factory.
#
# Canonical shape:
#
#   pathOrSubmodule : path | { path, filter? }
#     path   — the source directory: a path literal, or a path-like
#              string or derivation (a flake input's "${src}/agents")
#     filter — name → bool, applied to each direntry name; null or
#              absent uses the helper's own default (.md for rules,
#              the runtime's suffixes for agents, every entry for
#              skills and hooks).
#
# Polymorphic input resolution happens at each helper's call
# site rather than being lifted here so the helpers stay
# thin. `resolveDirArg` centralizes the shape normalization.
{lib}: let
  # A path literal stays a path, and a store-path string or derivation
  # becomes its store string, so `path + "/${name}"` works for both. Any
  # other absolute string (`"${config.devenv.root}/agents"`) becomes a path
  # literal, so each entry is a path or a store string and every runtime
  # copies its content instead of writing its path as the file's text.
  asDir = value:
    if builtins.isPath value
    then value
    else let
      s = "${value}";
    in
      if lib.hasPrefix "${builtins.storeDir}/" s
      then s
      else /. + s;
  # Normalize a polymorphic path | { path, filter? } argument to
  # a concrete `{ path, filter }` record. Consumers may pass a
  # bare path-like value and rely on the helper's default filter; a null
  # filter (the option's default) means the same.
  resolveDirArg = defaultFilter: arg:
    if lib.isStringLike arg
    then {
      path = asDir arg;
      filter = defaultFilter;
    }
    else {
      path = asDir arg.path;
      filter =
        if (arg.filter or null) == null
        then defaultFilter
        else arg.filter;
    };
in {
  # Rules from a directory of `.md` files. Each `.md` file
  # becomes one rule entry. The attrset key is the basename
  # with the `.md` suffix stripped (so emission can re-append
  # the suffix without producing the `.md.md` doubled-extension
  # bug the original readDir-based consumer had).
  #
  # Returns: attrsOf ruleModule-compatible attrs. Each value is
  # `{ source = <path to file> }`; emitters read it only when they must inject
  # frontmatter and otherwise preserve the home.file-shaped source record.
  rulesFromDir = arg: let
    cfg = resolveDirArg (name: lib.hasSuffix ".md" name) arg;
    entries = builtins.readDir cfg.path;
    matches =
      lib.filterAttrs
      (name: kind: kind == "regular" && cfg.filter name)
      entries;
    stripMd = name: lib.removeSuffix ".md" name;
  in
    lib.mapAttrs' (
      name: _:
        lib.nameValuePair (stripMd name) {
          source = cfg.path + "/${name}";
        }
    )
    matches;

  # Skills from a directory-of-directories. Each immediate
  # subdirectory becomes one skill entry. The attrset key is
  # the subdir name (unchanged); the value is a path to the
  # subdirectory, suitable for the per-CLI `skills` option
  # (which expects `attrsOf path`).
  #
  # Default filter is always-true — consumers that need to
  # exclude a subdir supply their own filter (name → bool).
  skillsFromDir = arg: let
    cfg = resolveDirArg (_: true) arg;
    entries = builtins.readDir cfg.path;
    matches =
      lib.filterAttrs
      (name: kind: kind == "directory" && cfg.filter name)
      entries;
  in
    lib.mapAttrs (
      name: _: cfg.path + "/${name}"
    )
    matches;

  # Agents from a directory of native agent files. Each top-level regular
  # file whose name ends in one of `suffixes` becomes one raw entry of a
  # per-runtime `ai.<runtime>.agents` pool, keyed by the basename minus that
  # suffix, with the file's path as its value, so it blends with named
  # entries there. Subdirectories and other files are not expanded. The
  # builder passes the runtime record's `agentsDirSuffixes` (`.md` unless
  # the runtime's native files differ, like Kiro's `.json`). Two files with
  # one stem (`foo.json` and `foo.md`) would name one agent twice, so that
  # throws instead of keeping either.
  agentsFromDirWith = suffixes: arg: let
    matchesSuffix = name: lib.any (suffix: lib.hasSuffix suffix name) suffixes;
    cfg = resolveDirArg matchesSuffix arg;
    entries = builtins.readDir cfg.path;
    matches =
      lib.filterAttrs
      (name: kind: kind == "regular" && cfg.filter name)
      entries;
    stripSuffix = name:
      lib.foldl' (stem: suffix:
        if stem == name
        then lib.removeSuffix suffix name
        else stem)
      name
      suffixes;
    collisions =
      lib.filterAttrs (_: names: builtins.length names > 1)
      (lib.groupBy stripSuffix (builtins.attrNames matches));
  in
    if collisions != {}
    then throw "agentsDir ${toString cfg.path}: ${lib.concatStringsSep "; " (lib.mapAttrsToList (stem: names: "${lib.concatStringsSep " and " names} both map to agent `${stem}`") collisions)}. Keep one file per agent."
    else
      lib.mapAttrs' (
        name: _:
          lib.nameValuePair (stripSuffix name) (cfg.path + "/${name}")
      )
      matches;

  # Claude-only hook files. Default filter accepts any regular
  # file — Claude hooks are shell scripts and typically have
  # no extension. Returns `attrsOf lines` via readFile so
  # `ai.claude.hookScripts` (inline script text) accepts the
  # output directly.
  hooksFromDir = arg: let
    cfg = resolveDirArg (_: true) arg;
    entries = builtins.readDir cfg.path;
    matches =
      lib.filterAttrs
      (name: kind: kind == "regular" && cfg.filter name)
      entries;
  in
    lib.mapAttrs (
      name: _: builtins.readFile (cfg.path + "/${name}")
    )
    matches;
}
