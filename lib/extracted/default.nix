{pkgs}: let
  inherit (pkgs) lib;
  facts = import ./facts.nix {inherit lib;};
  platforms = import ./platforms.nix;
  host = pkgs.stdenv.hostPlatform.system;
  # The drift check's `passthru.regenerate`; regenCommand runs it.
  regenerateName = name: "${name}-regenerate-extracted";
  mkDriftCheck = {
    # The owner's committed `extracted.json`.
    committed,
    # `{ "<system>" = derivation; }`; a derivation's `system` is the host its
    # extraction runs on.
    extracted,
    name,
    results ? {},
    # The committed file's repository path, as a string, for messages and
    # `regenerate`. A path derived from `committed` would move with its owner,
    # and checks.facet-owner-relocation requires the check not to.
    sidecar,
  }: let
    failures = lib.concatMap (surface: surface.failures) (builtins.attrValues results);
    merged = builtins.fromJSON (builtins.readFile committed);
    # Every system whose extraction runs on this host, compared with its
    # projection of the committed file.
    handled = builtins.filter (system: extracted ? ${system} && extracted.${system}.system == host) (import ../../config/systems.nix);
    projection = system: pkgs.writeText "${name}-${system}-committed.json" (builtins.toJSON (platforms.project merged system));
    compare = system: ''
      if ! "$jq" -e -n --slurpfile a ${extracted.${system}} --slurpfile b ${projection system} '$a == $b' > /dev/null; then
        echo "FAIL: ${name}: the ${system} side of ${sidecar} is out of sync with its extraction sources." >&2
        "$jq" -S . ${projection system} > committed.json
        "$jq" -S . ${extracted.${system}} > fresh.json
        ${pkgs.diffutils}/bin/diff -u committed.json fresh.json >&2 || :
        echo "Regenerate from the repository root:" >&2
        echo '  nix run .#checks.${host}.${name}-extracted.passthru.regenerate' >&2
        drifted=1
      fi
    '';
    # Carries this host's fresh raws into the committed file; only an
    # x86_64-linux carry makes the other systems follow (platforms.nix carry).
    regenerate = import ../strict-shell-application.nix pkgs {
      name = regenerateName name;
      text =
        if handled == []
        then ''
          echo "${name}: no extraction runs on ${host}; ${sidecar} is unchanged"
        ''
        else ''
          echo "${name}: carrying ${toString handled} into ${sidecar}"
          ${pkgs.nix}/bin/nix-instantiate --eval --strict --json \
            --argstr committed "$PWD/${sidecar}" --expr ${lib.escapeShellArg ''
            {committed}: let
              read = file: builtins.fromJSON (builtins.readFile file);
            in
              (import ${./platforms.nix}).carry {
                fresh = {${lib.concatMapStrings (system: "\"${system}\" = read \"${extracted.${system}}\"; ") handled}};
                merged = read committed;
                systems = builtins.fromJSON ${builtins.toJSON (builtins.toJSON (import ../../config/systems.nix))};
              }
          ''} > "${sidecar}.new"
          ${pkgs.coreutils}/bin/mv "${sidecar}.new" "${sidecar}"
          ${pkgs.coreutils}/bin/chmod 644 "${sidecar}"
          ${pkgs.nix}/bin/nix fmt -- "${sidecar}"
          echo "${name}: wrote ${sidecar}"
        '';
    };
  in {
    "${name}-extracted" =
      pkgs.runCommand "${name}-extracted-drift" {
        passthru = {inherit extracted handled regenerate;};
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        jq="${pkgs.jq}/bin/jq"
        drifted=0
        ${lib.concatMapStrings compare handled}if [ "$drifted" -eq 1 ]; then exit 1; fi
        ${lib.optionalString (failures != []) ''
          echo 'FAIL: ${name} extraction rows need attention:' >&2
          "$jq" . ${pkgs.writeText "${name}-extracted-failures.json" (builtins.toJSON failures)} >&2
          exit 1
        ''}
        echo "ok — ${name} sidecar matches the fresh extraction" > "$out"
      '';
  };

  # One test of a buildGoModule package: `sources` (name → file) join the Go
  # package directory `packagePath` (relative to `modRoot`), and `go test`
  # runs the test named `run` there, offline, with the package's own
  # toolchain and vendor tree and the `env` given. The test reads a joined
  # file by its name, from its working directory; `postTest` writes `$out`.
  goTest = {
    env ? {},
    sources,
    name,
    package,
    packagePath,
    postTest,
    run,
  }:
    pkgs.runCommand name {nativeBuildInputs = [package.go pkgs.jq];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export HOME="$TMPDIR" GOCACHE="$TMPDIR/go-cache" GOFLAGS=-mod=vendor GOPROXY=off GOTOOLCHAIN=local
      # Pure Go avoids the test binary's runtime/cgo dependency on gcc.
      export CGO_ENABLED=0
      cp -r --no-preserve=mode,ownership ${package.src} src # bare-commands: ok (runCommand builder PATH)
      cd src/${package.modRoot}
      cp -r --no-preserve=mode,ownership ${package.goModules} vendor # bare-commands: ok (runCommand builder PATH)
      ${lib.concatStrings (lib.mapAttrsToList (file: source: ''
          cp ${source} ${packagePath}/${file} # bare-commands: ok (runCommand builder PATH)
        '')
        sources)}${lib.concatStrings (lib.mapAttrsToList (variable: value: "export ${variable}=${lib.escapeShellArg value}\n") env)}go test -count=1 -run '^${run}$' ./${packagePath}/
      ${postTest}
    '';
in {
  inherit (facts) children expect get hostRunOn load merge;
  inherit (import ./reconcile.nix {inherit lib;}) reconcile;
  inherit goTest mkDriftCheck;
  index = facts.index pkgs;

  # A Go owner's raw: its extractor test, joined to one package of a
  # buildGoModule package's source with ./go/nat_shared_test.go, which takes
  # the test's package clause. The test writes an object of surfaces to
  # $NAT_EXTRACT_OUT.
  goTestExtract = {
    package,
    packagePath,
    testFile,
  }: let
    clause = lib.findFirst (lib.hasPrefix "package ") (throw "${toString testFile}: no package clause") (lib.splitString "\n" (builtins.readFile testFile));
  in
    goTest {
      env.NAT_EXTRACT_OUT = "raw.json";
      sources = {
        "nat_extract_test.go" = testFile;
        "nat_shared_test.go" = pkgs.writeText "nat_shared_test.go" (builtins.replaceStrings ["\npackage nat\n"] ["\n${clause}\n"] (builtins.readFile ./go/nat_shared_test.go));
      };
      name = "${package.pname}-extracted";
      inherit package packagePath;
      postTest = ''jq -S . ${packagePath}/raw.json >"$out"'';
      run = "TestNatExtract";
    };

  mkOwnerCheck = {
    dir,
    name,
    needs ? [],
    package ? null,
    # An owner whose extractions run on other hosts names each one.
    extracted ? {${host} = package.passthru.extracted;},
    results ? {},
  }: let
    ownerFacts = facts.load {inherit dir;};
  in
    mkDriftCheck {
      committed = dir + "/extracted.json";
      inherit extracted name;
      # `facts` and `consumers` are this builder's own surfaces; an owner's
      # `results` (reconcile output) may not shadow them, or a supplied
      # `facts.failures = []` would silence every merge failure.
      results =
        lib.throwIf (results ? consumers || results ? facts)
        "mkOwnerCheck ${name}: results.facts and results.consumers are reserved; pass reconcile results under their own surface names"
        (results
          // {
            consumers = facts.expect {
              inherit (ownerFacts) aggregate;
              consumer = name;
              inherit needs;
            };
            facts = ownerFacts;
          });
      sidecar = "packages/${name}/extracted/extracted.json";
    };

  # An owner's update script carries this host's extractions into its
  # committed file; the script echoes the written path.
  regenCommand = {name}: ''
    regenerate=$(${pkgs.nix}/bin/nix build --no-link --print-out-paths \
      ".#checks.${host}.${name}-extracted.passthru.regenerate")
    "$regenerate/bin/${regenerateName name}"
  '';
}
