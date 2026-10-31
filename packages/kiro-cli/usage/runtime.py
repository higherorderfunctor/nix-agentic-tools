"""Start the private capture service and fail closed before a tracked launch."""
# cspell:words getpgrp tcgetpgrp

import argparse
import os
import re
import signal
import sqlite3
import subprocess
import time
import uuid
from contextlib import closing
from pathlib import Path
import shlex
import socket
import stat
import sys


PROXY_NAMES = (
    "ALL_PROXY", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "NODE_EXTRA_CA_CERTS",
    "all_proxy", "http_proxy", "https_proxy", "no_proxy",
)


USAGE = ("usage: kiro-usage {exec COMMAND [ARG ...]|index --sessions DIR|session ID [--scope tree] [--json]"
         "|report [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--session ID ...] [--json]|list|unpack ID MODE}")


class CommandError(Exception):
    """A ready collector could not execute the selected command."""


def state_directory(explicit):
    if explicit:
        path = Path(explicit)
    else:
        base = os.environ.get("XDG_STATE_HOME")
        path = Path(base) if base else Path(os.environ["HOME"]) / ".local/state"
        path /= "kiro-cli/usage"
    if not path.is_absolute() or path == Path("/"):
        raise ValueError("usage state directory must be an absolute non-root path")
    return path


def private_directory(path, create=False):
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise ValueError(f"usage directory must be owned by this user, not a symlink, and mode 0700: {path}")


def launch_environment(path, port, refuse_conflicts=True, invocation=None):
    private_directory(path)
    ca_dir = path / "ca"
    private_directory(ca_dir)
    cert = ca_dir / "mitmproxy-ca-cert.pem"
    info = cert.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size == 0:
        raise ValueError(f"usage CA must be a nonempty user-owned regular file: {cert}")
    # This only connects to the local listener. It sends no HTTP request and
    # cannot cause a provider call.
    with socket.create_connection(("127.0.0.1", port), timeout=0.5):
        pass
    invocation = invocation or os.environ.get("KIRO_USAGE_INVOCATION")
    if invocation and not re.fullmatch(r"[0-9a-f]{32}", invocation):
        raise ValueError("invalid KIRO_USAGE_INVOCATION marker")
    credentials = f"kiro-usage-{invocation}:@" if invocation else ""
    url = f"http://{credentials}127.0.0.1:{port}"
    values = {name: url for name in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy")}
    values["NODE_EXTRA_CA_CERTS"] = str(cert)
    if invocation:
        values["KIRO_USAGE_INVOCATION"] = invocation
    for name in PROXY_NAMES:
        value = os.environ.get(name, "")
        if refuse_conflicts and value and value != values.get(name):
            raise ValueError(f"inherited {name} conflicts with usage tracking; unset it for this Kiro launch")
    return {**{name: value for name, value in os.environ.items() if name not in PROXY_NAMES}, **values}


def environment(path, port):
    values = launch_environment(path, port)
    for name in ("ALL_PROXY", "NO_PROXY", "all_proxy", "no_proxy"):
        print(f"unset {name}")
    for name, value in sorted(values.items()):
        if name not in PROXY_NAMES:
            continue
        print(f"export {name}={shlex.quote(value)}")


def service(args, path):
    os.umask(0o077)
    private_directory(path, create=True)
    ca_dir = path / "ca"
    private_directory(ca_dir, create=True)
    # The proxy must never inherit the client-side proxy and loop into itself.
    for name in PROXY_NAMES:
        os.environ.pop(name, None)
    os.environ["KIRO_USAGE_DB"] = str(path / "usage.sqlite3")
    os.environ["KIRO_USAGE_WARN_BYTES"] = str(args.warn_bytes)
    os.execv(args.mitmdump, [
        args.mitmdump,
        "--listen-host", "127.0.0.1", "--listen-port", str(args.port),
        "--allow-hosts", r"^runtime\.us-east-1\.kiro\.dev:443$",
        "--set", f"confdir={ca_dir}",
        "--set", "flow_detail=0",
        "--set", "termlog_verbosity=error",
        "--set", "connection_strategy=lazy",
        "--scripts", args.addon,
    ])


def refresh_disk_index(path, since):
    """Read only sessions changed since the launch (UTC ns); others are only stat-checked. The run's exit summary
    reads no disk data: this keeps kiro-usage session and report --session, which do, current after a launch."""
    from capture import lock_beside, open_database
    from disk_index import INDEX_LOCK, REFRESH_LOCK, index_tree
    try:
        sessions = Path.home() / ".kiro/sessions"
        if not sessions.exists():
            return
        with closing(open_database(path / "usage.sqlite3")) as db:
            lock = lock_beside(path / "usage.sqlite3", INDEX_LOCK, shared=True)
            try:
                queue = lock_beside(path / "usage.sqlite3", REFRESH_LOCK, blocking=True)
                try:
                    index_tree(db, sessions, since)
                finally:
                    os.close(queue)
            finally:
                os.close(lock)
    except BlockingIOError:
        print("Warning: a full Kiro session index is running; disk observations were not refreshed (rerun kiro-usage index if it began before Kiro exited).", file=sys.stderr)
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"Warning: automatic Kiro session indexing failed: {error}; disk observations may be stale.", file=sys.stderr)


