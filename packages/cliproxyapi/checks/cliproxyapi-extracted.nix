# Drift and annotation reconciliation for the measured-once v8 config shape.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: let
  packages = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
  configFacts = packages.cliproxyapi.passthru.extracted;
  opencodeGoFacts = import ../extract/opencode-go.nix {
    inherit pkgs;
    docs = packages.cliproxyapi-opencode-go-docs;
  };
  zhipuaiFacts = import ../extract/zhipuai.nix {
    inherit pkgs;
    docs = packages.cliproxyapi-zhipuai-docs;
  };
  extracted = pkgs.runCommand "cliproxyapi-extracted" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.jq}/bin/jq --slurpfile opencodeGo ${opencodeGoFacts} --slurpfile zhipuai ${zhipuaiFacts} \
      '. + {opencodeGo: $opencodeGo[0], zhipuai: $zhipuai[0]}' ${configFacts} > "$out"
  '';
in {
  checks = (extractedLib {inherit pkgs;}).mkOwnerCheck {
    dir = ../extracted;
    name = "cliproxyapi";
    extracted.${pkgs.stdenv.hostPlatform.system} = extracted;
    results = import ../extract/rules.nix {inherit lib;};
  };
}
