"""Drive Kiro v2 ACP through initialize and session/new without a model turn."""

from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
import time


COMMANDS_AVAILABLE = "_kiro.dev/commands/available"


def command_statuses(
    notifications: list[dict[str, object]],
) -> list[dict[str, object]]:
    return [
        notification["params"]
        for notification in notifications
        if notification.get("method") == COMMANDS_AVAILABLE
    ]


def latest_command_status(
    notifications: list[dict[str, object]],
) -> dict[str, object] | None:
    matches = command_statuses(notifications)
    return matches[-1] if matches else None


def run(kiro: str, agent: str, workspace: str) -> dict[str, object]:
    proc = subprocess.Popen(
        [kiro, "acp", "--agent", agent],
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

    def wait_until_commands_ready() -> None:
        deadline = time.monotonic() + 90
        while latest_command_status(notifications) is None:
            receive(deadline, "commands/available readiness")

    def require_result(response: dict[str, object], method: str) -> dict[str, object]:
        result = response.get("result")
        if not isinstance(result, dict):
            raise RuntimeError(
                f"{agent}: {method} failed: {response}; stderr={'; '.join(errors)}"
            )
        return result

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
        session = call(2, "session/new", {"cwd": workspace, "mcpServers": []})
        session_result = require_result(session, "session/new")
        if not session_result.get("sessionId"):
            raise RuntimeError(f"{agent}: session/new returned no session id: {session}")
        wait_until_commands_ready()
    finally:
        proc.stdin.close()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        stdout_thread.join(timeout=2)
        stderr_thread.join(timeout=2)

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

    if proc.returncode != 0:
        raise RuntimeError(
            f"{agent}: ACP exited with status {proc.returncode}: {'; '.join(errors)}"
        )
    return {
        "agent": agent,
        "initialize": initialized,
        "notifications": notifications,
        "session": session,
        "stderr": errors,
    }


def main() -> None:
    if len(sys.argv) != 5:
        sys.exit("usage: semble-kiro-acp.py <kiro-cli-chat> <agent> <control> <workspace>")

    configured = run(sys.argv[1], sys.argv[2], sys.argv[4])
    control = run(sys.argv[1], sys.argv[3], sys.argv[4])

    def commands_available(result: dict[str, object]) -> dict[str, object]:
        status = latest_command_status(result["notifications"])
        if status is None:
            raise RuntimeError(
                f"{result['agent']}: expected a commands/available notification"
            )
        return status

    for result in (configured, control):
        protocol = result["initialize"]["result"]["protocolVersion"]
        if protocol != 1:
            raise RuntimeError(f"{result['agent']}: expected v2 ACP protocol 1, got {protocol}")
        current_mode = result["session"]["result"]["modes"]["currentModeId"]
        if current_mode != result["agent"]:
            raise RuntimeError(
                f"{result['agent']}: session selected unexpected mode {current_mode}"
            )

    configured_status = commands_available(configured)
    servers = configured_status.get("mcpServers", [])
    if servers != [{"name": "semble", "status": "running", "toolCount": 2}]:
        raise RuntimeError(f"semble-search: unexpected MCP server status: {servers}")
    tools = sorted(
        tool["name"]
        for tool in configured_status.get("tools", [])
        if tool.get("source") == "mcp:semble"
    )
    if tools != ["find_related", "search"]:
        raise RuntimeError(f"semble-search: unexpected Semble tools: {tools}")

    control_notifications = control["notifications"]
    control_server_snapshots = [
        status.get("mcpServers", [])
        for status in command_statuses(control_notifications)
        if status.get("mcpServers", [])
    ]
    if control_server_snapshots:
        raise RuntimeError(
            f"control-search: unexpectedly reported MCP servers: "
            f"{control_server_snapshots}"
        )
    if any(
        notification.get("method") == "_kiro.dev/mcp/server_initialized"
        for notification in control_notifications
    ):
        raise RuntimeError("control-search: unexpectedly initialized an MCP server")
    if any(
        tool.get("source") == "mcp:semble"
        for notification in control_notifications
        if notification.get("method") == "_kiro.dev/commands/available"
        for tool in notification["params"].get("tools", [])
    ):
        raise RuntimeError("control-search: unexpectedly reported Semble tools")

    json.dump({"configured": configured, "control": control}, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
