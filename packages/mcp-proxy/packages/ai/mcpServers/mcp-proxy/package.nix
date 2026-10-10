# mcp-proxy — override nixpkgs to pin a newer version from GitHub.
#
# nixpkgs uses python3Packages.buildPythonApplication with finalAttrs
# and GitHub source. We override src/version to track upstream.
{
  pkgs,
  packageLib,
  ...
}: let
  inherit (pkgs) fetchFromGitHub;
  vu = packageLib;

  rev = "ae38d0b3c7978e991819ac6cd9742abf2165be1c";
  src = fetchFromGitHub {
    owner = "sparfenyuk";
    repo = "mcp-proxy";
    inherit rev;
    hash = "sha256-rworzDa9MJK/f+E8bzNLFr+nSxgJoPY6ehlElv32khs=";
  };
in
  pkgs.mcp-proxy.overridePythonAttrs (old: let
    # upstream: readPyprojectVersion @ pyproject.toml
    upstreamVersion = "0.12.0";
  in {
    version = vu.mkVersion {
      upstream = upstreamVersion;
      inherit rev;
    };
    inherit src;
    # Upstream added httpx-auth in v0.11.0. Append nixpkgs' OWN
    # `python3Packages.httpx-auth`, never a variant of it.
    #
    # This used to append a private `overridePythonAttrs {doCheck = false;}`
    # copy, for a jwt InsecureKeyLengthWarning test failure. That was safe
    # only while nixpkgs sat on v0.10.0 and listed no httpx-auth of its own.
    # nixpkgs d6524aa moved to 0.12.0 with `dependencies = [httpx-auth mcp
    # uvicorn]`, so the private copy became a SECOND store path for the same
    # `httpx_auth 0.23.1` and `pythonCatchConflictsPhase` failed:
    #
    #   Found duplicated packages in closure for dependency 'httpx_auth'
    #
    # Appending the identical derivation instead makes the entry a no-op
    # duplicate on a nixpkgs that already carries it (one store path, so no
    # conflict), while still supplying it on one that does not. Measured on
    # sweep 34388647306 — the first sweep after the versionCheckHook fix,
    # which is what let the build reach this phase at all.
    dependencies =
      (old.dependencies or [])
      ++ [pkgs.python3Packages.httpx-auth];
    nativeCheckInputs = with pkgs.python3Packages; [pytest pytest-asyncio];
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "mcp-proxy";};
    # Patch versionCheckHook's $version to drop our +<shortRev> suffix.
    # nixpkgs gave mcp-proxy a versionCheckHook in d6524aa (c043004 had
    # none), and the hook installs no phase of its own — it appends to
    # `preInstallCheckHooks`, so the `runHook preInstallCheck` that OPENS
    # mkMcpSmokeTest is what dispatches it. It matches the derivation's
    # `version` against `mcp-proxy --version`; ours carries the +<shortRev>
    # suffix the binary knows nothing about, so the hook `exit 2`s before
    # the smoke test body ever runs. `preVersionCheck` fires inside the hook
    # ahead of that comparison, so reassigning `version` there keeps the
    # check RUNNING, just against the string the binary actually prints.
    # Preferred over stripping the hook from `nativeInstallCheckInputs`
    # (oxlint's shape) or `dontVersionCheck`, both of which delete the
    # assertion instead of repairing it.
    preVersionCheck = ''
      version="${upstreamVersion}"
    '';
  })
