"""Drive Kiro ACP on the v3 engine through initialize and session/new, no model turn.

The agent is selected the way every v3 ACP client selects one: `session/new`
carries `_meta.kiro.modeId`. `acp --agent` is rejected by the v3 engine the
launcher forces, so it is never passed.
"""

from __future__ import annotations

import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time


MCP_STATUS = "_kiro/mcp/status"

# Sent when the requested modeId names no available agent; the session then
# silently falls back to the default mode instead of failing.
CUSTOM_AGENT_NOT_FOUND = "_kiro/customAgent/not_found"

# How long the child gets to exit after stdin EOF. Overrunning it is a HARNESS
# action, not a product failure -- see the harness_kill branch in run().
SHUTDOWN_BUDGET_SECONDS = 8

# Cap on the child stderr replayed into the teardown notice. On the kill path
# those lines are the only diagnostic left, so dropping them wastes the one
# signal available; replaying all of them would bury it.
STDERR_TAIL_LINES = 8


def exit_description(returncode):
    """A POSIX wait status in words.

    `Popen.returncode` overloads one integer: negative means the child was
    SIGNALLED with its absolute value, non-negative means it chose that exit
    status. Rendering a signal as "status -9" states something that cannot
    happen and reads like a product exit code.
    """
    return f"killed by signal {-returncode}" if returncode < 0 else f"exited with status {returncode}"


def semble_server(
    notifications: list[dict[str, object]],
) -> dict[str, object] | None:
    """The newest MCP status entry for the semble server, if any was reported."""
    entries = [
        server
        for notification in notifications
        if notification.get("method") == MCP_STATUS
        for server in notification["params"].get("servers", [])
        if server.get("name") == "semble"
    ]
    return entries[-1] if entries else None


