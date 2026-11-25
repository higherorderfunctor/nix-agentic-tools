{
  claims = [["ai" "generic" "mitmproxy"]];
  overlay = final: _prev: {
    ai.generic.mitmproxy =
      if final.stdenv.hostPlatform.isDarwin
      then
        # Keep nixpkgs' application wrapper and its dependency pin. Override the
        # Python scope so mitmproxy-rs picks up the new wheel transitively.
        # Remove with checks/mitmproxy-macos-pin.nix when nixpkgs #591156 lands.
        final.mitmproxy.override {
          python3Packages = final.python3Packages.overrideScope (_pyFinal: pyPrev: {
            mitmproxy-macos = pyPrev.mitmproxy-macos.overridePythonAttrs (old: {
              src = old.src.override {hash = "sha256-ruw6Tl0NG8XJiyltwszNaXAxiOWUYlDU9n8eaxSYI+A=";};
            });
          });
        }
      else final.mitmproxy;
  };
}
