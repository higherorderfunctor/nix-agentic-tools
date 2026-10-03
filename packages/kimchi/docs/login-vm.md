# Kimchi login microVM

> **Last verified:** 2026-10-03 — standalone QEMU runner for a non-NixOS host.

Run `nix run .#kimchi-login-vm` on x86_64 Linux with access to `/dev/kvm`. The
serial console logs in as the unprivileged `tester` user. Kimchi is on PATH.
Stop the VM with `sudo reboot`: the runner passes `-no-reboot`, so a guest
reboot exits QEMU, while a guest poweroff leaves QEMU hanging. The console is a
plain stdio chardev with no QEMU mux, so Ctrl-a x and Ctrl-C reach the guest,
not QEMU. All writable guest state is tmpfs and disappears when the VM stops.

The package exports the guest's `microvm.declaredRunner`, not upstream's
`microvm` management CLI. That CLI requires the NixOS host module and
`/var/lib/microvms`; the declared runner also works on Ubuntu with Nix. QEMU's
built-in 9p serves the entire host `/nix/store` read-only (enforced host-side by
`readonly=true`), not just the guest's closure. No host home or credential
directory is shared.

User-mode networking forwards no inbound ports, so a browser on the host cannot
reach a login callback on the guest's loopback. Outbound is unrestricted and
includes every host service bound to `127.0.0.1`, reachable from the guest at
`10.0.2.2`. This is a disposable login test host, not a sandbox security API. No
Home Manager or devenv module configures it. The `platforms.nix` sibling omits
the package from Darwin before evaluating NixOS.

The update pipeline discovers the `microvm` input from `flake.lock`. Kimchi
keeps its existing package update target.
