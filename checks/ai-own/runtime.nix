{
  harness,
  pkgs,
  ...
}: let
  materialize = import ../../lib/ai/materialize.nix {lib = harness.hmLib;};
  # TODAY's rung-2 writer, driven verbatim: the TSV manifest own.py has to
  # read is produced by the generated bash that wrote every live one, so a
  # drift in either format shows up as a failure rather than as a matched pair
  # of hand-written fixtures agreeing with each other.
  legacyDir = pkgs.writeShellScript "ai-own-legacy-dir" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${
      (materialize.mkDevenvTask {
        inherit (pkgs) coreutils diffutils flock gnugrep;
        files."legacy.txt" = {
          strategy = "copy";
          text = "legacy payload\n";
        };
        hasFiles = false;
        stateSlug = "own-legacy";
        targetDir = "managed";
      })
      .exec
    }
  '';
  tools = {
    bash = "${pkgs.bash}/bin/bash";
    legacyDir = "${legacyDir}";
    legacyDoc = "${../../lib/ai/reconcile-toml.py}";
    own = "${../../lib/ai/own.py}";
    # Deliberately WITHOUT tomlkit: every dir and JSON case runs on this
    # interpreter, which is what proves the TOML import stays lazy.
    python = "${pkgs.python3}/bin/python3";
    tomlPython = "${pkgs.python3.withPackages (pythonPackages: [pythonPackages.tomlkit])}/bin/python3";
  };
in {
  checks.ai-own-runtime = pkgs.runCommand "ai-own-runtime" {} ''
    ${pkgs.python3}/bin/python3 ${./runtime.py} \
      ${pkgs.writeText "ai-own-tools.json" (builtins.toJSON tools)}
    echo 'PASS: ai-own runtime' > "$out"
  '';
}
