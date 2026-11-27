# Semble's real default model, minishlab/blink-code-16M-int8, fetched as
# fixed-output files at a pinned Hugging Face commit (about 17 MB) and loaded
# offline by the packaged model2vec. The other checks serve generated float
# fixtures under this model's ID, so only this one proves the int8 weights load.
{pkgs, ...}: let
  revision = "0b033346145bfcc95b81658349da73c50abfc7a3";
  file = name: hash:
    pkgs.fetchurl {
      url = "https://huggingface.co/minishlab/blink-code-16M-int8/resolve/${revision}/${name}";
      inherit hash;
    };
  model = pkgs.linkFarm "blink-code-16M-int8-${builtins.substring 0 7 revision}" [
    {
      name = "config.json";
      path = file "config.json" "sha256-B7Pkm4Nn/wNZBfiq/t282q0DGZ5WYRFYuh/Gj2GfU4c=";
    }
    {
      name = "model.safetensors";
      path = file "model.safetensors" "sha256-r688qceyP+fxXyuBWzxQbyqiRAwNBIKi1cLkU8CapiU=";
    }
    {
      name = "tokenizer.json";
      path = file "tokenizer.json" "sha256-hY8achU2xRnQ7WuvTjgnuEb44aclGiFI2j1XF6j+uys=";
    }
  ];
  script = import ./semble-script.nix pkgs "real-default-model" pkgs.ai.semble ./real-default-model.py;
in {
  checks.semble-real-default-model = pkgs.runCommand "semble-real-default-model" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    export HOME="$TMPDIR/home"
    export HF_HUB_OFFLINE=1
    ${pkgs.coreutils}/bin/mkdir -p "$HOME"
    ${script} ${model}
    ${pkgs.coreutils}/bin/touch "$out"
  '';
}
