# Seed a pinned Hugging Face snapshot for Semble's offline default-model check.
# The generated float fixtures in models.nix cannot catch int8 loading failures.
{
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../../lib/packaging.nix) fetchHuggingFaceModel;
  modelId = "minishlab/blink-code-16M-int8";
  revision = "0b033346145bfcc95b81658349da73c50abfc7a3";
  cacheDirectory = "models--${lib.replaceStrings ["/"] ["--"] modelId}";
  modelSnapshot = fetchHuggingFaceModel {
    inherit pkgs;
    files = ["config.json" "model.safetensors" "tokenizer.json"];
    hash = "sha256-HgWuVJZd/3E33s40KsRRbex/PTxl3wEydfv2EjCCORk=";
    license = lib.licenses.mit;
    repoId = modelId;
    rev = revision;
  };
  script = import ./semble-script.nix pkgs "real-default-model" pkgs.ai.semble ./real-default-model.py;
in {
  checks.semble-real-default-model = pkgs.runCommand "semble-real-default-model" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    export HOME="$TMPDIR/home"
    export HF_HUB_CACHE="$TMPDIR/hf/hub"
    export HF_HUB_OFFLINE=1
    unset SEMBLE_MODEL_NAME

    model_cache="$HF_HUB_CACHE/${cacheDirectory}"
    ${pkgs.coreutils}/bin/mkdir -p "$HOME" "$model_cache/refs" "$model_cache/snapshots"
    printf '%s' '${revision}' > "$model_cache/refs/main"
    ${pkgs.coreutils}/bin/ln -s ${modelSnapshot} "$model_cache/snapshots/${revision}"
    ${script}
    ${pkgs.coreutils}/bin/touch "$out"
  '';
}
