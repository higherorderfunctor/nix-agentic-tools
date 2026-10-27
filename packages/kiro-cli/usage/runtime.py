"""Start the private capture service and fail closed before a tracked launch."""

import argparse
import os
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


def launch_environment(path, port, refuse_conflicts=True):
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
    url = f"http://127.0.0.1:{port}"
    values = {name: url for name in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy")}
    values["NODE_EXTRA_CA_CERTS"] = str(cert)
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
    child_environment = launch_environment(path, port, refuse_conflicts=False)
    try:
        os.execvpe(command, [command, *tail], child_environment)
    except FileNotFoundError as error:
        raise CommandError(f"command not found: {command}; check PATH or pass an executable path") from error
    except OSError as error:
        raise CommandError(f"cannot execute {command}: {error.strerror}; check the executable path and permissions") from error


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
            cli(path, args.arguments, args.port)
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
