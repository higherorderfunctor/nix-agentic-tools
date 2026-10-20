# Named cases for ./test.nix. `CASES` is prepended by test.nix: the path of a
# JSON file naming the user, the identity and each generation's activation
# package and expected values. Every case runs even when an earlier one
# fails; the test fails at the end if any did, listing them.
import json
import shlex
from typing import Callable

with open(CASES) as handle:
    FIXTURE = json.load(handle)

USER: str = FIXTURE["user"]
UID: int = FIXTURE["uid"]
GENERATIONS: dict = FIXTURE["generations"]
CTL = f"systemctl --user -M {USER}@.host"
# Longer than the RestartSec = 5 that ai.services writes, so a daemon that
# crashed and is waiting to retry has retried before a case reads its state.
RETRY_WINDOW = 7


class CaseFailure(Exception):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise CaseFailure(message)


def as_user(command: str) -> str:
    # runuser opens no logind session, so it never starts the user manager:
    # login-order needs the manager to start only when the case starts it.
    env = f"HOME={shlex.quote(FIXTURE['home'])} LOGNAME={USER} PATH=/run/current-system/sw/bin USER={USER} XDG_RUNTIME_DIR=/run/user/{UID}"
    return f"runuser -u {USER} -- env -i {env} /bin/sh -c {shlex.quote(command)} 2>&1"


def activate(name: str) -> tuple[int, str]:
    status, output = machine.execute(as_user(f"{GENERATIONS[name]['path']}/activate"))
    print(f"--- activate {name}: exit {status}\n{output}--- end activate {name}")
    return status, output


def prop(unit: str, name: str) -> str:
    return machine.succeed(f"{CTL} show --property={name} --value {unit}").strip()


def main_pids(daemons: list) -> dict:
    return {daemon: prop(f"{daemon}.service", "MainPID") for daemon in daemons}


def cursor() -> str:
    output = machine.succeed("journalctl --sync && journalctl --lines=1 --show-cursor --quiet")
    return output.strip().splitlines()[-1].removeprefix("-- cursor: ")


def journal(daemon: str, after: str) -> str:
    # The daemon's own output, then the user manager's messages about it.
    return machine.succeed(
        "journalctl --sync && journalctl --output=cat "
        + f"--after-cursor={shlex.quote(after)} "
        + f"_SYSTEMD_USER_UNIT={daemon}.service + USER_UNIT={daemon}.service"
    )


def seen(daemon: str, after: str) -> list:
    # The whole quoted value: split() would also break on Unicode spaces that
    # %q leaves printable, letting a wrong value match its first token.
    return [line.removeprefix("saw ") for line in journal(daemon, after).split("\n") if line.startswith("saw ")]


def wait_settled() -> None:
    idle = f'test -z "$({CTL} list-jobs --no-legend)"'
    machine.wait_until_succeeds(idle, timeout=120)
    machine.sleep(RETRY_WINDOW)
    machine.wait_until_succeeds(idle, timeout=120)


def switch(name: str) -> str:
    # Activates name, waits for the manager to settle and returns the cursor
    # taken just before the activation.
    mark = cursor()
    check(activate(name)[0] == 0, f"activating {name} failed")
    wait_settled()
    return mark


def settle(name: str) -> None:
    # A known start for each case whatever the previous case left: the first
    # activation may be the one a lagging rotation check acts late on, the
    # second must succeed, and each daemon is then restarted on purpose.
    activate(name)
    check(activate(name)[0] == 0, f"settling on {name}: activation failed")
    readers: dict = GENERATIONS[name]["readers"]
    mark = cursor()
    machine.succeed(f"{CTL} restart " + " ".join(f"{daemon}.service" for daemon in readers))
    wait_settled()
    for daemon, value in readers.items():
        last = seen(daemon, mark)[-1:]
        check(last == [value], f"settling on {name}: {daemon} saw {last}, want {[value]}")


def case_login_order() -> None:
    status, _ = machine.execute(f"systemctl is-active --quiet user@{UID}.service")
    check(status != 0, "precondition: the user manager was already running")
    check(activate("base")[0] == 0, "activating base before login failed")
    mark = cursor()
    machine.succeed(f"systemctl start user@{UID}.service")
    machine.wait_until_succeeds(f"{CTL} is-system-running | grep -Eqx 'running|degraded'", timeout=120)
    wait_settled()
    decrypted = int(prop("sops-nix.service", "ExecMainExitTimestampMonotonic"))
    check(decrypted > 0, "sops-nix.service never finished")
    problems = []
    for daemon, value in GENERATIONS["base"]["readers"].items():
        started = int(prop(f"{daemon}.service", "ExecMainStartTimestampMonotonic"))
        restarts = prop(f"{daemon}.service", "NRestarts")
        first = seen(daemon, mark)[:1]
        if started < decrypted:
            problems.append(f"{daemon} started {decrypted - started} us before sops-nix finished")
        if restarts != "0":
            problems.append(f"{daemon} restarted {restarts} times")
        if first != [value]:
            problems.append(f"{daemon} first saw {first}, want {[value]}")
    check(not problems, "; ".join(problems))


