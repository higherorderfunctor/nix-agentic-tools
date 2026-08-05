# openmemory-mcp — builds from CaviraOSS/OpenMemory mono-repo.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) buildNpmPackage bun fetchFromGitHub makeWrapper;
  vu = import ../lib.nix;

  rev = "9fdfc2ac09317881d0cdad6efd8b4859fc886323";
  src = fetchFromGitHub {
    owner = "CaviraOSS";
    repo = "OpenMemory";
    inherit rev;
    hash = "sha256-pVHStYuECa+X4XRk7fNJOWHv+ij2ZikdbDj+xK2XBXY=";
  };

  # The auto-memory backend helper (STAGE 5, D19/D20): a thin CLI over the
  # in-process `Memory` SDK. Shipped FROM this package (not a separate overlay)
  # so it shares the exact `dist/` + `node_modules` the daemon runs — guaranteeing
  # SDK/Postgres-schema lockstep. Source is repo-local (consumer-stable → cache-hit
  # parity holds). Referenced as individual file paths so only the helper (not its
  # test) enters $out. See docs/plans/kiro-cli-auto-memory.md.
  memHelper = ./openmemory-mem/openmemory-mem.ts;
  memTest = ./openmemory-mem/openmemory-mem.test.ts;
in
  buildNpmPackage {
    pname = "openmemory-mcp";
    version = vu.mkVersion {
      # upstream: readPackageJsonVersion @ packages/openmemory-js/package.json
      upstream = "1.3.3";
      inherit rev;
    };
    inherit src;
    sourceRoot = "source/packages/openmemory-js";
    postUnpack = "chmod -R u+w source";

    # SECURITY — upstream's HTTP daemon binds every interface.
    #
    # `src/server/server.ts` calls `SERVER.listen(port, cb)` with no host, so
    # Node binds `::` dual-stack. An unauthenticated memory store (the module
    # ships `devAllowNoAuth` for exactly this daemon) is then reachable from
    # the LAN and, behind a routable IPv6 prefix, from the open internet —
    # confirmed by probing a running instance over both. Upstream has no bind
    # knob to configure instead: there is no OM_HOST, and `env` in
    # `src/core/cfg.ts` carries a port and no host. Re-verified against
    # upstream HEAD, which is this exact pin (9fdfc2a) — there is no newer
    # revision to take this fix from.
    #
    # We patch the TYPESCRIPT SOURCE rather than build output: this package
    # runs tsc itself (see the note on `npmDepsHash` below), so the source is
    # what we own, and source anchors survive upstream rebuilds that a
    # dist-level patch would not.
    #
    # `host` is REQUIRED on the internal `listen`, not optional, for two
    # reasons: no wildcard-bind path survives the patch, and tsc fails the
    # build if these three edits ever drift apart. `--replace-fail` turns a
    # stale anchor into a loud build failure instead of a silent revert to
    # the insecure bind — the failure mode that matters most here.
    #
    # The default is loopback. `service.host` (default 127.0.0.1) feeds
    # OM_HOST from packages/openmemory-mcp/modules/mcp-server.nix; set it to
    # "0.0.0.0" to expose the daemon deliberately.
    #
    # This package KEEPS its config.update.targets row. The overlay guide's
    # "excludePattern + detector, never both" rule is about patching published
    # BUILD OUTPUT, which any upstream rebuild invalidates; these are source
    # anchors on upstream's own code, and the sweep is worth keeping for
    # security updates. If upstream ever edits these exact lines the sweep goes
    # HELD BACK — which is the point. Auto-sweeping past a broken security
    # patch would silently restore the all-interfaces bind.
    postPatch = ''
      substituteInPlace src/core/cfg.ts \
        --replace-fail \
          'port: num(process.env.OM_PORT, 8080),' \
          'port: num(process.env.OM_PORT, 8080), host: str(process.env.OM_HOST, "127.0.0.1"),'

      substituteInPlace src/server/server.ts \
        --replace-fail \
          'listen: (port: number, cb?: () => void) => void;' \
          'listen: (port: number, host: string, cb?: () => void) => void;' \
        --replace-fail \
          'const listen = (port: number, cb?: () => void): void => {' \
          'const listen = (port: number, host: string, cb?: () => void): void => {' \
        --replace-fail \
          'SERVER.listen(port, cb);' \
          'SERVER.listen(port, host, cb);'

      substituteInPlace src/server/index.ts \
        --replace-fail \
          'app.listen(env.port, () => {' \
          'app.listen(env.port, env.host, () => {' \
        --replace-fail \
          'Running on http://localhost:''${env.port}' \
          'Running on http://''${env.host}:''${env.port}'
    '';

    npmDepsHash = "sha256-jYvuAPpU53V44FdNmcvxQRJu7cGQBJ+7MCZPspWQwMA=";
    # Source needs building (tsc). npm tarball had pre-built dist/.
    nativeBuildInputs = [makeWrapper];

    # Run the openmemory-mem helper's own bun suite in-sandbox (pure: stub
    # backend, no Postgres/dist load), so a real regression fails the build.
    # Copied into an isolated temp dir so bun does not pick up the upstream
    # vitest suite in sourceRoot.
    doCheck = true;
    nativeCheckInputs = [bun];
    checkPhase = ''
      runHook preCheck
      mem_test_dir="$(mktemp -d)"
      cp ${memHelper} "$mem_test_dir/openmemory-mem.ts"
      cp ${memTest} "$mem_test_dir/openmemory-mem.test.ts"
      HOME="$TMPDIR" ${bun}/bin/bun test "$mem_test_dir/openmemory-mem.test.ts"
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/openmemory-mcp $out/bin
      cp -r bin dist node_modules package.json $out/lib/openmemory-mcp/
      makeWrapper ${bun}/bin/bun $out/bin/openmemory-mcp \
        --add-flags "$out/lib/openmemory-mcp/bin/opm.js" \
        --add-flags "mcp"
      makeWrapper ${bun}/bin/bun $out/bin/openmemory-mcp-serve \
        --add-flags "$out/lib/openmemory-mcp/bin/opm.js" \
        --add-flags "serve"
      # Auto-memory backend helper (STAGE 5): resolves `./dist/index.js` relative
      # to itself, so its openmemory-js deps load from the sibling node_modules.
      cp ${memHelper} $out/lib/openmemory-mcp/openmemory-mem.ts
      makeWrapper ${bun}/bin/bun $out/bin/openmemory-mem \
        --add-flags "$out/lib/openmemory-mcp/openmemory-mem.ts"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "openmemory-mcp";};
    # openmemory-mem smoke (runs via mkMcpSmokeTest's `runHook postInstallCheck`):
    # empty stdin short-circuits before any dist/Postgres load, proving bun resolves
    # the wrapped entry + dispatch runs. Live PG is exercised at the consumer flip.
    postInstallCheck = ''
      echo -n "" | $out/bin/openmemory-mem add --project-id smoke
      echo -n "" | $out/bin/openmemory-mem query --project-id smoke

      # SECURITY positive control for the bind patch. postPatch's
      # --replace-fail already guarantees the SOURCE changed and tsc rejects
      # the three edits drifting apart, so this covers the remaining gap:
      # that the compiled dist actually carries the host-threaded forms.
      #
      # It proves only the phrases listed below — it is NOT a proof that no
      # other listener exists. If upstream grows a second HTTP server, this
      # stays green; the runtime check is `ss -ltn` against a started daemon.
      #
      # `grep -F` is load-bearing, not style. Every pattern below carries a
      # `.`, which a basic regex reads as "any character" — so as a regex each
      # one also accepts a line carrying some OTHER character in that
      # position, and the control would pass on a dist that does not contain
      # the phrase it names. A positive control matching more than it claims
      # is exactly the "proves less than it appears" failure this block exists
      # to avoid.
      om_lib=$out/lib/openmemory-mcp
      grep -qF 'OM_HOST' "$om_lib/dist/core/cfg.js" \
        || { echo "bind patch lost: OM_HOST absent from cfg.js" >&2; exit 1; }
      grep -qF 'SERVER.listen(port, host, cb)' "$om_lib/dist/server/server.js" \
        || { echo "bind patch lost: server.js listen has no host" >&2; exit 1; }
      grep -qF 'env.host' "$om_lib/dist/server/index.js" \
        || { echo "bind patch lost: index.js does not pass a host" >&2; exit 1; }
    '';
    meta.mainProgram = "openmemory-mcp";
  }
