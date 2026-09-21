# Gate 2 runtime qualification

**Qualified for this bounded pairing:** x86_64-linux, CPython 3.14.6, StrictDoc
0.28.3 and rustworkx 0.17.1, using the installed StrictDoc interpreter with the
acquired closure's site-packages added through `PYTHONPATH`. The authorized host
build and probe both exited 0. A subsequent worker confirmation against those
immutable outputs passed and matched the host result.

Method and evidence: resolve the supplied filtered toolchain's exact lock
locally, evaluate its upstream flake outputs through the unchanged
`outputs/probe.nix`, and request only the pinned StrictDoc application and
Python 3.14 rustworkx environment. The initial sandbox build exited 1 because
Nix daemon access was denied; rustworkx was then absent, while isolated
StrictDoc CLI imports passed. `build.log`, `resolve.log` and
`import-control.json` retain that initial failure and control. This was an
acquisition limitation, not a package incompatibility. The initial private
report copies remain excluded from publication.

The coordinator subsequently built that exact expression on the authorized host,
with one job, two cores and a 480-second timeout. `host-build.out`,
`host-build.log` and `host-execution.json` establish successful acquisition: 12
paths fetched, including rustworkx from the NixOS cache, and two environment/
closure derivations built. `host-probe-result.json` records all passing
assertions; `host-probe.log` is empty. This follow-up performed no build or
acquisition. `confirmation-result.json` records the matching read-only rerun.

Exact identities:

- Filtered toolchain:
  `/nix/store/121pk8i5nzhrpm34fv97f7mywin6k1r0-strictdoc-toolchain-source`.
- Supplied consumer revision: `8563ca852ae083609f97fb52a46c0b07272897ee`;
  portable batch: `2d28787d` (supplied provenance).
- StrictDoc upstream revision: `7cf8183498ec87be531499230602df33523ed058`.
- nixpkgs revision: `f13ff45afd1bb73e640eaa08a7066dbed07e3238`.
- Interpreter:
  `/nix/store/cck3q51nd32dpbmpkwv5xpkxxhpnr2ak-strictdoc-env/bin/python3.14`.
- Python base: `/nix/store/gxzhl7aaiid7zp3y47jqqiq7zg5mqpwp-python3-3.14.6`.
- StrictDoc application:
  `/nix/store/qc5w0rnlr2pl8zvaaq5gi6jfhm7h50im-strictdoc`.
- rustworkx:
  `/nix/store/zlwbwsaaihzsvmiyyl2yspb368n1m9hz-python3.14-rustworkx-0.17.1`.
- Combined closure:
  `/nix/store/6cy53r1c3lj260drvpz6g82dqr1wq405-gate2-runtime-probe-closure`.

`result.json` contains locked revisions/NAR hashes, lock SHA-256 values, source
and derivation paths, package source/vendor/patch identities, and actual module
paths. `locked-sources.json` records resolved upstream source paths.

The executed probe imports StrictDoc, its CLI dependencies and rustworkx in one
process, with exact version assertions. Synthetic Python tuples B Parent A and A
Child B normalize to one A→B edge; B Child C adds B→C. rustworkx confirms an
acyclic graph and path A→B→C, rejects reverse and isolated-node reachability,
and detects a cycle after adding C→A. **Normalization is probe code, not native
StrictDoc parsing or validation.** No StrictDoc document was parsed or
validated. User site packages and bytecode writes were disabled in the combined
executions.

To replay without acquisition, from the supplied workspace run:

```sh
bash outputs/run-probe.sh /nix/store/6cy53r1c3lj260drvpz6g82dqr1wq405-gate2-runtime-probe-closure
```

The runner prints probe JSON. With no argument it requests the same closure
using `--max-jobs 1 --cores 2`, a 475-second timeout and 5-second termination
grace; build logs go to `outputs/replay-build.*` to preserve existing evidence.
The no-argument build branch was not rerun in this follow-up. Both modes read
the StrictDoc executable's shebang to select its interpreter and set the closure
site-packages path. The expression and Python probe remain unchanged. Replay
requires the supplied immutable filtered toolchain source at the listed path and
its locked dependencies; the publication files are not a standalone source
archive. Python and shell syntax, Nix parsing, and requested treefmt formatting
are recorded in `validation.log`.

This qualifies only this x86_64-linux pairing and temporary combined search-path
arrangement. Production packaging, native parser/validator integration, other
platforms, performance and earlier timings remain unqualified. The research
3.13.15 / 0.18.1 pairing was not run. No Scribe daemon or fixture was accessed,
and no Scribe refusal/reload claim, Git operation, delegate or new gate follows.

Publication allowlist (exclude all other files, including empty logs,
intermediate resolution/format noise, initial private report copies and all
build/download products):

- `outputs/qualification.md`
- `outputs/result.json`
- `outputs/progress.json`
- `outputs/identities.json`
- `outputs/locked-sources.json`
- `outputs/probe.nix`
- `outputs/probe.py`
- `outputs/run-probe.sh`
- `outputs/host-build.out`
- `outputs/host-build.log`
- `outputs/host-execution.json`
- `outputs/host-probe-result.json`
- `outputs/confirmation-result.json`
- `outputs/build.log`
- `outputs/resolve.log`
- `outputs/import-control.json`
- `outputs/validation.log`
- `treefmt.toml`
