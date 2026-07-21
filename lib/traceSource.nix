# Force devenv's eval-cache tracer (and direnv's watch list) to SEE the
# CONTENTS of a source tree that is otherwise only path-copied into the store.
#
# WHY: devenv invalidates its eval cache — and direnv reloads — only on files
# that were READ during evaluation (`import` / `readFile` / `readDir`). A bare
# `${src}` store copy (`cp -R ${src}` in a runCommand, or `builtins.path`)
# reads nothing INSIDE the tree, so editing a file under `src` changes no
# tracked input: devenv serves the previously-memoized (stale) store path and
# the materialized output lags the real source until some UNRELATED tracked
# input happens to change. `readDir` alone tracks only the directory LISTING,
# not file contents, so adding/removing a file is caught but editing one is not.
# Reading every regular file here registers each as a tracked eval input — the
# same mechanism that already makes `dev/fragments/*.md` auto-bust the cache
# via `builtins.readFile`.
#
# Symlinks are skipped on purpose: a stale devenv activation can drop dangling
# store-path symlinks into a source skill dir, and `readFile` on a broken link
# would abort evaluation.
#
# Callers MUST FORCE the fingerprint so the reads actually execute during eval:
#   - `fingerprint src` -> put in a derivation env attr (also makes Nix itself
#     rebuild the output when a file's content changes), or
#   - `tracedPath src`  -> returns `src` unchanged but forces the content trace
#     as a side effect (for a bare `./dir` handed straight to `ai.skills`).
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
  # stable across checkout locations. `builtins.readFile` is still what registers
  # each file as a tracked eval input — the hashing is only for framing.
  fingerprint = src: let
    base = toString src + "/";
  in
    builtins.hashString "sha256" (
      lib.concatMapStrings
      (f: "${lib.removePrefix base (toString f)}\n${builtins.hashString "sha256" (builtins.readFile f)}\n")
      (collect src)
    );
in {
  inherit fingerprint;

  # Return `src` unchanged, forcing the content trace as a side effect. Use
  # where a bare `./dir` path must stay a path (e.g. an `ai.skills` value).
  tracedPath = src: builtins.seq (fingerprint src) src;
}
