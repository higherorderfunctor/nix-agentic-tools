## Intercepting Proxy Trust

> **Last verified:** 2026-11-04 — registry selection and managed launcher
> delivery compose native or ambient CA files before direct exec; settings env
> omits the native-only CA path when the launcher delivers trust.

The optional registry `trust` field is an executable package: it takes an
inherited PEM bundle argument (empty for none) and prints the extra-CA file
path. The launcher exports that path, then uses `exec` to start the client
directly. This lets an owner locate its runtime CA without teaching runtime code
about that owner. Trust follows the selected instance when its HTTPS origin
survives resolution, or when HTTPS is null and its HTTP origin survives as the
fallback. An external HTTPS origin drops trust even if HTTP still uses the
instance. Selecting another instance uses that instance's helper, if any. See
[Network Proxy](ai-proxy.md) for protocol resolution.

Claude's managed launcher supplies `NODE_EXTRA_CA_CERTS` before its Bun
single-exec starts. The helper appends Airlock's CA to the native
`ai.claude.native.settings.env.NODE_EXTRA_CA_CERTS` when set, otherwise to the
ambient extra-CA file. When the managed launcher delivers trust, settings env
omits the native-only `NODE_EXTRA_CA_CERTS` so Claude cannot reset the composed
startup value. No generated CA value is written to settings. With
`package = null`, a warning explains the manual startup setting. A runtime
record declares CA delivery with `surfaceSupport.proxy.trust = true`; other
enabled runtimes selecting an intercepting instance warn that TLS through it
will fail without independently configured trust, including runtimes lacking
proxy delivery.

A trust helper can expose `passthru.jailPermissions`, a function from the
jail.nix combinators to permissions. The shared selection lowering adds these to
every enabled runtime jail, before the caller's final permissions, whether or
not that runtime delivers CA trust. Airlock uses the service's runtime-directory
helper at launch and refuses launch if `ca/ca.key` is missing or inaccessible,
including when the service is stopped or uses a different `XDG_RUNTIME_DIR` or
fallback `TMPDIR`. The existing file-mask combinator hides that key from direct
file reads. The helper reads the published certificate outside the private
service directory. The jailed launch still requires access to the private
directory to check and mask the key; a client denied that access must correct
permissions or use a separate service uid design. No selected helper or no jail
means no automatic mask. This mount mask does not isolate same-user IPC, such as
the user systemd manager, which can start processes outside the jail. Without
the jail, same-user processes can read the private key directly; a separate
service uid is future work.

Airlock's helper refuses a missing CA, so start the service before Claude. The
service publishes only `ca.pem` atomically in a sibling `.trust` directory,
created with the service runtime directory's ownership rules. The helper reads
only that copy. With no inherited file it returns that path directly. Otherwise
it writes a temporary bundle, then renames it to `<sha256 of inputs>.pem` in a
0700 `ai-service-airlock-trust` directory under `XDG_RUNTIME_DIR`, or
`ai-service-<uid>-airlock-trust` under the `TMPDIR`/`/tmp` fallback. The service
and client use the same directory-naming helper under the selected runtime root.
Bundles are reused across launches and kept until runtime storage is cleared;
their count is bounded by distinct input contents. Opaque instances register no
helper and change no CA trust.

### Evidence and limits

- `lib/ai/proxy.nix` (`resolveTrust`) retains trust for the effective HTTPS
  origin or its HTTP fallback.
- `packages/airlock/lib/trust.nix` publishes only the certificate and refuses
  missing or foreign-owned publication paths. It composes reusable bundles under
  `umask 077` with a temporary file and atomic rename, without supervising the
  client.
- `packages/claude-code/lib/mkClaude.nix` (`installPackage`) supplies the native
  or ambient extra-CA argument and composes the helper with inference flags
  through `lib.ai.mkLauncher`'s existing `--run` flags. Its warning covers a
  null package; `lib/ai/app/mkBackendTransform.nix` reads the record's trust
  capability for other runtimes' warnings.
- These checks use a mock Claude; they do not establish the pinned Bun binary's
  TLS trust behavior. The launcher supplies the composed value before startup
  and settings cannot replace it with the native-only path.
- `packages/airlock/checks/airlock-instances.nix` checks selection, opt-outs,
  warnings and HTTPS retention on both backends.
  `packages/airlock/checks/airlock-instance-runtime.py` checks bundle contents,
  permissions, native and ambient composition, overlapping bundle creation
  behind a FIFO barrier, reuse across launches, UID-qualified names in a shared
  sticky `TMPDIR`, identical launcher/command PIDs, unchanged exit and signal
  status, inherited descriptors, inaccessible private service directories and
  missing-CA refusal with a mock Claude. CI checks jail masks structurally and
  runs missing-key refusals before bubblewrap; its build sandbox cannot run the
  real jail. The hand-run `airlock-instance-jail-live` executable requires real
  jailed probes against the generated service's CA, using Claude's installed
  jailed launcher (also with a native CA override) and a Codex-profile test
  command, not Codex's installed launcher. No structural fallback is allowed in
  the live run. These fixtures do not establish Bun's TLS trust behavior.
