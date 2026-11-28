# Regression tests for lib/traceSource.nix.
#
# `registerTrackedInputs` walks a source tree at eval time, so an unhandled
# file type can abort `nix flake check`, `devenv shell` or direnv rather than
# failing one derivation. Both fixture shapes reproduce observed hazards:
#
#   - `fixtures/binary-a` carries a file with NUL bytes (a CPython `.pyc`
#     header). `builtins.readFile` refuses those bytes — "the contents of the
#     file ... cannot be represented as a Nix string" — and an agent that
#     imported a `dev/skills/*/scripts/*.py` instead of running it dropped
#     exactly such a file into a traced tree three times in one day.
#     `.gitignore` gives no cover: the walk reads the working tree and never
#     consults git.
#   - `fixtures/symlinks` carries a DANGLING symlink. The real-world shape is a
#     leftover `<hash>-<name>` store-path link from a stale devenv activation;
#     the fixture keeps a plain name because `readDir` types by lstat, not by
#     name, so the name is not what is under test.
#
# The binary fixture rules out a name-based blocklist that skips `__pycache__`
# and known binary extensions. A blocklist that misses `payload.pyc-fixture`
# (such as a literal `*.pyc` rule) still aborts with a `readFile` walk. One that
# matches it drops the payload, producing a digest that fails the fixed answer.
{
  harness,
  lib,
  ...
}: let
  traceSource = import ../../lib/traceSource.nix {inherit lib;};

  mkTest = harness.mkAssertion "trace-source";

  # Regenerate the fixed answers from each fixture directory. Use the listed
  # paths for binary-a; for symlinks, use only real.txt.
  # for f in nested/payload.pyc-fixture text.txt; do digest=$(sha256sum < "$f"); printf '%s\n%s\n' "$f" "${digest%% *}"; done | sha256sum
  # Including real.txt ensures a walk that skips the entire symlink fixture fails.
  # If only the framing in registerTrackedInputs changes, regenerate the pins;
  # a change to the framing alone is not a file-tracking regression.
  inherit (traceSource) registerTrackedInputs;
in {
  checks.trace-source-tracks-regular-files = mkTest "tracks-regular-files" (
    harness.checkRows "trace-source digest" {
      "binary-a hashes the nested NUL payload and its text sibling" =
        registerTrackedInputs ./fixtures/binary-a == "3d027bdf1e1dee626eaee932995e8fcade24e594f2ad43d79329518a5d9edeeb";
      "symlinks hashes real.txt and skips the dangling link" =
        registerTrackedInputs ./fixtures/symlinks == "b8d9e81f9ee837f693d915720c2cb053ae62544a5598bccd8f281ea7ece824c1";
    }
  );

  # NOT COVERED, and no pure-Nix assertion can cover it: that the caller FORCES
  # the returned digest. Forcing is observable only as an abort or as a direnv
  # reload, and `builtins.tryEval` does not catch the I/O errors `readDir` and
  # `hashFile` raise (measured 2026-09-22). A call site that computes the value
  # and drops it makes the module a no-op there and still passes this suite.
  # The consumer comment in
  # packages/stacked-workflows/packages/stacked-workflows-content/package.nix
  # carries that warning where a reader would act on it.
}
