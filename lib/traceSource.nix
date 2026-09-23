# Register every regular file under a source tree as a tracked eval input, so
# that direnv reloads the shell when one of them is edited.
#
# THE ONLY REMAINING CONSUMER IS DIRENV. Measured 2026-09-22 on devenv
# 2.3.2+87edd16, Nix 2.34.4, direnv 2.37.1, across four independent passes (two
# measuring, two refuting). Each of the other two candidate consumers was
# checked and does not need this:
#
#   - NIX ITSELF NEVER NEEDED IT. `builtins.path` and a bare `${./dir}` store
#     copy are content-addressed. A content-only edit inside the tree moves the
#     store path with no fingerprint involved, so the output rebuilds on its
#     own. Measured on the filtered `builtins.path {filter = ...;}` shape that
#     `stacked-workflows-content` uses, not only on the bare one.
#
#   - DEVENV'S EVAL CACHE NO LONGER NEEDS IT. `.devenv/nix-eval-cache.db`
#     records a bare store-copied directory as `is_directory=1, recursive=1`
#     with a content hash over the whole subtree (the `recursive` column
#     arrived in devenv migration `20260603000000`). A content-only edit moves
#     that hash and busts the cache. Measured across all three real call
#     shapes: `ai.skills.<name> = ./dir`, `env.X = "${./dir}"`, and
#     `builtins.path {path = ./dir; filter = ...;}`. 21 trials, upheld under an
#     independent refutation pass that added the missing "unrelated edit is
#     inert" control and re-ran every edit with the inode and size held fixed.
#
# What direnv watches is a different set, and that is the gap this closes.
# devenv's `direnvrc` builds `use_devenv`'s ENTIRE watch set by running
# `watch_file` over the lines of `.devenv/input-paths.txt`, which holds the
# individual paths evaluation touched — whether it read their bytes or
# realized them into the store. GRANULARITY, NOT READING, IS WHAT DECIDES: a
# DIRECTORY store copy registers the directory, and a directory yields no
# usable watch (measured: 0 watch entries for a bare `${./dir}` and 0 for the
# filtered `builtins.path` shape, and 0 of 594 watches was a directory). A
# PER-FILE realization registers that one leaf, and that leaf is watched — so
# a store copy is not inert in general, only a whole-directory one is.
# Hashing each file with `builtins.hashFile` reaches the same per-leaf
# granularity by reading, which is the route available here. devenv exposes no
# API for this — every `watch` option it has (`processes.<name>.watch.paths`,
# `tasks.<name>.process.watch.paths`) restarts a PROCESS, not the shell — so
# walking the tree file by file IS the mechanism and there is no cleaner call
# to switch to.
#
# TWO MECHANISMS, TWO KEYS, and confusing them produces wrong conclusions:
# direnv triggers on MTIME, devenv's eval cache on CONTENT. A content edit that
# restores the original mtime reloads nothing while the eval cache still
# catches it; a bare `touch` with identical bytes reloads direnv. So this buys
# a watch, not a content check.
#
# FOR DIRENV, THE MISSED CASE IS **ADD**, NOT EDIT. An edit is caught and a
# removal is caught, because both move a watched path's stat. An ADD is not:
# direnv watches individual files only, never directories, so a path that did
# not exist during evaluation has no watch to trip. The exception is real —
# evaluation probes paths that do not exist (33 of 301 input paths on this
# repo: `devenv.local.nix`, `.env`, `pathExists` probes, dangling symlinks), so
# creating one of THOSE does reload.
#
# MEASURED UNDER `devenv hook`: THAT MIGRATION ENDS THIS MODULE. The operator
# intends to migrate off direnv to devenv 2.1's shell integration
# (`eval "$(devenv hook zsh)"`, no `.envrc`, trust via `devenv allow`).
# Measured 2026-09-23 on devenv 2.3.2+87edd16, 24 activations, controls
# passing:
#
#   - `devenv hook` HAS NO WATCH SET AND NO RELOAD PATH. `_devenv_hook`
#     returns at its first statement when `DEVENV_ROOT` is set, so inside an
#     active devenv shell nothing is noticed — not even an edit to
#     `devenv.nix`. It never reads `.devenv/input-paths.txt`. Verified for
#     zsh, not only bash: the two hook scripts differ by 13 lines, all of them
#     the registration tail (`PROMPT_COMMAND` vs `precmd_functions`) and a
#     `_DEVENV_SHELL_HINT` value, and the `DEVENV_ROOT` early return is line
#     30 in both.
#
#   - ITS ONLY REFRESH POINT IS EXITING AND RE-ENTERING THE SHELL, where the
#     decider is devenv's own content-hashed eval cache — the
#     `is_directory=1, recursive=1` mechanism described above.
#
#   - SO THIS MODULE IS DEAD POST-MIGRATION. The pure store copy
#     `env.X = "${./dir}"` picks up a content edit on re-entry with no wrapper
#     at all, 3/3, and the wrapped twin behaves identically.
#
#   - IT ALSO INVERTS DIRENV'S KEYING: content, not mtime, and an ADDED file
#     IS caught — the opposite of direnv on both.
#
# NOT MEASURED: ablating the `registerTrackedInputs` call site itself under
# the hook. The mechanism says it is redundant too, but that is inference.
#
# So the module's remaining justification is direnv SPECIFICALLY, and
# migrating to `devenv hook` ends that justification: the module and its one
# call site can be deleted when the migration happens. Confirm by ABLATION,
# and ablate FIRST — remove this module and its call site, THEN make a
# content-only edit to a file under `packages/stacked-workflows/references/`
# and check whether the environment picks it up. Running that check with the
# module still in place cannot distinguish "the hook catches this" from
# "`registerTrackedInputs` put the path there". If it is caught without the
# module, the deletion stands; if not, restore it.
#
# The migration itself is the operator's call and is NOT made here. It carries
# a cost they are weighing: no in-shell reload at all, and a 15-20s cold
# re-entry.
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
# cache. Editing a SIBLING file the builtin never touched was also served from
# cache, so what is tracked is the individual file, not the enclosing tree. On
# text the two spellings agree byte-for-byte, so no existing value moved.
#
# Symlinks are skipped on purpose: a stale devenv activation can drop dangling
# store-path symlinks into a source skill dir, and hashing a broken link would
# abort evaluation — `hashFile` resolves its argument, so this hazard survives
# the move off `readFile`. The skip covers a symlinked DIRECTORY too, so
# content behind one would be invisible to the walk — but no symlinked
# directory exists in this repo, so that arm is untested rather than load
# bearing. What is real is symlinked FILES: every
# `packages/stacked-workflows/skills/*/references/` is a real directory
# holding symlinks into `packages/stacked-workflows/references/`, and the walk
# skips every one of them. They are covered because `stacked-workflows-content`
# registers that shared `references/` tree separately.
#
# THE CALLER MUST FORCE THE RESULT, or the hashes never execute and nothing is
# registered. Put the returned string in a derivation env attr; that is what
# makes eval demand it. The value itself is incidental — a reader who assumes
# the attr is unused and deletes it silently removes the watch registration.
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
in {
  # Read every regular file under `src` with `builtins.hashFile`, which is what
  # registers each as a tracked eval input and therefore as a direnv watch.
  #
  # The returned digest exists only to give the caller something to force. It
  # is built as `<relative-path>\n<sha256-of-contents>\n` per file, hashed as a
  # whole: the per-file path plus fixed-width content hash plus newline framing
  # make it unambiguous, so no byte shifting a change across a file boundary
  # can collide two different trees. The relative path (not absolute) keeps the
  # value stable across checkout locations, which matters because it lands in a
  # derivation env attr.
  registerTrackedInputs = src: let
    base = toString src + "/";
  in
    builtins.hashString "sha256" (
      lib.concatMapStrings
      (f: "${lib.removePrefix base (toString f)}\n${builtins.hashFile "sha256" f}\n")
      (collect src)
    );
}
