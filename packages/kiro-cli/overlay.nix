# `ai.generic.mitmproxy`: this flake's nixpkgs mitmproxy with upstream commit
# 992052ee92d7ff4d240eafbe1afdf87c94b3f080 applied. CPython 3.13.18/3.14.10
# reject the compromised eMudhra intermediates mitmproxy 12.3.0's
# test_emudhra connects through (https://github.com/python/cpython/issues/160040),
# so the unpatched derivation fails its build-time pytest; that commit switches
# the test to mitmproxy's own TLS client, exactly as nixpkgs carries it from
# 12.3.1. One source of truth for the kiro-usage service default
# (lib/usageTracking.nix) and the usage checks, which read it through
# `ai.internal.packages`. Past 12.3.1 nixpkgs ships the patch itself, so the
# override is obsolete: evaluation throws until it is removed. The Update
# workflow surfaces that as a hold-back, not a red update PR:
# dev/scripts/update-input.sh holds the nixpkgs input back ("update or hash
# derivation failed") and writes no update for it, dev/scripts/update-matrix.py
# annotates a warning on the first consecutive sweep, and update.yml's
# `Escalate repeated hold-backs` step fails on the second — the stale override
# cannot slip through silently.
{
  inputs,
  lib,
  system,
  ...
}: {
  claims = [["ai" "generic" "mitmproxy"]];
  overlay = final: _prev: {
    ai.generic.mitmproxy = let
      # Two separate decisions. The pin decides only when this override is
      # obsolete: the exported overlay's fallback (lib/facets/repository.nix,
      # `rootsFor`) builds claimed leaves on the consumer's `final`, so the
      # throw must follow this flake's pin (the same reach into the repo's pin
      # that packages/aihubmix-mcp's "verified against THIS repo's pin"
      # comment documents), never the consumer's set. The base being built
      # decides whether the patch is needed, so a consumer whose mitmproxy
      # already carries the fix gets it unchanged instead of patched twice.
      pinVersion = inputs.nixpkgs.legacyPackages.${system}.mitmproxy.version;
    in
      if lib.versionAtLeast pinVersion "12.3.1"
      then throw "packages/kiro-cli/overlay.nix: nixpkgs mitmproxy ${pinVersion} carries the test_emudhra fix; remove this override"
      else if lib.versionOlder final.mitmproxy.version "12.3.1"
      then
        final.mitmproxy.overridePythonAttrs (old: {
          patches =
            (old.patches or [])
            ++ [
              (final.fetchpatch {
                name = "fix-test-emudhra.patch";
                url = "https://github.com/mitmproxy/mitmproxy/commit/992052ee92d7ff4d240eafbe1afdf87c94b3f080.patch";
                hash = "sha256-kxCt72m8G+yoAWe8xsXjt1U6B2Sh02u8MCFiqi18lng=";
              })
            ];
        })
      else final.mitmproxy;
  };
}
