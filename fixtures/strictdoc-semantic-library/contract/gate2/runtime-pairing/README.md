# Pinned runtime pairing evidence

The [qualification report](outputs/qualification.md) records the bounded Python
3.14.6, StrictDoc 0.28.3 and rustworkx 0.17.1 result. The
[host result](outputs/host-probe-result.json) and independent
[confirmation](outputs/confirmation-result.json) agree. This is a capability
probe using a temporary search path, not the proposed production adapter.

The `outputs/` layout is retained so the producer's runner works after copying
this packet. Run the following Bash snippet from the repository root to replay
against the already acquired closure without changing committed evidence:

```bash
bash <<'SH'
set -euETo pipefail
shopt -s inherit_errexit
runtime_probe_dir=$(mktemp -d)
cp -R fixtures/strictdoc-semantic-library/contract/gate2/runtime-pairing/. "$runtime_probe_dir/"
cd "$runtime_probe_dir"
bash outputs/run-probe.sh /nix/store/6cy53r1c3lj260drvpz6g82dqr1wq405-gate2-runtime-probe-closure
SH
```

Without an argument, the runner makes a bounded request for the same closure and
writes replay logs in the disposable copy. The recorded filtered toolchain store
source and its exact locked dependencies are prerequisites; this packet is not a
standalone source distribution. See the report for acquisition limits and exact
identities. Earlier sandbox failures remain evidence of that attempt only; the
subsequent host build and both combined probes passed.
