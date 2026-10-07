# Drift check — the committed packages/claude-code/extracted.json must
# match what the packaged claude binary actually contains. Blocking
# (pins/levels must be exact for correctness). The build of
# passthru.extracted also enforces the non-empty / count==1 hardening
# baked into vu.mkClaudeExtract.
#
# This is also the ONLY place a darwin-generated sidecar is ever compared
# against the committed (linux-generated) one: nothing local can run a macOS
# build, so `build (aarch64-darwin, macos-latest)` is the first real test that
# the two platforms' settings censuses agree. A divergence shows up here and
# nowhere else, which is why the failure branch prints a DIFF rather than
# dumping both documents — the sidecar carries the binary's whole settings
# schema now, so a dump is ~86 KB twice and unreadable in a CI log.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (extractedLib {inherit pkgs;}) mkDriftCheck;
    extracted = self.ciPackages.${system}.claude-code.passthru.extracted;
    committed = ../extracted.json;
  in
    mkDriftCheck {
      inherit committed extracted;
      name = "claude-code";
      sidecar = "packages/claude-code/extracted.json";
    };
}