SETTLE_TIMEOUT = 2.0  # Seconds the exit path waits for the async writer to persist this invocation.


def invocation_captures(db, invocation, timeout):
    """(rows, settled): this invocation's (RUN_ROOT, state) marker rows, and whether they went quiet and finished
    before the deadline."""
    from query import RUN_ROOT
    deadline = time.monotonic() + timeout
    previous_rows, settled = None, time.monotonic()
    while True:
        rows = db.execute(f"SELECT {RUN_ROOT},state FROM captures c WHERE json_extract(c.metadata_json,'$.invocation')=?",
                          (invocation,)).fetchall()
        if rows != previous_rows:
            previous_rows, settled = rows, time.monotonic()
        if rows and all(state != "recording" for _, state in rows) and time.monotonic() - settled >= .1:
            return rows, True
        if time.monotonic() >= deadline:
            return rows, False
        time.sleep(.05)


def read_only(path):
    """settle_captures and invocation_summary never create or write the store."""
    uri = (path / "usage.sqlite3").resolve().as_uri() + "?mode=ro"
    return closing(sqlite3.connect(uri, uri=True, timeout=.1))


def settle_captures(path, invocation):
    """True once this invocation's captures are persisted and finished; disk indexing scopes from them."""
    try:
        with read_only(path) as db:
            return invocation_captures(db, invocation, SETTLE_TIMEOUT)[1]
    except (OSError, ValueError, sqlite3.Error):
        return False  # invocation_summary reports the same failure.


def invocation_summary(path, invocation, warn_bytes, settled=True, theme=None):
    """What this run captured: per root session it touched, only this invocation's marked captures, never the session's
    earlier runs. The exit path settles them first. theme is the --summary-theme JSON path."""
    from query import render_summary, run_report
    from store import payload_bytes
    import summary_theme
    try:
        with read_only(path) as db:
            retained = payload_bytes(db)
            if retained > warn_bytes:
                # Capture never stops for size; this is the operator's only prompt to retire the store.
                print(f"Warning: the usage store retains {retained / 2**20:,.0f} MiB of payloads, past the {warn_bytes / 2**20:,.0f} MiB warning; "
                      f"stop the kiro-usage service, then archive or delete {path / 'usage.sqlite3'} and its -wal/-shm files to start a new store.", file=sys.stderr)
            rows = invocation_captures(db, invocation, 0)[0]
            if not rows:  # e.g. resumed and exited without a turn
                print("Kiro usage: no calls were captured this run; kiro-usage report --session ID shows a whole session.", file=sys.stderr)
                return
            identities = [name for name, _ in rows]
            sessions = sorted({name if name.startswith("sess_") else "sess_" + name
                               for name in identities if isinstance(name, str)})
            if not sessions:
                print("Kiro usage summary unavailable: no captured conversation identity for this invocation.", file=sys.stderr)
                return
            # The exit path's wait outcome counts even if a call finished after it timed out. These describe the
            # invocation, not one session, so only the last block carries them.
            caveats = [*(["capture writer still has unfinished calls"] if not settled or any(state == "recording" for _, state in rows) else []),
                       *(["calls with no conversation identity excluded"] if any(not name for name in identities) else [])]
            theme = summary_theme.load(theme)  # after the payload warning, which a refused theme must not hide
            for session in sessions:
                print("\n" + render_summary(run_report(db, invocation, session), caveats if session == sessions[-1] else (), theme), file=sys.stderr)
    except (OSError, ValueError, sqlite3.Error) as error:  # JSONDecodeError is a ValueError
        print(f"Kiro usage summary unavailable: {error}.", file=sys.stderr)


