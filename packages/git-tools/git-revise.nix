sources: final: _: let
  nv = sources.git-revise;
  inherit (final) lib stdenv;
in {
  git-revise = final.python3Packages.buildPythonApplication {
    pname = "git-revise";
    inherit (nv) version src;
    pyproject = true;

    build-system = [final.python3Packages.hatchling];

    nativeCheckInputs =
      [final.git final.openssh final.python3Packages.pytestCheckHook]
      ++ lib.optionals (!stdenv.hostPlatform.isDarwin) [final.gnupg];

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
