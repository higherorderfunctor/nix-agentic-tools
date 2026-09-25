# fetch-hugging-face-model — the WRAPPER, offline. nixpkgs owns and tests the
# fetching itself.
#
# Two pkgs sets, neither of which touches the network:
# - `stubbed` swaps in a fetchFromHuggingFace that records the arguments the
#   wrapper passed and writes one small file per sparseCheckout entry, so the
#   LICENSE / ATTRIBUTION layer can actually be built.
# - the real fetcher is only EVALUATED (name, meta, drvPath). That is enough
#   for getName and the licence gate, and proves nixpkgs accepts what the
#   wrapper passes.
# Both reach the wrapper as pkgs.ai.fetchHuggingFaceModel, so the overlay
# exposure and its binding to the consumer's own pkgs are tested too.
{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  rev = "0123456789abcdef0123456789abcdef01234567";
  files = ["1_Pooling/config.json" "config.json"];
  base = {
    inherit files rev;
    hash = lib.fakeHash;
    repoId = "fixture-owner/Fixture-Model";
  };
  attribution = "Literal shell text: $(false) `false` $out";
  licenseFile = pkgs.writeText "fixture-license" "Fixture licence text.";
  mit = {license = lib.licenses.mit;};
  noticed = mit // {inherit attribution licenseFile;};

  stub = args:
    pkgs.runCommand args.name {
      inherit (args) meta;
      passthru = args.passthru // {inherit args;};
    } ''
      for path in ${lib.escapeShellArgs (map (lib.removePrefix "/") args.sparseCheckout)}; do
        mkdir -p "$out/$(dirname "$path")"
        printf '%s\n' "$path" > "$out/$path"
      done
    '';
  stubbed = pkgs.extend (_: _: {fetchFromHuggingFace = stub;});
  fake = overrides: stubbed.ai.fetchHuggingFaceModel (base // overrides);
  passed = overrides: (fake overrides).args;

  real = overrides: pkgs.ai.fetchHuggingFaceModel (base // overrides);
  rejects = overrides: !(builtins.tryEval (real overrides).drvPath).success;
  # The licence gate itself, not just the meta value: check-meta must refuse
  # the unfree default on both layers once allowUnfree is off.
  strict = import pkgs.path {
    inherit system;
    config.allowUnfree = false;
    overlays = [self.overlays.default];
  };
  evaluates = overrides: (builtins.tryEval (strict.ai.fetchHuggingFaceModel (base // overrides)).drvPath).success;

  plain = fake {};
  noticedTree = fake noticed;
  attributedTree = fake {inherit attribution;};
  collision = pkgs.testers.testBuildFailure (fake {
    inherit licenseFile;
    files = ["license"];
  });
in {
  # Exposure: a plain function on the consumer's pkgs, and not a flake package.
  checks.fetch-hugging-face-model = assert builtins.isFunction pkgs.ai.fetchHuggingFaceModel;
  assert !(self.packages.${system} ? fetchHuggingFaceModel);
  # What the wrapper hands nixpkgs.
  assert (passed {}).backend == "lfs";
  assert (passed {backend = "xet";}).backend == "xet";
  assert (passed {}).nonConeMode;
  assert (passed {}).sparseCheckout == ["/1_Pooling/config.json" "/config.json"];
  assert (passed {files = ["a*b?[c]\\d"];}).sparseCheckout == ["/a\\*b\\?\\[c]\\\\d"];
  assert (passed {
    files = null;
    sparseCheckout = ["/*.json"];
  }).sparseCheckout
  == ["/*.json"];
  assert (passed {
    files = null;
    sparseCheckout = ["/*.json"];
  }).nonConeMode;
  assert !(passed {
    files = null;
    nonConeMode = false;
    sparseCheckout = ["onnx"];
  }).nonConeMode;
  assert !(passed {files = null;} ? sparseCheckout);
  assert (passed {fetchSubmodules = true;}).fetchSubmodules;
  assert (passed {}).name == "fixture-model-0123456";
  assert (passed {name = "custom";}).name == "custom";
  assert (passed {}).derivationArgs
  == {
    pname = "fixture-model";
    version = "0123456";
  };
  assert (passed {}).meta.description == "fixture-owner/Fixture-Model at 0123456 (Hugging Face)";
  assert (passed {}).meta.license == lib.licenses.unfree;
  assert (passed {meta.description = "custom";}).meta.description == "custom";
  assert (passed mit).meta.license == lib.licenses.mit;
  assert noticedTree.fetched.args.meta.license == lib.licenses.mit;
  assert noticedTree.meta.license == lib.licenses.mit;
  # Accepted by the real fetcher, with a stable getName.
  assert (real {}).name == "fixture-model-0123456";
  assert lib.getName (real {}) == "fixture-model";
  assert lib.getName (real {name = "custom";}) == "fixture-model";
  assert lib.getName (real noticed) == "fixture-model";
  assert lib.getName (real {rev = "abcdef0123456789abcdef0123456789abcdef01";}) == "fixture-model";
  assert (real {}).meta.homepage == "https://huggingface.co/fixture-owner/Fixture-Model";
  assert (real noticed).fetched.outPath == (real mit).outPath;
  # The licence gate on both layers.
  assert !(evaluates {});
  assert !(evaluates {inherit attribution;});
  assert evaluates mit;
  assert evaluates noticed;
  # Rejects.
  assert !(rejects {});
  assert rejects {rev = "main";};
  assert rejects {rev = builtins.substring 0 7 rev;};
  assert rejects {
    rev = null;
    tag = "v1";
  };
  assert rejects {tag = "v1";};
  assert rejects {meta.license = lib.licenses.mit;};
  assert rejects {sparseCheckout = ["/*.json"];};
  assert rejects {files = [];};
  assert rejects {files = ["../x"];};
  assert rejects {files = ["a/../x"];};
  assert rejects {files = ["./x"];};
  assert rejects {files = ["/abs"];};
  assert rejects {files = [""];};
  assert rejects {files = ["a//b"];};
  assert rejects {files = ["config.json" "Config.json"];};
    pkgs.runCommand "fetch-hugging-face-model" {} ''
      for file in ${lib.escapeShellArgs files}; do
        cmp "${plain}/$file" "${noticedTree}/$file"
      done
      test -L ${noticedTree}/1_Pooling
      test ! -e ${plain}/LICENSE
      test ! -e ${plain}/ATTRIBUTION
      test ! -e ${attributedTree}/LICENSE
      cmp ${noticedTree}/LICENSE ${licenseFile}
      printf '%s' ${lib.escapeShellArg attribution} | cmp - ${attributedTree}/ATTRIBUTION
      printf '%s' ${lib.escapeShellArg attribution} | cmp - ${noticedTree}/ATTRIBUTION
      grep -q 'already has LICENSE' ${collision}/testBuildFailure.log
      touch "$out"
    '';
}
