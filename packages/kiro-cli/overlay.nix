# `ai.generic.mitmproxy`: this flake's nixpkgs mitmproxy with upstream commit
# 992052ee92d7ff4d240eafbe1afdf87c94b3f080 applied. CPython 3.13.18/3.14.10
# reject the compromised eMudhra intermediates mitmproxy 12.3.0's
# test_emudhra connects through (https://github.com/python/cpython/issues/160040),
# so the unpatched derivation fails its build-time pytest; that commit switches
# the test to mitmproxy's own TLS client, exactly as nixpkgs carries it from
# 12.3.1. One source of truth for the kiro-usage service default
# (lib/usageTracking.nix) and the usage checks, which read it through
# `ai.internal.packages`. Past 12.3.1 nixpkgs ships the patch itself, so the
# override is obsolete: evaluation throws until it is removed, which turns the
# nixpkgs update PR red instead of silently double-patching.
{lib, ...}: {
  claims = [["ai" "generic" "mitmproxy"]];
  overlay = final: _prev: {
    ai.generic.mitmproxy =
      if lib.versionOlder final.mitmproxy.version "12.3.1"
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
      else throw "packages/kiro-cli/overlay.nix: nixpkgs mitmproxy ${final.mitmproxy.version} carries the test_emudhra fix; remove this override";
  };
}
