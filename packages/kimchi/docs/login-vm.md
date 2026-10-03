# Kimchi login microVM

> **Last verified:** 2026-10-03 — standalone QEMU runner for a non-NixOS host.

Run `nix run .#kimchi-login-vm` on x86_64 Linux with access to `/dev/kvm`. The
serial console logs in as the unprivileged `tester` user. Kimchi is on PATH. Use
`exit` to end the shell; use QEMU's Ctrl-a x to stop the VM. All writable guest
state is tmpfs and disappears when the VM stops.

The package exports the guest's `microvm.declaredRunner`, not upstream's
`microvm` management CLI. That CLI requires the NixOS host module and
`/var/lib/microvms`; the declared runner also works on Ubuntu with Nix. QEMU's
built-in 9p serves the host store read-only without a separate virtiofsd
process. The runner shares no host home or credentials.

User-mode networking permits outbound connections and forwards no inbound ports.
A browser on the host cannot reach a login callback on the guest's loopback.
This is a disposable login test host, not a sandbox security API. No Home
Manager or devenv module configures it. The `platforms.nix` sibling omits the
package from Darwin before evaluating NixOS.

The update pipeline discovers the `microvm` input from `flake.lock`;
`passthru.updateFlakeInput` records that ownership for update coverage. Kimchi
continues to use its existing package update target.
