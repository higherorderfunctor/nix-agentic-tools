# Sandbox inference

> **Last verified:** 2026-11-02 — client-key option inheritance, the inference
> door, per-launch key transport and the guest user configs, on Home Manager and
> devenv. The guest carries no consumer native Claude/Codex settings.

`ai.sandbox.inference.clientKey` names the VM-only client of the runtime's
selected proxy instance (`ai.<runtime>.settings.inference`). Null disables
sandbox inference; a selected instance with a null client never falls back to
the host client.

```nix
{inputs, ...}: let
  redact = inputs.nix-agentic-tools.lib.redact;
in {
  ai = {
    claude.enable = true;
    cliproxyapi.instances.main = {
      clientKeys = {
        desktop.key = redact.file "/run/secrets/cpa-desktop";
        sandbox.key = redact.file "/run/secrets/cpa-sandbox";
      };
      port = 8317;
    };
    sandbox = {enable = true; inference.clientKey = "sandbox";};
    settings.inference = {clientKey = "desktop"; instance = "main";};
  };
}
```

## Selection

Runtimes with a guest route mirror the option; a runtime value, including
`mkDefault`, replaces the root value, and nothing flows back up. The guest
selection reuses the runtime's selected instance and substitutes only the
client, so the VM client's routes and models resolve independently of the host
client's.

A requested client is refused when the selection is missing or disabled, the
client does not exist, or the runtime selected an external `url` instead of an
instance. Sandbox inference supports `cliproxyapi` instances only, and a client
that an enabled host harness also selects in the same evaluation is refused:
revoking a shared key would cut a host harness too. Give every guest one
dedicated client so a single revocation cuts them all. VM-only key provisioning
is an operator obligation; equal bytes behind different references are not
checked.

## What crosses the boundary

The guest config is exactly the owner lowering's output for the guest selection.
No consumer native Claude or Codex settings enter the guest: Claude gets a guest
`~/.claude/settings.json` (door URL, key-file helper, quiet defaults), Codex a
guest `~/.codex/config.toml` (provider table with command auth). No host config
file, login, environment wrapper or home directory is copied.

The client key is read on the host at launch through the shared inference key
helper, written to a 0600 file in the launcher's private runtime directory,
carried as a fw_cfg blob, and installed in the guest as
`/run/sandbox-inference/key`, mode 0400, owned by the sandbox user. It never
enters a Nix value, a store path, an argument vector or the kernel command line.
fw_cfg is guest-visible by design: the key is for the guest, not protected from
guest root. The guest file is a launch snapshot; rotation needs a relaunch, and
CPA-side revocation refuses subsequent authenticated requests.

## Door and launch refusal

Inference traffic crosses one factory door: guest port 8317 on the door address,
`socat` to the instance's native loopback port. The guest endpoint URL names the
door, not the host origin. No second NIC or other credential crosses with it.

The door is a plain TCP forward, so the guest reaches every route the instance
serves, not only `/v1`, and the instance sees each connection as coming from
localhost. The management API still requires `management.secret-key` on every
request, localhost included, and an empty key disables it; the guest does not
hold that key. The panel and OAuth callback routes are reachable. Filtering the
door by path is future work for the egress proxy.

Before QEMU starts, the launcher probes the instance's `/v1/models` with the
staged key, supplied to curl as a 0600 header file, never an argument. A
connection failure, timeout, rejected key or non-200 status refuses the launch,
naming the option, instance, client and port only. A key containing a line break
is refused first. The proxy is never auto-started and no other provider is
tried. With inference inactive there is no door, blob, probe or helper at all.