def wait_command(command, arguments, environment):
    # Inherit all three descriptors and the foreground process group: interactive
    # Kiro retains its terminal. Forward signals sent to the supervisor alone.
    child = subprocess.Popen([command, *arguments], env=environment)
    previous = {}
    def forward(number, frame):
        # Recheck after job-control changes. The terminal already delivers these
        # signals to every foreground member; forwarding would double Ctrl+C.
        if number in (signal.SIGINT, signal.SIGQUIT):
            for descriptor in (0, 1, 2):
                try:
                    if os.tcgetpgrp(descriptor) == os.getpgrp():
                        return
                except OSError:
                    continue
        if child.poll() is None:
            child.send_signal(number)
    try:
        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM):
            previous[number] = signal.signal(number, forward)
        return child.wait()
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def exec_command(path, port, warn_bytes, arguments, theme=None):
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    if not arguments:
        raise ValueError("usage: kiro-usage exec [--] COMMAND [ARG ...]")
    command, *tail = arguments
    if Path(command).name in ("kiro-cli", "kiro-cli-chat"):
        # Match the managed launcher's exact-token scan and stop at argv's
        # boundary. Do not interpret prompt text or generic command options.
        options = tail[:tail.index("--")] if "--" in tail else tail
        has_v3 = "--v3" in options
        for index, option in enumerate(options):
            if option == "--agent-engine":
                engine = next(iter(options[index + 1:index + 2]), "")
            elif option.startswith("--agent-engine="):
                engine = option.split("=", 1)[1]
            else:
                continue
            if engine != "v3":
                raise ValueError("usage tracking requires the v3 engine; remove the non-v3 --agent-engine override")
            has_v3 = True
        if Path(command).name == "kiro-cli" and "--v3" not in options:
            tail.insert(0, "--v3")
        elif not has_v3:
            raise ValueError("kiro-cli-chat requires explicit --v3 or --agent-engine v3")
    tracked = Path(command).name in ("kiro-cli", "kiro-cli-chat")
    if tracked:
        options = tail[:tail.index("--")] if "--" in tail else tail
        if any(option in ("--help", "--help-all", "--version", "-h", "-V") for option in options):
            tracked = False
        elif Path(command).name == "kiro-cli":
            # Consume known launcher globals before checking the subcommand;
            # unknown options keep tracking rather than guessing their arity.
            value_options = ("--agent", "--agent-engine", "--model", "--repo", "--resume-id")
            flag_options = ("--classic", "--cloud", "--list", "--resume", "--resume-picker", "--tui", "--v2", "--v3", "--verbose", "-r", "-v")
            leading = iter(options)
            administrative = (
                "agent", "dashboard", "debug", "diagnostic", "doctor", "help", "init",
                "integrations", "issue", "launch", "login", "logout", "mcp", "powers",
                "profile", "quit", "restart", "settings", "setup", "theme", "update",
                "user", "whoami",
            )
            for option in leading:
                if option in value_options:
                    next(leading, None)
                elif option in flag_options or option.partition("=")[0] in value_options:
                    continue
                else:
                    tracked = option not in administrative
                    break
    nested = bool(os.environ.get("KIRO_USAGE_INVOCATION"))
    invocation = (os.environ.get("KIRO_USAGE_INVOCATION") or uuid.uuid4().hex) if tracked else None
    child_environment = launch_environment(path, port, refuse_conflicts=False, invocation=invocation)
    try:
        if not tracked or nested:
            os.execvpe(command, [command, *tail], child_environment)
        else:
            started = time.time_ns()
            result = wait_command(command, tail, child_environment)
            previous = {number: signal.signal(number, signal.SIG_IGN)
                        for number in (signal.SIGINT, signal.SIGQUIT)}
            try:
                try:
                    # Refresh scopes from persisted captures, so settle them first.
                    settled = settle_captures(path, invocation)
                    refresh_disk_index(path, started)
                    invocation_summary(path, invocation, warn_bytes, settled=settled, theme=theme)
                    sys.stderr.flush()
                except (OSError, ValueError):
                    # Only a failed summary sink is silenced. Redirect its fd so
                    # Python's final flush cannot replace the child's exit code.
                    sink = open(os.devnull, "w")
                    try:
                        os.dup2(sink.fileno(), sys.stderr.fileno())
                    except (OSError, ValueError):
                        pass
                    sys.stderr = sink
            finally:
                for number, handler in previous.items():
                    signal.signal(number, handler)
            if result < 0:
                if -result not in (signal.SIGKILL, signal.SIGSTOP):
                    signal.signal(-result, signal.SIG_DFL)
                os.kill(os.getpid(), -result)
            return result
    except FileNotFoundError as error:
        raise CommandError(f"command not found: {command}; check PATH or pass an executable path") from error
    except OSError as error:
        raise CommandError(f"cannot execute {command}: {error.strerror}; check the executable path and permissions") from error


