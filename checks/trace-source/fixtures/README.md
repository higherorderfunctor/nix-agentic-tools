# `lib/traceSource.nix` fixtures

The bytes here are the test. Do not "clean them up".

- `binary-a/nested/payload.pyc-fixture` and its `binary-b` twin are nine bytes
  of a CPython `.pyc` header and contain NUL bytes, which `builtins.readFile`
  refuses to turn into a Nix string. They differ in exactly one byte, inside
  that payload, so a fingerprint that skipped binary files instead of hashing
  them would make the two trees collide.
- `binary-a/text.txt` and `binary-b/text.txt` are identical on purpose — they
  keep the binary payload the only difference between the two trees.
- `symlinks/dangling` points at nothing on purpose. Resolving it aborts
  evaluation, so the fingerprint has to skip symlinks rather than hash them.

See `../default.nix` for what each one pins.
