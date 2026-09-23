# Regression tests for lib/traceSource.nix.
#
# `registerTrackedInputs` walks a source tree at EVAL time, so every hazard it
# has to survive aborts `nix flake check`, `devenv shell` and direnv outright
# rather than failing one derivation. Both fixture shapes encode a hazard seen in the
# wild:
#
#   - `fixtures/binary-*` carry a file with NUL bytes (a CPython `.pyc`
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
# Two checks, not one, are what close off a name-based blocklist — the
# alternative fix, skipping `__pycache__` and known binary extensions by name.
# A blocklist that MISSES a file is caught by `hashes-unreadable-bytes`, which
# aborts exactly as the defect did; the fixture is deliberately named
# `payload.pyc-fixture` so a literal `*.pyc` rule does not match it. A
# blocklist that MATCHES is caught by `tracks-binary-contents`: `binary-a` and
# `binary-b` differ in one byte, inside the binary payload only, so skipping
# that file collides the two trees and silently drops it from the content
# trace. Neither check can be satisfied by a blocklist; both are satisfied by
# hashing the bytes.
{
  harness,
  lib,
  ...
}: let
  traceSource = import ../../lib/traceSource.nix {inherit lib;};

  mkTest = harness.mkAssertion "trace-source";

  isSha256Hex = s: builtins.match "[0-9a-f]{64}" s != null;

  binaryA = traceSource.registerTrackedInputs ./fixtures/binary-a;
  binaryB = traceSource.registerTrackedInputs ./fixtures/binary-b;
in {
  checks = {
    # Fails by ABORTING evaluation against a `readFile`-based walk.
    trace-source-hashes-unreadable-bytes =
      mkTest "hashes-unreadable-bytes" (isSha256Hex binaryA);

    trace-source-skips-dangling-symlinks =
      mkTest "skips-dangling-symlinks"
      (isSha256Hex (traceSource.registerTrackedInputs ./fixtures/symlinks));

    trace-source-tracks-binary-contents =
      mkTest "tracks-binary-contents" (binaryA != binaryB);
  };

  # NOT COVERED, and no pure-Nix assertion can cover it: that the caller FORCES
  # the returned digest. Forcing is observable only as an abort or as a direnv
  # reload, and `builtins.tryEval` does not catch the I/O errors `readDir` and
  # `hashFile` raise (measured 2026-09-22). A call site that computes the value
  # and drops it makes the module a no-op there and still passes this suite.
  # The consumer comment in
  # packages/stacked-workflows/packages/stacked-workflows-content/package.nix
  # carries that warning where a reader would act on it.
}
