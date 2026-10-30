## Intercepting Proxy Trust

> **Last verified:** 2026-10-30 — registry selection and managed launcher
> delivery are implemented; Bun's CA-read timing relative to settings `env` is
> unverified.

The optional registry `trust` field is an executable package, not a CA path:
when run, it prints the PEM bundle path a client should trust, appending the
instance CA to an optional inherited bundle argument. This lets an owner locate
its runtime CA without teaching runtime code about that owner. Trust follows
only a selected instance whose non-null protocol origin survives resolution;
replacing both protocol origins or opting out drops it. Selecting another
instance uses that instance's helper, if any. See [Network Proxy](ai-proxy.md)
for protocol resolution.

Claude's managed launcher sets `NODE_EXTRA_CA_CERTS` before its Bun single-exec
starts. A non-null `ai.claude.native.settings.env.NODE_EXTRA_CA_CERTS` wins and
is passed at startup instead of invoking the helper. Otherwise the helper
preserves an ambient extra-CA file by appending the instance CA. No generated CA
value is written to settings. With `package = null`, a warning explains the
manual startup setting. Other enabled runtimes selecting an intercepting
instance warn by name that TLS through it will fail without independently
configured trust, including runtimes lacking proxy delivery; they receive no CA.

Airlock's helper refuses a missing CA, so start the service before Claude. It
keeps composed bundles private and publishes them atomically beside the runtime
CA. Opaque instances register no helper and change no CA trust.

### Evidence and limits

- `lib/ai/proxy.nix` (`resolveTrust`) retains the selected helper only when an
  effective non-null protocol origin matches its registry entry.
- `packages/airlock/lib/trust.nix` checks the CA before returning its path and
  composes an inherited bundle with `umask 077` and an atomic rename.
- `packages/claude-code/lib/mkClaude.nix` (`installPackage`) supplies the native
  extra-CA value or runs the helper before exec. Its warning covers a null
  package; `lib/ai/app/mkBackendTransform.nix` exempts Claude by name from the
  warning for other runtimes. Revisit that exemption when another runtime
  delivers trust.
- **UNVERIFIED:** Bun's `NODE_EXTRA_CA_CERTS` read before Claude applies
  settings `env`. The package recipe identifies a Bun single-exec; the proxy
  fragment's dispatcher evidence proves proxy-variable ordering, not CA
  initialization. Matching Bun source or a pinned-binary call trace locating
  both operations would settle the timing. The launcher supplies the value
  before either.
- `packages/airlock/checks/airlock-instances.nix` checks selection, opt-outs,
  warnings and native precedence on both backends.
  `packages/airlock/checks/airlock-instance-runtime.py` checks bundle contents,
  permissions and missing-CA refusal with a mock Claude; it does not establish
  Bun's TLS trust behavior.
