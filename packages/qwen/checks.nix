{
  pkgs,
  self,
  ...
}: let
  model = self.packages.${pkgs.stdenv.hostPlatform.system}."qwen3-embedding-0.6b-q8_0";
in {
  checks = {
    qwen-model = pkgs.runCommand "qwen-model" {} ''
      test -L ${model}/${model.modelFile}
      test "$(readlink ${model}/${model.modelFile})" = ${model.model}
      printf '%s  %s\n' ${model.sha256Hex} ${model}/${model.modelFile} | sha256sum -c -
      cmp ${model}/LICENSE ${./licenses/Apache-2.0}
      grep -F 'Revision: ${model.rev}' ${model}/ATTRIBUTION
      touch "$out"
    '';
    qwen-model-license = pkgs.runCommand "qwen-model-license" {} ''
      ${pkgs.python3.withPackages (ps: [ps.gguf])}/bin/python3 ${./scripts}/test-check-license.py
      touch "$out"
    '';
    qwen-model-update = pkgs.runCommand "qwen-model-update" {} ''
      ${pkgs.python3}/bin/python3 ${./scripts}/test-update-model.py
      touch "$out"
    '';
  };
}
