# Force devenv's eval-cache tracer (and direnv's watch list) to SEE the
# CONTENTS of a source tree that is otherwise only path-copied into the store.
#
# WHY: devenv invalidates its eval cache — and direnv reloads — only on files
# that were READ during evaluation (`import` / `readFile` / `hashFile` /
# `readDir`). A bare `${src}` store copy (`cp -R ${src}` in a runCommand, or
# `builtins.path`) reads nothing INSIDE the tree, so editing a file under `src`
# changes no tracked input: devenv serves the previously-memoized (stale) store
# path and the materialized output lags the real source until some UNRELATED
# tracked input happens to change. `readDir` alone tracks only the directory
# LISTING, not file contents, so adding/removing a file is caught but editing
# one is not. Hashing every regular file here registers each as a tracked eval
# input — the same mechanism that already makes `dev/fragments/*.md` auto-bust
# the cache via `builtins.readFile`.
#
# Files are hashed with `builtins.hashFile`, NEVER with
# `builtins.hashString "sha256" (builtins.readFile f)`. `readFile` aborts
# evaluation on any file whose bytes Nix cannot hold in a string — "the
# contents of the file '...' cannot be represented as a Nix string", which a
# single NUL byte is enough to trigger. That made any binary asset in a traced
# tree — a `.pyc`, a PNG, a font — a total, invisible outage: eval aborts, the
# shell will not start, and `git status` is clean because `.gitignore` is no
# protection at all here. This walk reads the WORKING TREE and never consults
# git. Observed three times in one day on
# `dev/skills/*/scripts/__pycache__/*.pyc`, written by an agent that imported a
# script instead of running it.
#
# `hashFile` registers the file as a tracked eval input exactly as `readFile`
# does. MEASURED on devenv 2.3.2 / Nix 2.34.4 (2026-09-22), in isolated
# single-file devenv projects, one per builtin: editing the hashed file's
# CONTENTS while leaving the directory listing alone busted devenv's cache
# under `hashFile` and under `readFile` alike, whereas the same edit under a
# `readDir`-only probe was served from cache in 0.03s with the stale value.
# Editing a SIBLING file that the builtin never touched was also served from
# cache, so what is tracked is the individual file, not the enclosing tree. On
# text the two spellings agree byte-for-byte, so no existing fingerprint moved.
#
# Symlinks are skipped on purpose: a stale devenv activation can drop dangling
# store-path symlinks into a source skill dir, and hashing a broken link would
# abort evaluation — `hashFile` resolves its argument, so this hazard survives
# the move off `readFile`.
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
