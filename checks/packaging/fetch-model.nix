{
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../lib/packaging.nix) fetchModel;
  payload = pkgs.writeText "model-fixture" "weights";
  licenseFile = ./fixtures/model-license;
  args = {
    attribution = "Literal shell text: $(false) `false` $out";
    description = "Model fetcher fixture";
    file = "weights.safetensors";
    format = "safetensors";
    license = lib.licenses.asl20;
    inherit licenseFile;
    mirrors = ["https://mirror.example/weights"];
    pkgs = pkgs // {fetchurl = attrs: payload // {fetchArgs = attrs;};};
    publisher = "publisher";
    repo = "model";
    rev = lib.concatStrings (lib.replicate 40 "a");
    sha256Hex = lib.concatStrings (lib.replicate 64 "0");
  };
  model = fetchModel args;
  rejects = overrides: !(builtins.tryEval (fetchModel (args // overrides))).success;
in {
  checks.fetch-model = assert rejects {rev = "main";};
  assert rejects {rev = "v1";};
  assert rejects {sha256Hex = "sha256-invalid";};
  assert rejects {file = "LICENSE";};
  assert !(builtins.functionArgs fetchModel).attribution;
  assert !(builtins.functionArgs fetchModel).license;
  assert !(builtins.functionArgs fetchModel).licenseFile;
  assert model.format == "safetensors";
  assert model.model.fetchArgs.urls
  == [
    "https://huggingface.co/publisher/model/resolve/${args.rev}/weights.safetensors"
    "https://mirror.example/weights"
  ];
  assert model.model.fetchArgs.hash == "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  assert model.meta.sourceProvenance == [lib.sourceTypes.binaryBytecode];
    pkgs.runCommand "fetch-model" {} ''
      test -L ${model}/${model.modelFile}
      test "$(readlink ${model}/${model.modelFile})" = ${payload}
      cmp ${model}/LICENSE ${licenseFile}
      grep -F ${lib.escapeShellArg args.attribution} ${model}/ATTRIBUTION
      grep -F 'sha256:   ${args.sha256Hex}' ${model}/ATTRIBUTION
      touch "$out"
    '';
}
