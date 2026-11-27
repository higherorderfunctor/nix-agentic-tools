# Named cases for ./test.nix. `CASES` is prepended by test.nix: the path of a
# JSON file naming the user, the identity and each generation's activation
# package. Every case runs even when an earlier one fails; the test fails
# at the end if any did, listing them.
import json
import shlex
from typing import Callable, Iterable

with open(CASES) as handle:
    FIXTURE = json.load(handle)

USER: str = FIXTURE["user"]
UID: int = FIXTURE["uid"]
GENERATIONS: dict[str, str] = FIXTURE["generations"]
# Expected values are independent of the fixture's daemon-to-secret wiring.
BASE_READERS = {"aa-reader": "aa-base", "zz-reader": "zz-base"}
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
    status, output = machine.execute(as_user(f"{GENERATIONS[name]}/activate"))
    print(f"--- activate {name}: exit {status}\n{output}--- end activate {name}")
    return status, output


def prop(unit: str, name: str) -> str:
    return machine.succeed(f"{CTL} show --property={name} --value {unit}").strip()


def main_pids(daemons: Iterable[str]) -> dict[str, str]:
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


def seen(daemon: str, after: str) -> list[str]:
    # The whole quoted value: split() would also break on Unicode spaces that
    # %q leaves printable, letting a wrong value match its first token.
    return [line.removeprefix("saw ") for line in journal(daemon, after).split("\n") if line.startswith("saw ")]


def wait_settled() -> None:
    idle = f'jobs="$({CTL} list-jobs --no-legend)" && test -z "$jobs"'
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


def settle_base() -> None:
    # A known start for each case whatever the previous case left: the first
    # activation absorbs it, the second must succeed, and each daemon is then
    # restarted on purpose.
    activate("base")
    check(activate("base")[0] == 0, "settling on base: activation failed")
    mark = cursor()
    machine.succeed(f"{CTL} restart " + " ".join(f"{daemon}.service" for daemon in BASE_READERS))
    wait_settled()
    for daemon, value in BASE_READERS.items():
        last = seen(daemon, mark)[-1:]
        check(last == [value], f"settling on base: {daemon} saw {last}, want {[value]}")


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
    for daemon, value in BASE_READERS.items():
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


def case_reader_switch(generation: str, expected: dict[str, list[str]]) -> None:
    settle_base()
    before = main_pids(expected)
    missing = [daemon for daemon, pid in before.items() if pid == "0"]
    check(not missing, f"before switching to {generation}, readers without a MainPID: {missing}")
    mark = switch(generation)
    after = main_pids(expected)
    problems = []
    for daemon, wanted in expected.items():
        lines = seen(daemon, mark)
        if lines != wanted:
            problems.append(f"{daemon} saw {lines}, want {wanted}")
        if wanted and after[daemon] in ("0", before[daemon]):
            problems.append(f"{daemon} MainPID is {after[daemon]}, want a new process after {before[daemon]}")
        if not wanted and after[daemon] != before[daemon]:
            problems.append(f"{daemon} MainPID moved {before[daemon]} -> {after[daemon]}")
    check(not problems, "; ".join(problems))


def case_new_secret() -> None:
    settle_base()
    mark = switch("fresh")
    value = "fresh-new"
    restarts = prop("aa-fresh.service", "NRestarts")
    lines = seen("aa-fresh", mark)
    check(
        restarts == "0" and lines == [value],
        f"aa-fresh restarted {restarts} times and saw {lines}, want one start that saw {[value]}; journal:\n"
        + journal("aa-fresh", mark),
    )


def case_stopped_daemon() -> None:
    # sd-switch starts a stopped unit that an active target wants, on every
    # switch; that is its behavior, not ai-module's. What ai-module owns: the
    # activation starts the reader at most once, and it ends on the new value.
    settle_base()
    machine.succeed(f"{CTL} stop zz-reader.service")
    mark = switch("rotate-zz")
    state = prop("zz-reader.service", "ActiveState")
    lines = seen("zz-reader", mark)
    rotated = "zz-rotated"
    check(
        state == "active" and lines == [rotated],
        f"the stopped zz-reader is {state} and saw {lines}, want one start that saw {[rotated]} and left it active",
    )


def case_systemctl_path() -> None:
    # Calls only ai-module's step makes: Home Manager's own reload runs
    # is-system-running, and sd-switch talks D-Bus.
    settle_base()
    machine.succeed(as_user(': > "$HOME/systemctl-calls"'))
    check(activate("systemctl-path")[0] == 0, "activating systemctl-path failed")
    calls = machine.succeed(as_user('cat "$HOME/systemctl-calls"')).splitlines()
    wanted = [
        "--user show --property=Result --value sops-nix.service",
        "--user show --property=ActiveState --value aa-reader.service",
    ]
    missing = [call for call in wanted if call not in calls]
    check(not missing, f"ai-module bypassed systemd.user.systemctlPath for {missing}; the wrapper logged {calls}")


def case_decrypt_failure() -> None:
    # In the pinned order sops-nix's own step succeeds, so only ai-module's
    # provider check can fail this activation.
    settle_base()
    status, output = activate("broken")
    result = prop("sops-nix.service", "Result")
    check(status != 0, f"activation with an unreadable secrets file exited 0 (sops-nix.service Result={result})")
    check(result == "exit-code", f"sops-nix.service Result={result}, want exit-code for the foreign key")
    message = "ai.services: secret provider sops-nix.service last ran with Result=exit-code"
    check(message in output.splitlines(), f"activation failed without {message!r}")


# login-order needs the first user-manager start of the boot. decrypt-failure
# runs last because it leaves an unreadable sops-nix unit loaded.
CASE_LIST: list[tuple[str, Callable[[], None]]] = [
    ("login-order", case_login_order),
    ("noop-activation", lambda: case_reader_switch("base", {"aa-reader": [], "zz-reader": []})),
    ("rotate-one", lambda: case_reader_switch("rotate-aa", {"aa-reader": ["aa-rotated"], "zz-reader": []})),
    (
        "unit-and-secret-change",
        lambda: case_reader_switch("changed", {"aa-reader": ["aa-changed"], "zz-reader": ["zz-changed"]}),
    ),
    ("new-secret", case_new_secret),
    ("stopped-daemon", case_stopped_daemon),
    ("systemctl-path", case_systemctl_path),
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
