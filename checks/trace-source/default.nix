# Regression tests for lib/traceSource.nix.
#
# The fingerprint walks a source tree at EVAL time, so every hazard it has to
# survive aborts `nix flake check`, `devenv shell` and direnv outright rather
# than failing one derivation. Both fixture shapes encode a hazard seen in the
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

  binaryA = traceSource.fingerprint ./fixtures/binary-a;
  binaryB = traceSource.fingerprint ./fixtures/binary-b;
in {
  checks = {
    # Fails by ABORTING evaluation against a `readFile`-based fingerprint.
    trace-source-fingerprint-hashes-unreadable-bytes =
      mkTest "fingerprint-hashes-unreadable-bytes" (isSha256Hex binaryA);

    trace-source-fingerprint-skips-dangling-symlinks =
      mkTest "fingerprint-skips-dangling-symlinks"
      (isSha256Hex (traceSource.fingerprint ./fixtures/symlinks));

    trace-source-fingerprint-tracks-binary-contents =
      mkTest "fingerprint-tracks-binary-contents" (binaryA != binaryB);

    # Pins the RETURN VALUE only: `tracedPath` must hand back a path, because
    # `ai.skills` needs one. It does NOT pin the `builtins.seq` that forces the
    # trace, and no pure-Nix assertion can. Forcing is observable only as an
    # abort, and `builtins.tryEval` does not catch the I/O errors `readDir` and
    # `hashFile` raise (measured 2026-09-22) — so a `tracedPath = src: src`
    # mutant, which makes the module a no-op at every call site, passes this
    # whole suite. Do not read it as covering that.
    trace-source-traced-path-returns-src =
      mkTest "traced-path-returns-src"
      (traceSource.tracedPath ./fixtures/binary-a == ./fixtures/binary-a);
  };
}
