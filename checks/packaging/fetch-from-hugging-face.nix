# fetch-from-hugging-face — `fetchFromHuggingFace` against an offline fixture.
#
# The fixture tree mirrors the Hugging Face URL layout
# (<owner>/<repo>/resolve/<rev>/<path>), so a `file://` endpoint serves it the
# way huggingface.co serves the real thing. Interpolating the fixture path
# makes it an input of the fixed-output derivation, which is what puts it
# inside the build sandbox. The first endpoint never exists, so every file
# comes from the per-file fallback. `with space.txt` only resolves if the URL
# path is percent-encoded, because curl decodes file:// URLs.
#
# The fetches the build step reads go through invalidateFetcherByDrvHash. A
# FOD's store path depends on name and hash only, so without it a builder
# change keeps the old path, finds it already valid, and never runs: a broken
# fetcher would still pass on any machine that built the fixture once.
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
  args = overrides:
    {
      inherit files pkgs rev;
      endpoints = ["file:///nonexistent" "file://${endpointRoot}"];
      hash = "sha256-MP1zsg60xuXTvvkTr6MXwHbhCx8dV0DKXOY9Xa11ACg=";
      owner = "fixture-owner";
      repo = "Fixture-Model";
    }
    // overrides;
  fetch = overrides: fetchFromHuggingFace (args overrides);
  fresh = overrides: pkgs.testers.invalidateFetcherByDrvHash fetchFromHuggingFace (args overrides);
  licensedArgs = {
    inherit attribution licenseFile;
    license = lib.licenses.mit;
  };
  plain = fetch {};
  licensed = fetch licensedArgs;
  freshPlain = fresh {};
  freshAttributed = fresh {inherit attribution;};
  freshLicensed = fresh licensedArgs;
  rejects = overrides: !(builtins.tryEval (fetch overrides)).success;
  # The licence gate itself, not just the meta value: check-meta must refuse
  # the unfree default on both layers once allowUnfree is off.
  strict = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = false;
  };
  evaluates = overrides:
    (builtins.tryEval (fetchFromHuggingFace (args overrides // {pkgs = strict;})).drvPath).success;
  source = "${endpointRoot}/fixture-owner/Fixture-Model/resolve/${rev}";
in {
  checks.fetch-from-hugging-face = assert !rejects {};
  assert !rejects {files = ["LICENSE"];};
  assert !rejects {
    inherit attribution;
    files = ["LICENSE"];
  };
  assert rejects {rev = "main";};
  assert rejects {rev = builtins.substring 0 7 rev;};
  assert rejects {files = [];};
  assert rejects {files = ["../x"];};
  assert rejects {files = ["a/../x"];};
  assert rejects {files = ["/abs"];};
  assert rejects {files = [""];};
  assert rejects {files = ["a//b"];};
  assert rejects {files = ["config.json" "config.json"];};
  assert rejects {files = ["config.json" "Config.json"];};
  assert rejects {
    inherit licenseFile;
    files = ["LICENSE"];
  };
  assert rejects {
    inherit licenseFile;
    files = ["LICENSE/x"];
  };
  assert rejects {
    inherit licenseFile;
    files = ["license"];
  };
  assert rejects {
    inherit attribution;
    files = ["ATTRIBUTION"];
  };
  assert rejects {
    inherit attribution;
    files = ["ATTRIBUTION/x"];
  };
  assert plain.name == "fixture-model-0123456";
  assert (fetch {name = "custom";}).name == "custom";
  assert lib.getName plain == "fixture-model";
  assert lib.getName licensed == "fixture-model";
  assert lib.getName (fetch {rev = "abcdef0123456789abcdef0123456789abcdef01";}) == "fixture-model";
  assert plain.meta.description == "fixture-owner/Fixture-Model at 0123456 (Hugging Face)";
  assert plain.meta.license == lib.licenses.unfree;
  assert licensed.meta.license == lib.licenses.mit;
  assert licensed.fetched.meta.license == lib.licenses.mit;
  assert !(evaluates {});
  assert !(evaluates {inherit attribution;});
  assert evaluates {license = lib.licenses.mit;};
  assert evaluates licensedArgs;
  assert plain.passthru.files == files;
  # A licence wrapper links the SAME fetched tree: one copy of the weights.
  assert licensed.fetched.outPath == plain.outPath;
    pkgs.runCommand "fetch-from-hugging-face" {} ''
      for file in ${lib.escapeShellArgs files}; do
        cmp "${freshPlain}/$file" "${source}/$file"
        cmp "${freshLicensed}/$file" "${source}/$file"
      done
      test -L ${freshLicensed}/1_Pooling/config.json
      test ! -e ${freshPlain}/extra.txt
      test ! -e ${freshPlain}/LICENSE
      test ! -e ${freshPlain}/ATTRIBUTION
      test ! -e ${freshAttributed}/LICENSE
      cmp ${freshLicensed}/LICENSE ${licenseFile}
      printf '%s' ${lib.escapeShellArg attribution} | cmp - ${freshAttributed}/ATTRIBUTION
      printf '%s' ${lib.escapeShellArg attribution} | cmp - ${freshLicensed}/ATTRIBUTION
      touch "$out"
    '';
}
