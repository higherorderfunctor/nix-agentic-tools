# CLIProxyAPI's own code, run as an extractor and as a validator: a copy of
# the pinned source with the package's vendor tree, built by the package's
# toolchain offline, with ./config_test.go and ./accounts_test.go dropped into
# the packages whose unexported tables they read.
{pkgs}: package: let
  harness = name: script:
    pkgs.runCommand name {nativeBuildInputs = [package.go pkgs.jq];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export HOME="$TMPDIR" GOCACHE="$TMPDIR/go-cache" GOFLAGS=-mod=vendor GOPROXY=off GOTOOLCHAIN=local
      # Pure Go: without this the test binary pulls in runtime/cgo and needs gcc.
      export CGO_ENABLED=0
      cp -r --no-preserve=mode,ownership ${package.src} src
      cp -r --no-preserve=mode,ownership ${package.goModules} src/vendor
      cp ${./config_test.go} src/internal/config/nat_config_test.go
      cp ${./accounts_test.go} src/internal/watcher/synthesizer/nat_accounts_test.go
      cd src
      ${script}
    '';
in {
  # The raw for packages/cliproxyapi/extracted/: the v8 configuration tree and
  # the auth-file fields.
  extracted = harness "cliproxyapi-extracted" ''
    NAT_EXTRACT_OUT="$TMPDIR/config.json" go test -count=1 -run '^TestNatExtract$' ./internal/config/
    NAT_EXTRACT_OUT="$TMPDIR/accounts.json" go test -count=1 -run '^TestNatAccounts$' ./internal/watcher/synthesizer/
    jq -S -n --slurpfile accounts "$TMPDIR/accounts.json" --slurpfile config "$TMPDIR/config.json" \
      '{accounts: $accounts[0], config: $config[0]}' >"$out"
  '';

  # ValidateV8Config over every file in the directory `validate`, and
  # LoadConfig over a writable copy of every file in `load`.
  validate = name: {
    load,
    validate,
  }:
    harness name ''
      NAT_LOAD_DIR=${load} NAT_VALIDATE_DIR=${validate} go test -count=1 -run '^TestNat(Load|Validate)$' ./internal/config/
      echo ok >"$out"
    '';
}
