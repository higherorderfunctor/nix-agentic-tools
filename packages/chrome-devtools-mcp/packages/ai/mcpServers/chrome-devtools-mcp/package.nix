# chrome-devtools-mcp — Google's prebuilt Chrome DevTools MCP server.
#
# The flat npm-tarball/sourceRoot shape follows aihubmix-mcp: npm publishes a
# package/ tree rather than a GitHub archive, and the sidecar records the flat
# tarball hash. Unlike that package, chrome-devtools-mcp@1.13.0 declares no
# runtime dependencies, so there is no lockfile to fabricate and no npmDeps
# derivation to fetch. The tarball already contains its bundled ESM output.
{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs) fetchurl lib makeWrapper nodejs_22 stdenv;
  vu = packageLib;

  sources = builtins.fromJSON (builtins.readFile ../../../../sources.json);
  sourcesFile = repoPath ../../../../sources.json;
in
  stdenv.mkDerivation {
    pname = "chrome-devtools-mcp";
    inherit (sources) version;

    src = fetchurl {
      url = sources.src.url;
      hash = sources.src.hash;
    };

    # npm tarballs extract under package/.
    sourceRoot = "package";

    dontConfigure = true;
    dontBuild = true;

    nativeBuildInputs = [makeWrapper];

    installPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preInstall

      mkdir -p "$out/lib/chrome-devtools-mcp" "$out/bin"
      # The root manifest marks the shipped .js outputs as ESM; Node needs it
      # beside those outputs before it executes the entry point.
      cp package.json "$out/lib/chrome-devtools-mcp/package.json"
      cp -R out/Default/gen/src/. "$out/lib/chrome-devtools-mcp/"
      makeWrapper ${lib.getExe nodejs_22} "$out/bin/chrome-devtools-mcp" \
        --add-flags "$out/lib/chrome-devtools-mcp/bin/chrome-devtools-mcp.js"

      runHook postInstall
    '';

    # The server starts over stdio but materializes a browser only for a tool
    # call. Feeding /dev/null therefore checks startup without launching one.
    # It sends no MCP initialize, so it does not prove the handshake or tools.
    doInstallCheck = true;
    installCheckPhase = ''
      export CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1
      export CHROME_DEVTOOLS_MCP_NO_CONFIG_DISCOVERY=1
      export CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1
      ${vu.mkMcpSmokeTest {
        bin = "chrome-devtools-mcp";
        marker = "exposes content of the browser instance";
      }}
    '';

    passthru.updateScript = vu.mkUpdateScript {
      inherit pkgs sourcesFile;
      pname = "chrome-devtools-mcp";
      platforms = {
        # One platform-independent npm artifact.
        src = ver: "https://registry.npmjs.org/chrome-devtools-mcp/-/chrome-devtools-mcp-${ver}.tgz";
      };
      versionCheck.cmd = "${pkgs.curl}/bin/curl -fsSL https://registry.npmjs.org/chrome-devtools-mcp | ${pkgs.jq}/bin/jq -r '.[\"dist-tags\"].latest // empty'";
    };

    meta = {
      description = "MCP server for Chrome DevTools";
      homepage = "https://github.com/ChromeDevTools/chrome-devtools-mcp#readme";
      license = lib.licenses.asl20;
      platforms = lib.platforms.unix;
      mainProgram = "chrome-devtools-mcp";
    };
  }
