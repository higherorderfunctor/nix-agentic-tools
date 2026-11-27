# fetch-hugging-face-model — lib.packaging.fetchHuggingFaceModel, offline.
# nixpkgs owns and tests the fetching itself.
#
# The wrapper takes the caller's `pkgs` as an argument, and this check passes
# three variants, none of which touches the network:
# - `stubbed` is pkgs with a fetchFromHuggingFace that records the arguments
#   the wrapper passed and writes one small file per sparseCheckout entry, so
#   the LICENSE / ATTRIBUTION layer can actually be built.
# - the real pkgs is only EVALUATED (name, meta, drvPath). That is enough for
#   getName and the licence gate, and proves nixpkgs accepts what the wrapper
#   passes.
# - the validation stub accepts every argument, so only the wrapper's own
#   assertions can reject an input.
# All three go through the flake's public self.lib, so the exposure is tested too.
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (harness) checkRows rejectsChange;
  inherit (pkgs.stdenv.hostPlatform) system;
  inherit (self.lib.packaging) fetchHuggingFaceModel;
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
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      for path in ${lib.escapeShellArgs (map (lib.removePrefix "/") args.sparseCheckout)}; do
        mkdir -p "$out/$(dirname "$path")"
        printf '%s\n' "$path" > "$out/$path"
      done
    '';
  stubbed = pkgs // {fetchFromHuggingFace = stub;};
  fake = overrides: fetchHuggingFaceModel ({pkgs = stubbed;} // base // overrides);
  passed = overrides: (fake overrides).args;

  real = overrides: fetchHuggingFaceModel ({inherit pkgs;} // base // overrides);
  # Unlike the real fetcher, this stub has no rev/tag xor.
  readValidation = overrides:
    (fetchHuggingFaceModel ({pkgs = pkgs // {fetchFromHuggingFace = _: {accepted = true;};};} // base // overrides)).accepted;
  rejects = invalid:
    rejectsChange readValidation {
      inherit invalid;
      valid = {};
      expected = true;
    };
  # The licence gate itself, not just the meta value: check-meta must refuse
  # the unfree default on both layers once the CALLER's allowUnfree is off.
  strict = import pkgs.path {
    inherit system;
    config.allowUnfree = false;
  };
  strictFetch = overrides: let
    result = fetchHuggingFaceModel ({pkgs = strict;} // base // overrides);
  in
    builtins.seq result.drvPath result.name;
  rejectsUnfree = valid: invalid:
    rejectsChange strictFetch {
      inherit invalid valid;
      expected = "fixture-model-0123456";
    };

  plain = fake {};
  noticedTree = fake noticed;
  attributedTree = fake {inherit attribution;};
  collision = pkgs.testers.testBuildFailure (fake {
    inherit licenseFile;
    files = ["license"];
  });
in {
  # Exposure: a plain function on the public lib, the only packaging helper
  # exported there, and neither an overlay leaf nor a flake package.
  checks.fetch-hugging-face-model = assert builtins.isFunction self.lib.packaging.fetchHuggingFaceModel;
  assert builtins.attrNames self.lib.packaging == ["fetchHuggingFaceModel"];
  assert !(pkgs.ai or {} ? fetchHuggingFaceModel);
  assert !(pkgs ? fetchHuggingFaceModel);
  assert !(self.ciPackages.${system} ? fetchHuggingFaceModel);
  # `pkgs` is consumed, never handed to nixpkgs.
  assert !(passed {} ? pkgs);
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
  assert removeAttrs (passed {}).derivationArgs ["pos"]
  == {
    pname = "fixture-model";
    version = "0123456";
  };
  assert (passed {derivationArgs.extra = 1;}).derivationArgs.extra == 1;
  assert (fake {passthru.extra = 1;}).extra == 1;
  assert (fake (noticed // {passthru.extra = 1;})).extra == 1;
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
  assert lib.getName (real (noticed // {name = "custom";})) == "fixture-model";
  assert lib.getName (real {rev = "abcdef0123456789abcdef0123456789abcdef01";}) == "fixture-model";
  assert (real {}).meta.homepage == "https://huggingface.co/fixture-owner/Fixture-Model";
  assert (real noticed).fetched.outPath == (real mit).outPath;
  # meta.position names the caller, not the wrapper.
  assert lib.hasInfix "/checks/packaging/fetch-hugging-face-model.nix:" (real {}).meta.position;
  assert lib.hasInfix "/checks/packaging/fetch-hugging-face-model.nix:" (real noticed).meta.position;
  # No makeOverridable `override`: it would skip the wrapper.
  assert !((real {}) ? override || (real {}) ? overrideDerivation);
  assert (real {}) ? overrideAttrs && (real noticed) ? overrideAttrs;
  assert checkRows "fetch-hugging-face-model arguments" {
    "a free licence allows both notices" = strictFetch noticed == "fixture-model-0123456";
    "absolute paths are not model-relative" = rejects {files = ["/abs"];};
    "branch names are not full commit hashes" = rejects {rev = "main";};
    "case-folded paths must be unique" = rejects {files = ["config.json" "Config.json"];};
    "dot components are not allowed" = rejects {files = ["./x"];};
    "empty path components are not allowed" = rejects {files = ["a//b"];};
    "empty paths are not allowed" = rejects {files = [""];};
    "exact path lists must not be empty" = rejects {files = [];};
    "exact paths cannot be combined with sparse patterns" = rejects {sparseCheckout = ["/*.json"];};
    "licence belongs in license rather than meta.license" = rejects {meta.license = lib.licenses.mit;};
    "nested parent components are not allowed" = rejects {files = ["a/../x"];};
    "notice layer is unfree without an explicit free licence" = rejectsUnfree (mit // {inherit attribution;}) {inherit attribution;};
    "revision must not be null" = rejects {rev = null;};
    "short commit hashes are not full commit hashes" = rejects {rev = "0123456";};
    "tag-only selectors are forbidden" = rejects {
      rev = null;
      tag = "v1";
    };
    "tags cannot accompany a pinned commit" = rejects {tag = "v1";};
    "top-level parent components are not allowed" = rejects {files = ["../x"];};
    "unwrapped model is unfree without an explicit free licence" = rejectsUnfree mit {};
  };
    pkgs.runCommand "fetch-hugging-face-model" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

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
