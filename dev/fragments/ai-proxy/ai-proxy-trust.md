## Intercepting Proxy Trust

> **Last verified:** 2026-11-06 — registry selection and managed launcher
> delivery compose native or ambient CA files before direct exec; the helper
> reads the CA in the runtime directory `airlock ca directory` resolves;
> settings env omits the native-only CA path when the launcher delivers trust.

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
not that runtime delivers CA trust. Airlock resolves the instance's runtime
directory at launch as `airlock ca init` does and refuses launch if `ca.key`
there is missing or inaccessible, including when the service is stopped or uses
a different `XDG_RUNTIME_DIR`. The mask and the helper get that directory from
`airlock ca directory`, so under `AIRLOCK_HOME` they read it through the
canonical path Airlock checks and refuse what init refuses, and a symlink
swapped after init cannot redirect them. The existing file-mask combinator hides
that key from direct file reads. No selected helper or no jail means no
automatic mask. This mount mask does not isolate same-user IPC, such as the user
systemd manager, which can start processes outside the jail. Without the jail,
same-user processes can read the private key directly; a separate service uid is
future work.

Airlock's helper refuses a missing CA, so start the service before Claude. It
reads `ca.pem` in the instance's runtime directory:
`$XDG_RUNTIME_DIR/airlock/<name>` on Home Manager,
`$AIRLOCK_HOME/runtime/<name>` with the devenv service's `AIRLOCK_HOME`. With no
inherited file it returns that path directly. Otherwise it writes a temporary
bundle, then renames it to `<sha256 of inputs>.pem` beside `ca.pem`. Bundles are
reused across launches and kept as long as the runtime directory; their count is
bounded by distinct input contents. Opaque instances register no helper and
change no CA trust.

### Evidence and limits

- `lib/ai/proxy.nix` (`resolveTrust`) retains trust for the effective HTTPS
  origin or its HTTP fallback.
- `packages/airlock/lib/trust.nix` asks `airlock ca directory` for the
  instance's runtime directory with the service's base, so its refusals are the
  Rust resolver's, and refuses a missing certificate. It composes reusable
  bundles under `umask 077` with a temporary file and atomic rename, without
  supervising the client.
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
  behind a FIFO barrier, reuse across launches, identical launcher/command PIDs,
  unchanged exit and signal status, inherited descriptors, refusal without
  `XDG_RUNTIME_DIR` and missing-CA refusal with a mock Claude. Its devenv
  runtime root is the shared `/tmp`, so the devenv intercepting service is
  checked to refuse it, and its client and jail to refuse that directory, empty
  or holding a CA planted there. CI checks jail masks structurally and runs
  missing-key refusals before bubblewrap; its build sandbox cannot run the real
  jail. The hand-run `airlock-instance-jail-live` executable requires real
  jailed probes against the generated service's CA, using Claude's installed
  jailed launcher (also with a native CA override) and a Codex-profile test
  command, not Codex's installed launcher. No structural fallback is allowed in
  the live run. These fixtures do not establish Bun's TLS trust behavior.