def cli(path, arguments, port, warn_bytes, theme=None):
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    if not arguments:
        raise ValueError(USAGE)
    command, *tail = arguments
    script = Path(__file__).parent
    db_args = ["--db", str(path / "usage.sqlite3")]
    if command == "exec":
        return exec_command(path, port, warn_bytes, tail, theme)
    if command == "session" and tail:
        invocation = [str(script / "query.py"), *db_args, "--session", tail[0], *tail[1:]]
    elif command == "report":
        # The report alone renders the exit summary's look outside exec; the full session report has no styles.
        invocation = [str(script / "report.py"), *db_args, *tail, *(["--summary-theme", str(theme)] if theme else [])]
    elif command == "index":
        invocation = [str(script / "disk_index.py"), *db_args, *tail]
    elif command in ("list", "unpack"):
        invocation = [str(script / "capture.py"), *db_args, command, *tail]
    else:
        raise ValueError(USAGE)
    os.umask(0o077)
    private_directory(path, create=True)
    os.execv(sys.executable, [sys.executable, *invocation])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    for mode in ("cli", "environment", "service"):
        child = sub.add_parser(mode)
        child.add_argument("--state-dir")
        child.add_argument("--port", type=int, required=True)
        if mode in ("cli", "service"):  # the collector warns past it; the cli's exit summary repeats it
            child.add_argument("--warn-bytes", type=int, required=True)
        if mode == "cli":  # read by the exec summary and report only
            child.add_argument("--summary-theme")
            child.add_argument("arguments", nargs=argparse.REMAINDER)
        if mode == "service":
            child.add_argument("--mitmdump", required=True)
            child.add_argument("--addon", required=True)
    args = parser.parse_args()
    try:
        path = state_directory(args.state_dir)
        if args.mode == "cli":
            return cli(path, args.arguments, args.port, args.warn_bytes, args.summary_theme)
        elif args.mode == "service":
            service(args, path)
        else:
            environment(path, args.port)
    except CommandError as error:
        print(f"Kiro usage command failed: {error}.", file=sys.stderr)
        return 1
    except (KeyError, OSError, ValueError) as error:
        print(f"Kiro usage tracking unavailable: {error}. Start the kiro-usage service first; see packages/kiro-cli/docs/usage-tracking.md.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
