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
  checks.fetch-hugging-face-model = assert checkRows "fetch-hugging-face-model public exposure" {
    "exports the fetcher as a plain function, not an overridable record" = builtins.isFunction self.lib.packaging.fetchHuggingFaceModel;
    "keeps internal packaging helpers out of the public library" = builtins.attrNames self.lib.packaging == ["fetchHuggingFaceModel"];
    "does not export a package leaf" = !(self.ciPackages.${system} ? fetchHuggingFaceModel);
    "does not export an AI overlay leaf" = !(pkgs.ai or {} ? fetchHuggingFaceModel);
    "does not export a top-level overlay leaf" = !(pkgs ? fetchHuggingFaceModel);
  };
  assert checkRows "fetch-hugging-face-model fetcher wiring" {
    "caller derivation arguments survive generated package identity" = (passed {derivationArgs.extra = 1;}).derivationArgs.extra == 1;
    "caller description overrides the generated description" = (passed {meta.description = "custom";}).meta.description == "custom";
    "caller package set is consumed instead of forwarded" = !(passed {} ? pkgs);
    "custom name reaches the fetcher" = (passed {name = "custom";}).name == "custom";
    "default backend uses LFS" = (passed {}).backend == "lfs";
    "default description names the repository and pinned commit" = (passed {}).meta.description == "fixture-owner/Fixture-Model at 0123456 (Hugging Face)";
    "default licence is unfree" = (passed {}).meta.license == lib.licenses.unfree;
    "exact paths do not become directory selectors" = (passed {}).nonConeMode;
    "explicit cone mode survives caller-supplied patterns" =
      !(passed {
        files = null;
        nonConeMode = false;
        sparseCheckout = ["onnx"];
      }).nonConeMode;
    "explicit xet backend is not overwritten by LFS" = (passed {backend = "xet";}).backend == "xet";
    "glob metacharacters in exact paths stay literal" = (passed {files = ["a*b?[c]\\d"];}).sparseCheckout == ["/a\\*b\\?\\[c]\\\\d"];
    "no file selection leaves sparse checkout unset" = !(passed {files = null;} ? sparseCheckout);
    "notice layer retains caller passthru" = (fake (noticed // {passthru.extra = 1;})).extra == 1;
    "notice layer retains the caller licence on the fetch" = noticedTree.fetched.args.meta.license == lib.licenses.mit;
    "notice layer retains the caller licence on the output" = noticedTree.meta.license == lib.licenses.mit;
    "pattern input defaults to non-cone mode" =
      (passed {
        files = null;
        sparseCheckout = ["/*.json"];
      }).nonConeMode;
    "patterns are forwarded without literal escaping" =
      (passed {
        files = null;
        sparseCheckout = ["/*.json"];
      }).sparseCheckout
      == ["/*.json"];
    "stable package identity is independent of the output name" =
      removeAttrs (passed {}).derivationArgs ["pos"]
      == {
        pname = "fixture-model";
        version = "0123456";
      };
    "submodule choice reaches the fetcher" = (passed {fetchSubmodules = true;}).fetchSubmodules;
    "unwrapped result retains caller passthru" = (fake {passthru.extra = 1;}).extra == 1;
  };
  # Force real nixpkgs derivations for argument compatibility and metadata.
  assert checkRows "fetch-hugging-face-model nixpkgs integration" {
    "changing the commit does not change the package identity" = lib.getName (real {rev = "abcdef0123456789abcdef0123456789abcdef01";}) == "fixture-model";
    "custom name does not replace getName on the fetch" = lib.getName (real {name = "custom";}) == "fixture-model";
    "custom name does not replace getName on the notice output" = lib.getName (real (noticed // {name = "custom";})) == "fixture-model";
    "fetch metadata points at the caller rather than the wrapper" = lib.hasInfix "/checks/packaging/fetch-hugging-face-model.nix:" (real {}).meta.position;
    "identity does not include the revision on the notice output" = lib.getName (real noticed) == "fixture-model";
    "notice layer leaves the underlying fetch unchanged" = (real noticed).fetched.outPath == (real mit).outPath;
    "notice metadata points at the caller rather than the wrapper" = lib.hasInfix "/checks/packaging/fetch-hugging-face-model.nix:" (real noticed).meta.position;
    "real fetcher keeps its own homepage default" = (real {}).meta.homepage == "https://huggingface.co/fixture-owner/Fixture-Model";
    "supported derivation overrides remain on both outputs" = (real {}) ? overrideAttrs && (real noticed) ? overrideAttrs;
    "unsupported overrides cannot bypass validation on the fetch" = !((real {}) ? override || (real {}) ? overrideDerivation);
  };
  assert checkRows "fetch-hugging-face-model input restrictions" {
    "a free licence allows both notices" = strictFetch noticed == "fixture-model-0123456";
    "absolute paths are not model-relative" = rejects {files = ["/abs"];};
    "branch names are not full commit hashes" = rejects {rev = "main";};
    "case-folded paths must be unique" = rejects {files = ["config.json" "Config.json"];};
    "dot components are not allowed" = rejects {files = ["./x"];};
    "empty path components are not allowed" = rejects {files = ["a//b"];};
    "exact path lists must not be empty" = rejects {files = [];};
    "exact paths cannot be combined with sparse patterns" = rejects {sparseCheckout = ["/*.json"];};
    "licence belongs in license rather than meta.license" = rejects {meta.license = lib.licenses.mit;};
    "nested parent components are not allowed" = rejects {files = ["a/../x"];};
    "notice layer is unfree without an explicit free licence" = rejectsUnfree (mit // {inherit attribution;}) {inherit attribution;};
    "revision must not be null" = rejects {rev = null;};
    "short commit hashes are not full commit hashes" = rejects {rev = "0123456";};
    "tags cannot accompany a pinned commit" = rejects {tag = "v1";};
    "unwrapped model is unfree without an explicit free licence" = rejectsUnfree mit {};
  };
    pkgs.runCommand "fetch-hugging-face-model" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      # Adding notices must not copy or replace fetched contents.
      for file in ${lib.escapeShellArgs files}; do
        cmp "${plain}/$file" "${noticedTree}/$file"
      done
      test -L ${noticedTree}/1_Pooling
      # Each optional notice is opt-in, including on the wrapped tree.
      test ! -e ${plain}/LICENSE
      test ! -e ${plain}/ATTRIBUTION
      test ! -e ${attributedTree}/LICENSE
      # Preserve the supplied bytes rather than evaluating shell text.
      cmp ${noticedTree}/LICENSE ${licenseFile}
      printf '%s' ${lib.escapeShellArg attribution} | cmp - ${attributedTree}/ATTRIBUTION
      printf '%s' ${lib.escapeShellArg attribution} | cmp - ${noticedTree}/ATTRIBUTION
      # A case-folded spelling must not be shadowed by the generated notice.
      grep -q 'already has LICENSE' ${collision}/testBuildFailure.log
      touch "$out"
    '';
}
