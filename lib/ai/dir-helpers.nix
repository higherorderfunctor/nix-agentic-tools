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
#     path   — Nix path literal to the source directory
#     filter — name → bool, applied to each direntry name
#              (default varies per helper — .md for rules,
#              .json for hooks, always-true for skills/agents
#              since those are directories of their own shape).
#
# Polymorphic input resolution happens at each helper's call
# site rather than being lifted here so the helpers stay
# thin. `resolveDirArg` centralizes the shape normalization.
{lib}: let
  # Normalize a polymorphic path | { path, filter? } argument to
  # a concrete `{ path, filter }` record. Consumers may pass a
  # bare path literal and rely on the helper's default filter.
  resolveDirArg = defaultFilter: arg:
    if lib.isPath arg
    then {
      path = arg;
      filter = defaultFilter;
    }
    else {
      inherit (arg) path;
      filter = arg.filter or defaultFilter;
    };
in rec {
  # Rules from a directory of `.md` files. Each `.md` file
  # becomes one rule entry. The attrset key is the basename
  # with the `.md` suffix stripped (so emission can re-append
  # the suffix without producing the `.md.md` doubled-extension
  # bug the original readDir-based consumer had).
  #
  # Returns: attrsOf ruleModule-compatible attrs. Each value is
  # `{ text = <path to file> }` — the per-CLI rule emission
  # path already accepts a path for `text` and readFile's it
  # at eval time with transformer frontmatter injected.
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
          text = cfg.path + "/${name}";
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

  # Agents from a directory of `.md` files. Each file becomes
  # one agent. Attrset value shape matches the per-CLI agents
  # option (`attrsOf (either lines path)`) — we return the
  # path directly (no wrapper record) so the existing rule
  # emission code is unchanged.
  #
  # Kiro is intentionally excluded from the agents fanout in
  # the factory (its agent shape is JSON, not markdown). This
  # helper is therefore only wired into Claude + Copilot via
  # `ai.<cli>.agentsDir` options.
  agentsFromDir = arg: let
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
        lib.nameValuePair (stripMd name) (cfg.path + "/${name}")
    )
    matches;

  # Claude-only hook files. Default filter accepts any regular
  # file — Claude hooks are shell scripts and typically have
  # no extension. Returns `attrsOf lines` via readFile so the
  # existing `programs.claude-code.hooks` option (which
  # expects inline script text) accepts the output directly.
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
