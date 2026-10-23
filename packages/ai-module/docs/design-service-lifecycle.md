# Service lifecycle and resource claims

> **Last verified:** 2026-10-22 — split from DESIGN.md without changing the
> generic file, activation or service contracts.

### Start limit

A daemon that fails within about 55 s of each start ends failed, so alerts on a
failed unit fire; an instant crash loop ends failed after 25 s. Restarts are
`RestartSec = 5` apart, and systemd's default `StartLimitIntervalSec=10s` and
`StartLimitBurst=5` can never trip: the sixth start of an instant crash loop
lands 5 x 5 = 25 s after the first, and a 10 s window holds at most three
starts. The unit then stays in `activating (auto-restart)` for good.
`restartPolicy` in `lib/services.nix` is the one definition: five starts in 300
s. A daemon that lives longer than about 55 s per start (5 x (55 + 5) = 300 s)
never trips it. The trade-off: a start-time dependency absent for longer than
about 25 s, such as a keyring or the network at login, is now terminal where the
unit used to retry for good. Recover with `systemctl --user reset-failed <unit>`
and a start; the same command clears a trip that would refuse a fix-and-switch
inside the 300 s interval, because the start limit also applies to manual starts
and survives `daemon-reload`. The limit applies to every `restart` value,
including `always`, and to every service; no consumer needs to tune it, so there
is no option. Add one when a named consumer does.

Devenv's native supervisor applies the same limit as `restart.max = 4` and
`restart.window = 300`: it counts restarts after the first start in a sliding
window, so five starts in 300 s.

#### Recipe: a desktop notification when a service fails

This is a personal recipe, not a module default and not an option. Home Manager
only: devenv has no systemd, and its supervisor has no `OnFailure=`. A Home
Manager `ai.services.<name>` entry becomes the user unit `<name>.service`, and
`systemd.user.services.<name>` is an ordinary Home Manager attribute that merges
with the generated definition, so a consumer adds `Unit.OnFailure` without
touching the module. systemd then requests the templated unit on failure, with
the failing unit's name as the instance `%i`.

```nix
{pkgs, ...}: {
  systemd.user.services = {
    # Replace cliproxyapi with the ai.services key.
    cliproxyapi.Unit.OnFailure = ["notify-failure@%n.service"];

    "notify-failure@" = {
      Service = {
        ExecStart = "${pkgs.libnotify}/bin/notify-send --urgency=critical --app-name=systemd 'Service failed' '%i failed; see journalctl --user -u %i'";
        Type = "oneshot";
      };
      Unit.Description = "Notify that %i failed";
    };
  };
}
```

`notify-send` needs a reachable user session bus and a running desktop
notification server; a headless session may have neither, and the notification
is lost. With the default `RestartMode=normal`, each failure before an automatic
restart passes through the failed state and triggers `OnFailure=`, as does the
terminal start-limit failure. It does not fire for a stop. A consumer who wants
a notification only when systemd gives up can also set
`Service.RestartMode = "direct"` on that unit (systemd 254+), which skips
`OnFailure=` for failures followed by an automatic restart
(`systemd.service(5)`, `RestartMode=`). After the unit gives up, recover with
`systemctl --user reset-failed <unit>` as above.

Home Manager Linux reserves `services-reconcile`. The Home Manager launcher of a
service with triggers hashes every trigger path and its bytes before it reads
any secret, so a file replaced during a start leaves the stamp older than the
daemon, never newer; a missing trigger fails the start. Immediately before exec
it writes the digest and its `INVOCATION_ID` to
`$XDG_RUNTIME_DIR/ai-service-<key>.stamp`. The devenv launcher writes no stamp.

One generated activation entry runs after `files`, `secrets` and
`reloadSystemd`, so it sees the units sd-switch started and the provider run
sd-switch caused, and calls `systemd.user.systemctlPath`. Activation fails when
a loaded provider unit's last `Result` is not `success`, or a reader is `failed`
or in `auto-restart`. The entry waits for each active reader's running
invocation to stamp, then one `try-restart` restarts every reader whose stamp
differs from the trigger files now or that did not stamp in time; each must come
back with a matching stamp, or activation fails naming it. Each of the two
passes shares one 90-second deadline, room for a secret command that waits on a
person, so the entry waits at most 180 seconds, under the 5-minute start timeout
of Home Manager's NixOS unit. A match proves the reader read every secret and
reached exec, not that it stays up; a reader that then crash-loops is refused by
the next activation. A stopped reader stays stopped, although sd-switch itself
starts a stopped unit an active target wants. A no-op activation, and a re-key
that leaves the decrypted bytes alone, restart nothing.

The entry acts only while the user manager reports `running` or `degraded`, the
test Home Manager's own reload uses. `starting` and `stopping` skip with a
message, since `user@<uid>.service` turns `active` before its manager finishes
starting. For any other answer, or none, it fails activation only when the
system manager reports `user@<uid>.service` `active`; every other state skips
with a message naming it, including a failed query on a host whose init is not
systemd. The two backends differ: Home Manager compares content after each
switch, devenv's `watch.paths` restarts live on any change and accepts
directories.

Exclusive resources share `ai.claims.<group>.<key>`, a hidden registry of owner
lists validated once in `modules/common.nix`. Runtime helpers register
non-shared paths in `path`, service names in `service` and decimal ports in
`port`. Other resources use `ai.<owner>.claims.<group> = [keys]`. Port owners
are `<owner>:<service>.ports.<name>`. A list with more than one owner fails with
`ai.claims.<group>.<key>: claimed by <a> and <b>`, sorted by owner. Adding a
resource group needs no new validation code; owners register resources and never
assert uniqueness. The internal shared owner accepts scoped service claims for
proxies (`proxy:root`, `proxy:<runtime>`), so identical proxy declarations fail
the shared ownership assertion at the native assertion boundary.
