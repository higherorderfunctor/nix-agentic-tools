# fetch-from-hugging-face — `fetchFromHuggingFace` against an offline fixture.
#
# The fixture tree mirrors the Hugging Face URL layout
# (<owner>/<repo>/resolve/<rev>/<path>), so a `file://` endpoint serves it the
# way huggingface.co serves the real thing. Interpolating the fixture path
# makes it an input of the fixed-output derivation, which is what puts it
# inside the build sandbox. The first endpoint never exists, so every file
# comes from the per-file fallback. `with space.txt` only resolves if the URL
# path is percent-encoded, because curl decodes file:// URLs.
{
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../lib/packaging.nix) fetchFromHuggingFace;
  endpointRoot = ./fixtures/hugging-face;
  licenseFile = ./fixtures/hugging-face-license;
  attribution = "Literal shell text: $(false) `false` $out";
  rev = "0123456789abcdef0123456789abcdef01234567";
  files = ["1_Pooling/config.json" "config.json" "with space.txt"];
  fetch = overrides:
    fetchFromHuggingFace ({
        inherit files pkgs rev;
        endpoints = ["file:///nonexistent" "file://${endpointRoot}"];
        hash = "sha256-MP1zsg60xuXTvvkTr6MXwHbhCx8dV0DKXOY9Xa11ACg=";
        owner = "fixture-owner";
        repo = "Fixture-Model";
      }
      // overrides);
  plain = fetch {};
  attributed = fetch {inherit attribution;};
  licensed = fetch {
    inherit attribution licenseFile;
    license = lib.licenses.mit;
  };
  rejects = overrides: !(builtins.tryEval (fetch overrides)).success;
  source = "${endpointRoot}/fixture-owner/Fixture-Model/resolve/${rev}";
in {
  checks.fetch-from-hugging-face = assert !rejects {};
  assert !rejects {files = ["LICENSE"];};
  assert rejects {rev = "main";};
  assert rejects {rev = builtins.substring 0 7 rev;};
  assert rejects {files = [];};
  assert rejects {files = ["../x"];};
  assert rejects {files = ["a/../x"];};
  assert rejects {files = ["/abs"];};
  assert rejects {files = [""];};
  assert rejects {files = ["a//b"];};
  assert rejects {files = ["config.json" "config.json"];};
  assert rejects {
    inherit attribution;
    files = ["LICENSE"];
  };
  assert rejects {
    inherit licenseFile;
    files = ["ATTRIBUTION"];
  };
  assert plain.name == "fixture-model-0123456";
  assert plain.meta.license == lib.licenses.unfree;
  assert licensed.meta.license == lib.licenses.mit;
  assert plain.meta.sourceProvenance == [lib.sourceTypes.binaryBytecode];
  assert plain.passthru.files == files;
  # A licence wrapper links the SAME fetched tree: one copy of the weights.
  assert licensed.fetched.outPath == plain.outPath;
    pkgs.runCommand "fetch-from-hugging-face" {} ''
      for file in ${lib.escapeShellArgs files}; do
        cmp "${plain}/$file" "${source}/$file"
        cmp "${licensed}/$file" "${source}/$file"
      done
      test -L ${licensed}/1_Pooling/config.json
      test ! -e ${plain}/extra.txt
      test ! -e ${plain}/LICENSE
      test ! -e ${plain}/ATTRIBUTION
      test ! -e ${attributed}/LICENSE
      cmp ${licensed}/LICENSE ${licenseFile}
      printf '%s' ${lib.escapeShellArg attribution} | cmp - ${attributed}/ATTRIBUTION
      printf '%s' ${lib.escapeShellArg attribution} | cmp - ${licensed}/ATTRIBUTION
      touch "$out"
    '';
}
