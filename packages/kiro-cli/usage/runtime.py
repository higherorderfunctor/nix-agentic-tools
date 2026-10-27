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
    os.environ["KIRO_USAGE_MAX_BYTES"] = str(args.max_bytes)
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


def invocation_summary(path, invocation, timeout=2.0):
    """Read only exact marker matches; wait briefly for the async writer."""
    from query import query, render
    deadline = time.monotonic() + timeout
    rows = []
    uri = (path / "usage.sqlite3").resolve().as_uri() + "?mode=ro"
    try:
        with closing(sqlite3.connect(uri, uri=True, timeout=.1)) as db:
            previous_rows, settled = None, time.monotonic()
            while True:
                rows = db.execute("""
                    SELECT json_extract(metadata_json,'$."kiro:conversation_id"'), state
                    FROM captures WHERE json_extract(metadata_json,'$.invocation')=?
                """, (invocation,)).fetchall()
                if rows != previous_rows:
                    previous_rows, settled = rows, time.monotonic()
                if rows and all(state != "recording" for _, state in rows) and time.monotonic() - settled >= .1:
                    break
                if time.monotonic() >= deadline:
                    break
                time.sleep(.05)
            sessions = sorted({name if name.startswith("sess_") else "sess_" + name
                               for name, _ in rows if isinstance(name, str) and name})
            if not sessions:
                print("Kiro usage summary unavailable: no captured conversation identity for this invocation.", file=sys.stderr)
                return
            print("\nKiro usage summary (full session totals for sessions observed in this invocation):", file=sys.stderr)
            if any(state == "recording" for _, state in rows):
                print("Warning: capture writer still has unfinished calls; totals may be incomplete.", file=sys.stderr)
            if any(not name for name, _ in rows):
                print("Warning: some invocation calls have no conversation identity and are excluded.", file=sys.stderr)
            for session in sessions:
                report = query(db, session)
                if report["disk"]["available"]:
                    print("Disk observations are from the last explicit index and may be stale; this launch did not refresh them.", file=sys.stderr)
                print(render(report), file=sys.stderr)
                for warning in report["warnings"]:
                    print("Warning: " + warning, file=sys.stderr)
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"Kiro usage summary unavailable: {error}.", file=sys.stderr)


def wait_command(command, arguments, environment):
    # Inherit all three descriptors and the foreground process group: interactive
    # Kiro retains its terminal. Forward signals sent to the supervisor alone.
    child = subprocess.Popen([command, *arguments], env=environment)
    previous = {}
    try:
        shared_foreground = os.tcgetpgrp(0) == os.getpgrp()
    except OSError:
        shared_foreground = False
    def forward(number, frame):
        # The terminal already delivers these to the whole foreground group.
        # Forwarding again turns one Ctrl+C into Kiro's second interrupt.
        if shared_foreground and number in (signal.SIGINT, signal.SIGQUIT):
            return
        if child.poll() is None:
            child.send_signal(number)
    try:
        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM):
            previous[number] = signal.signal(number, forward)
        return child.wait()
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def exec_command(path, port, arguments):
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
    nested = bool(os.environ.get("KIRO_USAGE_INVOCATION"))
    invocation = (os.environ.get("KIRO_USAGE_INVOCATION") or uuid.uuid4().hex) if tracked else None
    child_environment = launch_environment(path, port, refuse_conflicts=False, invocation=invocation)
    try:
        if not tracked or nested:
            os.execvpe(command, [command, *tail], child_environment)
            return
        result = wait_command(command, tail, child_environment)
    except FileNotFoundError as error:
        raise CommandError(f"command not found: {command}; check PATH or pass an executable path") from error
    except OSError as error:
        raise CommandError(f"cannot execute {command}: {error.strerror}; check the executable path and permissions") from error
    invocation_summary(path, invocation)
    if result < 0:
        if -result not in (signal.SIGKILL, signal.SIGSTOP):
            signal.signal(-result, signal.SIG_DFL)
        os.kill(os.getpid(), -result)
    return result


def cli(path, arguments, port):
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    if not arguments:
        raise ValueError("usage: kiro-usage {exec COMMAND [ARG ...]|index --sessions DIR|session ID [--scope tree]|list|replay ID}")
    command, *tail = arguments
    script = Path(__file__).parent
    db_args = ["--db", str(path / "usage.sqlite3")]
    if command == "exec":
        return exec_command(path, port, tail)
    if command == "session" and tail:
        invocation = [str(script / "query.py"), *db_args, "--session", tail[0], *tail[1:]]
    elif command == "index":
        invocation = [str(script / "disk_index.py"), *db_args, *tail]
    elif command in ("list", "replay"):
        invocation = [str(script / "capture.py"), *db_args, command, *tail]
    else:
        raise ValueError("usage: kiro-usage {exec COMMAND [ARG ...]|index --sessions DIR|session ID [--scope tree]|list|replay ID}")
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
        if mode == "cli":
            child.add_argument("arguments", nargs=argparse.REMAINDER)
        if mode == "service":
            child.add_argument("--max-bytes", type=int, required=True)
            child.add_argument("--mitmdump", required=True)
            child.add_argument("--addon", required=True)
    args = parser.parse_args()
    try:
        path = state_directory(args.state_dir)
        if args.mode == "cli":
            return cli(path, args.arguments, args.port)
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
