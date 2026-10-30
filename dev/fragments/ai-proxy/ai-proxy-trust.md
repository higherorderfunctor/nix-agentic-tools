## Intercepting Proxy Trust

> **Last verified:** 2026-10-30 — registry selection and managed launcher
> delivery are implemented; Bun's CA-read timing relative to settings `env` is
> unverified.

The optional registry `trust` field is an executable package: it takes an
inherited PEM bundle argument (empty for none), then the client command and its
arguments. It starts that command with the composed extra-CA bundle and removes
the temporary bundle on exit. This lets an owner locate its runtime CA without
teaching runtime code about that owner. Trust follows the selected instance when
its HTTPS origin survives resolution, or when HTTPS is null and its HTTP origin
survives as the fallback. An external HTTPS origin drops trust even if HTTP
still uses the instance. Selecting another instance uses that instance's helper,
if any. See [Network Proxy](ai-proxy.md) for protocol resolution.

Claude's managed launcher supplies `NODE_EXTRA_CA_CERTS` before its Bun
single-exec starts. The helper appends Airlock's CA to the native
`ai.claude.native.settings.env.NODE_EXTRA_CA_CERTS` when set, otherwise to the
ambient extra-CA file. No generated CA value is written to settings. With
`package = null`, a warning explains the manual startup setting. A runtime
record declares CA delivery with `surfaceSupport.proxy.trust = true`; other
enabled runtimes selecting an intercepting instance warn that TLS through it
will fail without independently configured trust, including runtimes lacking
proxy delivery.

A trust helper can expose `passthru.jailPermissions`, a function from the
jail.nix combinators to permissions. The shared selection lowering adds these to
every enabled runtime jail, before the caller's final permissions, whether or
not that runtime delivers CA trust. Airlock uses the service's runtime-directory
helper at launch and refuses launch if `ca/ca.key` is missing, including when
the service is stopped or uses a different `XDG_RUNTIME_DIR` or fallback
`TMPDIR`. The existing file-mask combinator hides that key from direct file
reads. The helper reads the published certificate outside the private service
directory. No selected helper or no jail means no automatic mask. This mount
mask does not isolate same-user IPC, such as the user systemd manager, which can
start processes outside the jail. Without the jail, same-user processes can read
the private key directly; a separate service uid is future work.

Airlock's helper refuses a missing CA, so start the service before Claude. The
service publishes only `ca.pem` atomically in a sibling `.trust` directory,
created with the service runtime directory's ownership rules. The helper reads
only that copy. Each launch composes its bundle in its own private directory
under the client runtime root; exit and forwarded INT/TERM remove it. Opaque
instances register no helper and change no CA trust.

### Evidence and limits

- `lib/ai/proxy.nix` (`resolveTrust`) retains trust for the effective HTTPS
  origin or its HTTP fallback.
- `packages/airlock/lib/trust.nix` publishes only the certificate and refuses
  missing or foreign-owned publication paths. `client-trust.py` composes the
  bundle under `umask 077`, forwards INT/TERM, preserves the command's exit
  status and cleans up its temporary directory.
- `packages/claude-code/lib/mkClaude.nix` (`installPackage`) supplies the native
  or ambient extra-CA argument and composes the helper with inference flags
  through `lib.ai.mkLauncher`'s command prefix. Its warning covers a null
  package; `lib/ai/app/mkBackendTransform.nix` reads the record's trust
  capability for other runtimes' warnings.
- **UNVERIFIED:** Bun's `NODE_EXTRA_CA_CERTS` read before Claude applies
  settings `env`. The package recipe identifies a Bun single-exec; the proxy
  fragment's dispatcher evidence proves proxy-variable ordering, not CA
  initialization. Matching Bun source or a pinned-binary call trace locating
  both operations would settle the timing. The launcher supplies the value
  before either.
- `packages/airlock/checks/airlock-instances.nix` checks selection, opt-outs,
  warnings and HTTPS retention on both backends.
  `packages/airlock/checks/airlock-instance-runtime.py` checks bundle contents,
  permissions, native and ambient composition, concurrent lifetime, exit and
  signal cleanup, inaccessible private service directories and missing-CA
  refusal with a mock Claude. CI checks jail masks structurally and runs
  missing-key refusals before bubblewrap; its build sandbox cannot run the real
  jail. The hand-run `airlock-instance-jail-live` executable requires real
  jailed probes against the generated service's CA, using Claude's installed
  jailed launcher (also with a native CA override) and a Codex-profile test
  command, not Codex's installed launcher. No structural fallback is allowed in
  the live run. These fixtures do not establish Bun's TLS trust behavior.
