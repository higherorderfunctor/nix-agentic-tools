# Pin the Rust parser's legacy formats, absence, and ambiguous/missing channels.
{pkgs, ...}: {
  checks.rust-toolchain-parser = pkgs.runCommand "rust-toolchain-parser" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    ${pkgs.python3}/bin/python3 ${./rust-toolchain-parser.py} ${../../lib/packaging/rust-toolchain.py}
    touch "$out"
  '';
}
