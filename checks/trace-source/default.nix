# Regression tests for lib/traceSource.nix.
#
# The fingerprint walks a source tree at EVAL time, so every hazard it has to
# survive is a hazard that aborts `nix flake check`, `devenv shell` and direnv
# outright rather than failing one derivation. Both fixtures below encode a
# hazard that was observed in the wild:
#
#   - `fixtures/binary-*` carry a file with NUL bytes (a CPython `.pyc` header).
#     `builtins.readFile` refuses those bytes — "the contents of the file ...
#     cannot be represented as a Nix string" — and an agent that imported a
#     `dev/skills/*/scripts/*.py` instead of running it dropped exactly such a
#     file into a traced tree three times in one day. `.gitignore` gives no
#     cover: the walk reads the working tree and never consults git.
#   - `fixtures/symlinks` carries a DANGLING symlink, the shape a stale devenv
#     activation leaves behind in a source skill dir.
#
# `binary-a` and `binary-b` differ in one byte, inside the binary payload only.
# That is deliberate: it pins that binary files are HASHED rather than skipped,
# so a "just blocklist binary extensions" fix cannot pass these tests while
# silently dropping those files out of the content trace.
{
  lib,
  pkgs,
  ...
}: let
  traceSource = import ../../lib/traceSource.nix {inherit lib;};

  mkTest = name: assertion:
    pkgs.runCommandLocal "trace-source-${name}" {} (
      if assertion
      then ''echo "PASS: ${name}" > "$out"''
      else throw "FAIL: ${name}"
    );

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

    trace-source-traced-path-returns-src =
      mkTest "traced-path-returns-src"
      (traceSource.tracedPath ./fixtures/binary-a == ./fixtures/binary-a);
  };
}
