{
  harness,
  lib,
  pkgs,
  ...
}: let
  materialize = import ../../lib/ai/materialize.nix {lib = harness.hmLib;};
  expected = pkgs.writeText "materializer-complete-payload" (lib.concatStrings (lib.replicate 8192 "complete payload line\n"));
  common = {
    inherit (pkgs) coreutils diffutils flock gnugrep;
    stateSlug = "oracle-runtime";
    targetDir = "managed";
  };
  script = backend: files: let
    activation = materialize.mkHmActivation (common // {inherit files;});
    body =
      if backend == "hm"
      then activation.materialize-oracle-runtime-prune.text + "\n" + activation.materialize-oracle-runtime-write.text
      else
        (materialize.mkDevenvTask (common
          // {
            inherit files;
            hasFiles = false;
          })).exec;
  in
    pkgs.writeShellScript "materializer-${backend}" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${body}
    '';
  cases = map (backend: {
    inherit backend expected;
    concurrent = script backend {
      "payload.txt" = {
        renderCommand = "${pkgs.python3}/bin/python ${./materializer-runtime.py} render ${expected}";
        strategy = "copy";
      };
    };
    empty = script backend {};
    initial = script backend {
      "payload.txt" = {
        strategy = "copy";
        text = "previous generation\n";
      };
    };
  }) ["devenv" "hm"];
  check = control:
    pkgs.runCommand "ai-delivery-materializer-${control}" {} ''
      ${pkgs.python3}/bin/python ${./materializer-runtime.py} ${control} \
        ${pkgs.writeText "materializer-cases.json" (builtins.toJSON cases)}
      echo 'PASS: materializer ${control}' > "$out"
    '';
in {
  checks = {
    ai-delivery-materializer-concurrent = check "concurrent";
    ai-delivery-materializer-fifo = check "fifo";
  };
}