def case_rotate_one() -> None:
    settle("base")
    before = main_pids(["aa-reader", "zz-reader"])
    mark = switch("rotate-aa")
    after = main_pids(["aa-reader", "zz-reader"])
    rotated = GENERATIONS["rotate-aa"]["readers"]["aa-reader"]
    problems = []
    aa = seen("aa-reader", mark)
    if aa != [rotated]:
        problems.append(f"aa-reader saw {aa} after the rotation, want exactly {[rotated]}")
    if after["aa-reader"] == before["aa-reader"]:
        problems.append(f"aa-reader kept MainPID {before['aa-reader']}")
    if after["zz-reader"] != before["zz-reader"]:
        problems.append(f"zz-reader MainPID moved {before['zz-reader']} -> {after['zz-reader']}")
    zz = seen("zz-reader", mark)
    if zz:
        problems.append(f"zz-reader restarted and saw {zz}")
    check(not problems, "; ".join(problems))


def case_noop_activation() -> None:
    settle("base")
    daemons = list(GENERATIONS["base"]["readers"])
    before = main_pids(daemons)
    mark = switch("base")
    after = main_pids(daemons)
    problems = [f"{daemon} MainPID moved {before[daemon]} -> {after[daemon]}" for daemon in daemons if before[daemon] != after[daemon]]
    problems += [f"{daemon} saw {seen(daemon, mark)}" for daemon in daemons if seen(daemon, mark)]
    check(not problems, "; ".join(problems))


def case_unit_and_secret_change() -> None:
    settle("base")
    mark = switch("changed")
    problems = []
    for daemon, value in GENERATIONS["changed"]["readers"].items():
        lines = seen(daemon, mark)
        if lines != [value]:
            problems.append(f"{daemon} saw {lines}, want exactly one start that saw {[value]}")
    check(not problems, "; ".join(problems))


def case_new_secret() -> None:
    settle("base")
    mark = switch("fresh")
    value = GENERATIONS["fresh"]["readers"]["aa-fresh"]
    restarts = prop("aa-fresh.service", "NRestarts")
    lines = seen("aa-fresh", mark)
    check(
        restarts == "0" and lines == [value],
        f"aa-fresh restarted {restarts} times and saw {lines}, want one start that saw {[value]}; journal:\n"
        + journal("aa-fresh", mark),
    )


def case_stopped_daemon() -> None:
    settle("base")
    machine.succeed(f"{CTL} stop zz-reader.service")
    mark = cursor()
    # Twice: the second activation is where a rotation noticed late acts.
    for attempt in (1, 2):
        check(activate("rotate-zz")[0] == 0, f"activating rotate-zz (attempt {attempt}) failed")
        wait_settled()
    state = prop("zz-reader.service", "ActiveState")
    lines = seen("zz-reader", mark)
    check(state == "inactive" and not lines, f"the stopped zz-reader is {state} and saw {lines}")


def case_decrypt_failure() -> None:
    # In the pinned order sops-nix's own step succeeds, so only ai-module's
    # provider check can fail this activation.
    settle("base")
    status, output = activate("broken")
    result = prop("sops-nix.service", "Result")
    check(status != 0, f"activation with an unreadable secrets file exited 0 (sops-nix.service Result={result})")
    message = "ai.services: secret provider sops-nix.service last ran with Result="
    check(message in output, f"activation failed without {message!r} (sops-nix.service Result={result})")


# login-order needs the first user-manager start of the boot. decrypt-failure
# runs last because it leaves an unreadable sops-nix unit loaded.
CASE_LIST: list[tuple[str, Callable[[], None]]] = [
    ("login-order", case_login_order),
    ("rotate-one", case_rotate_one),
    ("noop-activation", case_noop_activation),
    ("unit-and-secret-change", case_unit_and_secret_change),
    ("new-secret", case_new_secret),
    ("stopped-daemon", case_stopped_daemon),
    ("decrypt-failure", case_decrypt_failure),
]

start_all()
machine.wait_for_unit("multi-user.target")
machine.succeed(as_user(f"install -D -m 0600 {FIXTURE['identity']} {shlex.quote(FIXTURE['keyFile'])}"))

failed = []
for name, run in CASE_LIST:
    try:
        run()
    except Exception as error:
        failed.append(name)
        print(f"CASE {name}: FAIL: {error}")
    else:
        print(f"CASE {name}: PASS")

print("CASE SUMMARY: " + ", ".join(f"{name}={'FAIL' if name in failed else 'PASS'}" for name, _ in CASE_LIST))
if failed:
    raise Exception("failed cases: " + ", ".join(failed))
