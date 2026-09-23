# Force devenv's eval-cache tracer (and direnv's watch list) to SEE the
# CONTENTS of a source tree that is otherwise only path-copied into the store.
#
# WHY: devenv invalidates its eval cache — and direnv reloads — only on files
# that were READ during evaluation (`import` / `readFile` / `hashFile` /
# `readDir`). `readDir` alone tracks only the directory LISTING, not file
# contents, so adding or removing a file is caught but editing one is not.
# Hashing every regular file here registers each as a tracked eval input — the
# same mechanism that makes `dev/fragments/*.md` auto-bust the cache via
# `builtins.readFile`.
#
# OPEN QUESTION, and it is measured. This header used to go on to claim that a
# bare `${src}` store copy (`cp -R ${src}` in a runCommand, or `builtins.path`)
# "reads nothing INSIDE the tree", leaving devenv to serve a stale memoized
# path after an edit under `src`. On devenv 2.3.2 / Nix 2.34.4 (2026-09-22)
# that is FALSE. Probes of both real call shapes — `env.X = "${./dir}"`, the
# `ai.skills` shape, and a `runCommand` that `cp -R`s the dir, the
# stacked-workflows-content shape — each re-evaluated to a NEW store path after
# a content-only edit inside the tree, and devenv's own
# `.devenv/nix-eval-cache.db` records the copied directory with `recursive=1`.
# So on devenv this module may now be redundant. That call belongs to its owner
# and has NOT been made here; direnv's watch list, the other consumer, was not
# measured. The claim is deleted rather than restated, because a header
# asserting a refuted mechanism is worse than one admitting the question.
#
# Files are hashed with `builtins.hashFile`, NEVER with
# `builtins.hashString "sha256" (builtins.readFile f)`. `readFile` aborts
# evaluation on any file whose bytes Nix cannot hold in a string — one NUL byte
# is enough — with "the contents of the file '...' cannot be represented as a
# Nix string". That made any binary asset in a traced tree a total, invisible
# outage: eval aborts, the shell will not start, and `git status` is clean,
# because this walk reads the WORKING TREE and never consults git, so
# `.gitignore` is no protection at all. Observed three times in one day on
# `dev/skills/*/scripts/__pycache__/*.pyc`, written by an agent that imported a
# script instead of running it.
#
# That closes the unrepresentable-bytes class, NOT every eval abort. A mode-000
# file still aborts inside `hashFile`, and a mode-000 SUBDIRECTORY still aborts
# inside `readDir` before any hashing is reached. Both aborted under `readFile`
# too, so neither is a regression — but neither is fixed here either.
#
# `hashFile` registers the file as a tracked eval input exactly as `readFile`
# does. MEASURED on devenv 2.3.2 / Nix 2.34.4, in isolated single-file devenv
# projects, one per builtin: editing the hashed file's CONTENTS while leaving
# the directory listing alone busted devenv's cache under `hashFile` and under
# `readFile` alike, whereas a `readDir`-only probe served the stale value from
# cache. That probe DID bust when a file was added, which is what proves its
# cache was live rather than frozen. Editing a SIBLING file the builtin never
# touched was also served from cache, so what is tracked is the individual
# file, not the enclosing tree. On text the two spellings agree byte-for-byte,
# so no existing fingerprint moved.
#
# Symlinks are skipped on purpose: a stale devenv activation can drop dangling
# store-path symlinks into a source skill dir, and hashing a broken link would
# abort evaluation — `hashFile` resolves its argument, so this hazard survives
# the move off `readFile`. A symlinked DIRECTORY is skipped too, which means
# content behind one is invisible to the trace. That is pre-existing and load
# bearing: stacked-workflows carries its `references/` as symlinks and covers
# them by fingerprinting that tree separately.
#
# Callers MUST FORCE the fingerprint so the hashes actually execute during eval:
#   - `fingerprint src` -> put in a derivation env attr (also makes Nix itself
#     rebuild the output when a file's content changes), or
#   - `tracedPath src`  -> returns `src` unchanged but forces the content trace
#     as a side effect (for a bare `./dir` handed straight to `ai.skills`).
#
# Regression tests: checks/trace-source/.
{lib}: let
  # Recursively collect regular-file paths under `dir`, recursing into real
  # subdirectories and skipping symlinks / unknown entry types.
  collect = dir:
    lib.concatLists (
      lib.mapAttrsToList (
        name: type: let
          path = dir + "/${name}";
        in
          if type == "directory"
          then collect path
          else if type == "regular"
          then [path]
          else [] # skip symlinks (dangling store-link cruft) and unknown types
      ) (builtins.readDir dir)
    );

  # Fingerprint each file as `<relative-path>\n<sha256-of-contents>\n`, then
  # hash the concatenation. The per-file path + fixed-width content hash +
  # newline framing make the result unambiguous: unlike a bare concatenation of
  # raw contents, no byte shifting a change across a file boundary can produce a
  # colliding fingerprint. The relative path (not absolute) keeps the value
  # stable across checkout locations. `builtins.hashFile` is what registers each
  # file as a tracked eval input — the framing is only for collision safety.
  fingerprint = src: let
    base = toString src + "/";
  in
    builtins.hashString "sha256" (
      lib.concatMapStrings
      (f: "${lib.removePrefix base (toString f)}\n${builtins.hashFile "sha256" f}\n")
      (collect src)
    );
in {
  inherit fingerprint;

  # Return `src` unchanged, forcing the content trace as a side effect. Use
  # where a bare `./dir` path must stay a path (e.g. an `ai.skills` value).
  tracedPath = src: builtins.seq (fingerprint src) src;
}
