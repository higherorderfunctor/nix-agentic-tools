# Instantiate `ourPkgs` from `inputs.nixpkgs` so every build input
# (python interpreter, hatchling, pytest/git/openssh/gnupg check deps)
# routes through this repo's pinned nixpkgs instead of the consumer's.
# This is what gives the store path cache-hit parity against CI's
# standalone build — see dev/fragments/overlays/cache-hit-parity.md
# and dev/notes/overlay-cache-hit-parity-fix.md.
#
# No rust-overlay here — git-revise is a pure-python build.
{inputs}: sources: final: _prev: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final) system;
    config.allowUnfree = true;
  };
  nv = sources.git-revise;
  inherit (ourPkgs) lib stdenv;
in {
  git-revise = ourPkgs.python3Packages.buildPythonApplication {
    pname = "git-revise";
    inherit (nv) version src;
    pyproject = true;

    build-system = [ourPkgs.python3Packages.hatchling];

    nativeCheckInputs =
      [ourPkgs.git ourPkgs.openssh ourPkgs.python3Packages.pytestCheckHook]
      ++ lib.optionals (!stdenv.hostPlatform.isDarwin) [ourPkgs.gnupg];

    disabledTests = lib.optionals stdenv.hostPlatform.isDarwin [
      "test_gpgsign"
    ];

    meta = {
      description = "Efficiently update, split, and rearrange git commits";
      homepage = "https://github.com/mystor/git-revise";
      license = lib.licenses.mit;
      mainProgram = "git-revise";
    };
  };
}
