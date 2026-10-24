# Run the config-credential patch tests against the patched source; the
# package build tests only its cmd/cpa-manager-plus subPackage.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks.cpa-manager-plus-config-credentials = (extractedLib {inherit pkgs;}).goTest {
    name = "cpa-manager-plus-config-credentials";
    package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cpa-manager-plus;
    packagePath = "internal/service/proxy";
    postTest = ''echo "ok — CPA Manager Plus config-credential tests" >"$out"'';
    run = "TestConfigCredentials.*";
    sources = {};
  };
}
