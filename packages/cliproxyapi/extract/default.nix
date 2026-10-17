# Run the pinned config package with its own toolchain and vendor tree offline.
{pkgs}: package:
pkgs.runCommand "cliproxyapi-extracted" {nativeBuildInputs = [package.go pkgs.jq];} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  export HOME="$TMPDIR" GOCACHE="$TMPDIR/go-cache" GOFLAGS=-mod=vendor GOPROXY=off GOTOOLCHAIN=local
  # Pure Go avoids the test binary's runtime/cgo dependency on gcc.
  export CGO_ENABLED=0
  cp -r --no-preserve=mode,ownership ${package.src} src
  cp -r --no-preserve=mode,ownership ${package.goModules} src/vendor
  cp ${./config_test.go} src/internal/config/nat_config_test.go
  cd src
  NAT_EXTRACT_OUT="$TMPDIR/config.json" go test -count=1 -run '^TestNatExtract$' ./internal/config/
  jq -S -n --slurpfile config "$TMPDIR/config.json" '{config: $config[0]}' >"$out"
''