def run(kiro: str, agent: str, workspace: str, *, wait_for_semble: bool) -> dict[str, object]:
    proc = subprocess.Popen(
        [kiro, "acp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=os.environ,
    )
    assert proc.stdin is not None and proc.stdout is not None and proc.stderr is not None
    inbox: queue.Queue[str | None] = queue.Queue()
    errors: list[str] = []
    notifications: list[dict[str, object]] = []

    def pump_stdout() -> None:
        for line in proc.stdout:
            if line.strip():
                inbox.put(line.rstrip("\n"))
        inbox.put(None)

    def pump_stderr() -> None:
        for line in proc.stderr:
            errors.append(line.rstrip("\n"))

    stdout_thread = threading.Thread(target=pump_stdout, daemon=True)
    stderr_thread = threading.Thread(target=pump_stderr, daemon=True)
    stdout_thread.start()
    stderr_thread.start()

    def send(message: dict[str, object]) -> None:
        proc.stdin.write(json.dumps(message) + "\n")
        proc.stdin.flush()

    def timeout_error(waiting_for: str) -> RuntimeError:
        return RuntimeError(
            f"{agent}: ACP timed out waiting for {waiting_for}; "
            f"notifications={json.dumps(notifications)}; stderr={'; '.join(errors)}"
        )

    def handle(message: dict[str, object], *, reply_to_requests: bool) -> None:
        if "method" in message and "id" in message:
            if reply_to_requests:
                send(
                    {
                        "jsonrpc": "2.0",
                        "id": message["id"],
                        "error": {
                            "code": -32601,
                            "message": "acceptance client callback unavailable",
                        },
                    }
                )
        elif "method" in message:
            notifications.append(message)

    def receive(deadline: float, waiting_for: str) -> dict[str, object]:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise timeout_error(waiting_for)
        try:
            line = inbox.get(timeout=remaining)
        except queue.Empty as exc:
            raise timeout_error(waiting_for) from exc
        if line is None:
            raise RuntimeError(f"{agent}: ACP exited while waiting for {waiting_for}")
        message = json.loads(line)
        handle(message, reply_to_requests=True)
        return message

    def call(request_id: int, method: str, params: dict[str, object]) -> dict[str, object]:
        send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + 90
        while True:
            message = receive(deadline, f"a reply to {method}")
            if "method" not in message and message.get("id") == request_id:
                return message

    def wait_until_semble_connected() -> None:
        deadline = time.monotonic() + 90
        while True:
            server = semble_server(notifications)
            if server is not None and server.get("status") == "connected":
                return
            if server is not None and server.get("status") == "failed":
                raise RuntimeError(f"{agent}: semble MCP server failed: {server}")
            receive(deadline, "the semble MCP server to connect")

    def require_result(response: dict[str, object], method: str) -> dict[str, object]:
        result = response.get("result")
        if not isinstance(result, dict):
            raise RuntimeError(
                f"{agent}: {method} failed: {response}; stderr={'; '.join(errors)}"
            )
        return result

    harness_kill = False
    shutdown_kill = False
    shutdown_seconds = 0.0

    try:
        initialized = call(
            1,
            "initialize",
            {
                "protocolVersion": 1,
                "clientCapabilities": {
                    "fs": {"readTextFile": False, "writeTextFile": False}
                },
            },
        )
        require_result(initialized, "initialize")
        session = call(
            2,
            "session/new",
            {"cwd": workspace, "mcpServers": [], "_meta": {"kiro": {"modeId": agent}}},
        )
        session_result = require_result(session, "session/new")
        if not session_result.get("sessionId"):
            raise RuntimeError(f"{agent}: session/new returned no session id: {session}")
        if wait_for_semble:
            wait_until_semble_connected()
    finally:
        proc.stdin.close()
        closed_at = time.monotonic()
        try:
            proc.wait(timeout=SHUTDOWN_BUDGET_SECONDS)
        except subprocess.TimeoutExpired:
            shutdown_kill = True
            proc.kill()
            proc.wait()
        shutdown_seconds = time.monotonic() - closed_at
        stdout_thread.join(timeout=2)
        stderr_thread.join(timeout=2)
        # `shutdown_kill` alone does not prove the status is ours. CPython's
        # send_signal() polls first and returns without signalling if the child
        # already died, so a child that exits between the wait loop's last poll
        # and os.kill() keeps its OWN status here. Requiring SIGKILL as well
        # leaves that race on the autonomous-exit path, where it belongs.
        harness_kill = shutdown_kill and proc.returncode == -signal.SIGKILL
        if harness_kill:
            # Reported from the `finally` so it still appears when the protocol
            # phase itself failed. A child wedged at shutdown is usually wedged
            # earlier too, and that correlation is evidence a bare protocol
            # timeout does not carry. Emitted after the pump joins so `errors`
            # is complete.
            tail = "; ".join(errors[-STDERR_TAIL_LINES:])
            print(
                f"{agent}: harness SIGKILLed ACP after {shutdown_seconds:.2f}s waiting "
                f"for it to exit after stdin EOF (budget {SHUTDOWN_BUDGET_SECONDS}s); "
                f"the signal is this harness's doing, not the product's"
                + (f"; stderr={tail}" if tail else ""),
                file=sys.stderr,
            )

    if stdout_thread.is_alive() or stderr_thread.is_alive():
        raise RuntimeError(f"{agent}: ACP output pumps did not stop after process exit")
    while True:
        try:
            line = inbox.get_nowait()
        except queue.Empty as exc:
            raise RuntimeError(f"{agent}: ACP stdout ended without an EOF marker") from exc
        if line is None:
            break
        handle(json.loads(line), reply_to_requests=False)

    # `proc.returncode` is the PRODUCT's exit status only when this harness sent
    # no signal. On the kill path above it is our own SIGKILL, and reporting
    # that as the product's status is what made the pre-fix reds unreadable --
    # `git log -S harness_kill` reaches the commit with the measurements.
    #
    # Reaching here means the try block returned: initialize, session/new and,
    # for the configured agent, the semble connection all succeeded, so a slow exit afterwards costs this
    # check nothing it asserts. An AUTONOMOUS non-zero exit still fails.
    #
    # DELIBERATELY GIVEN UP: a child that never exits AT ALL is now a pass
    # rather than a red. That class was only ever caught by accident, and no
    # budget between 8s and infinity can be chosen from evidence anyone has --
    # a killed child never reveals whether it would have exited at 8.1s or
    # never. Guessing one reinstates the same wall-clock flake further out.
    # `teardown` below records the measurement instead, so a cap can later be
    # set from data rather than from a number someone liked.
    if not harness_kill and proc.returncode != 0:
        raise RuntimeError(
            f"{agent}: ACP {exit_description(proc.returncode)} on its own, "
            f"{shutdown_seconds:.2f}s after stdin EOF, harness sent no signal: "
            f"{'; '.join(errors)}"
        )
    return {
        "agent": agent,
        "initialize": initialized,
        "notifications": notifications,
        "session": session,
        "stderr": errors,
        "teardown": {"harness_kill": harness_kill, "seconds": round(shutdown_seconds, 3)},
    }


def main() -> None:
    if len(sys.argv) != 5:
        sys.exit("usage: semble-kiro-acp.py <kiro-cli> <agent> <control> <workspace>")

    configured = run(sys.argv[1], sys.argv[2], sys.argv[4], wait_for_semble=True)
    # The control cannot wait for a status that must never come. Its absence
    # claim is read from everything the child sent before it exited; the
    # configured run proves the status channel works.
    control = run(sys.argv[1], sys.argv[3], sys.argv[4], wait_for_semble=False)

    for result in (configured, control):
        protocol = result["initialize"]["result"]["protocolVersion"]
        if protocol != 1:
            raise RuntimeError(f"{result['agent']}: expected ACP protocol 1, got {protocol}")
        modes = result["session"]["result"]["modes"]
        if modes["currentModeId"] != result["agent"]:
            raise RuntimeError(
                f"{result['agent']}: session selected unexpected mode {modes['currentModeId']}"
            )
        if result["agent"] not in [mode["id"] for mode in modes["availableModes"]]:
            raise RuntimeError(f"{result['agent']}: agent missing from available modes: {modes}")
        fallbacks = [
            notification
            for notification in result["notifications"]
            if notification.get("method") == CUSTOM_AGENT_NOT_FOUND
        ]
        if fallbacks:
            raise RuntimeError(f"{result['agent']}: agent was not found: {fallbacks}")

    server = semble_server(configured["notifications"])
    if server is None or server.get("status") != "connected":
        raise RuntimeError(f"semble-search: unexpected MCP server status: {server}")
    tools = sorted(tool["name"] for tool in server.get("tools", []))
    if tools != ["find_related", "search"]:
        raise RuntimeError(f"semble-search: unexpected Semble tools: {tools}")

    if semble_server(control["notifications"]) is not None:
        raise RuntimeError("control-search: unexpectedly reported the semble MCP server")

    json.dump({"configured": configured, "control": control}, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
