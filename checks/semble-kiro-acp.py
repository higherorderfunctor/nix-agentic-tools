"""Drive Kiro v2 ACP through initialize and session/new without a model turn."""

from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
import time


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

    threading.Thread(target=pump_stdout, daemon=True).start()
    threading.Thread(target=pump_stderr, daemon=True).start()

    def send(message: dict[str, object]) -> None:
        proc.stdin.write(json.dumps(message) + "\n")
        proc.stdin.flush()

    def call(request_id: int, method: str, params: dict[str, object]) -> dict[str, object]:
        send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                line = inbox.get(timeout=max(0.1, deadline - time.monotonic()))
            except queue.Empty:
                break
            if line is None:
                raise RuntimeError(f"{agent}: ACP exited before replying to {method}")
            message = json.loads(line)
            if "method" in message and "id" in message:
                send(
                    {
                        "jsonrpc": "2.0",
                        "id": message["id"],
                        "error": {"code": -32601, "message": "acceptance client callback unavailable"},
                    }
                )
            elif "method" in message:
                notifications.append(message)
            elif message.get("id") == request_id:
                return message
        raise RuntimeError(f"{agent}: ACP timed out replying to {method}")

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
        session = call(2, "session/new", {"cwd": workspace, "mcpServers": []})
    finally:
        proc.stdin.close()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    if proc.returncode != 0:
        raise RuntimeError(
            f"{agent}: ACP exited with status {proc.returncode}: {'; '.join(errors)}"
        )
    if "result" not in initialized:
        raise RuntimeError(f"{agent}: initialize failed: {initialized}")
    if "result" not in session or not session["result"].get("sessionId"):
        raise RuntimeError(f"{agent}: session/new failed: {session}")
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
        matches = [
            notification["params"]
            for notification in result["notifications"]
            if notification.get("method") == "_kiro.dev/commands/available"
        ]
        if not matches:
            raise RuntimeError(
                f"{result['agent']}: expected a commands/available notification"
            )
        return matches[-1]

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
