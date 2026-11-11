# Reject divergent grouped-family decisions in the two v8 transformations and
# extraction. The schema baseline is committed measured data, not a fixture
# derived from the predicate under test; compare only compatibility's subtree.
{
  extractedLib,
  pkgs,
  self,
  ...
}: let
  committed = pkgs.writeText "cliproxyapi-grouped-family-committed.json" (builtins.toJSON {
    config = extracted.get (extracted.load {dir = ../extracted;}).aggregate "config";
  });
  extracted = extractedLib {inherit pkgs;};
  package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
  roundtrip = extracted.goTest {
    name = "cliproxyapi-grouped-family-roundtrip";
    inherit package;
    packagePath = "internal/config";
    postTest = ''echo "ok — compatibility grouped load/serialize shape preserved" >"$out"'';
    run = "TestV8GroupedFamily.*";
    sources = {};
  };
  schema =
    pkgs.runCommand "cliproxyapi-grouped-family-schema" {
      nativeBuildInputs = [pkgs.diffutils pkgs.jq];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      for side in expected actual; do
        case "$side" in
          expected) source=${committed} ;;
          actual) source=${package.passthru.extracted} ;;
        esac
        jq -S '.config | with_entries(select(.key == "api-keys.openai-compatibility" or (.key | startswith("api-keys.openai-compatibility[]"))))' \
          "$source" > "$side.json"
      done
      diff -u expected.json actual.json
      echo "ok — compatibility extracted schema unchanged" > "$out"
    '';
in {
  checks.cliproxyapi-grouped-family = pkgs.linkFarm "cliproxyapi-grouped-family" [
    {
      name = "roundtrip";
      path = roundtrip;
    }
    {
      name = "schema";
      path = schema;
    }
  ];
}
