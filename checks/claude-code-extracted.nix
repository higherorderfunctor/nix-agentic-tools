# Drift check — the committed overlays/claude-code-extracted.json must
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
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  extracted = self.packages.${system}.claude-code.passthru.extracted;
  committed = ../overlays/claude-code-extracted.json;
in {
  claude-code-extracted = pkgs.runCommand "claude-code-extracted-drift" {} ''
    jq="${pkgs.jq}/bin/jq"
    if "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} \
      '$a == $b' > /dev/null; then
      echo "ok — overlays/claude-code-extracted.json matches the packaged binary" > $out
    else
      echo "FAIL: overlays/claude-code-extracted.json is out of sync with the claude binary." >&2
      echo "--- diff: committed (-) vs extracted from binary (+), first 80 lines ---" >&2
      # `|| true`: diff exits 1 when the files differ, which is the case we are
      # already in, and `head` closing the pipe early would make it exit 141.
      # Either would abort this branch before the guidance below is printed.
      "$jq" -S . ${committed} > committed.json
      "$jq" -S . ${extracted} > extracted.json
      ${pkgs.diffutils}/bin/diff -u committed.json extracted.json \
        | ${pkgs.coreutils}/bin/head -80 >&2 || true
      echo "" >&2
      echo "Regenerate: nix build .#claude-code.passthru.extracted --no-link --print-out-paths" >&2
      echo "then cp the result over overlays/claude-code-extracted.json and 'git add' it." >&2
      exit 1
    fi
  '';
}
