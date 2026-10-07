// stdio <-> WebSocket bridge for `kiro-cli-chat serve`, so acpctl.py can drive the v3 WebSocket server.
// usage (as wire2.sh WRAP): node ws-bridge.cjs <kiro-cli-chat> serve --port <port> [args...]
// Starts the server, waits for the port, then relays one JSON-RPC frame per stdin line / WebSocket message.
"use strict";
const { spawn } = require("node:child_process");
const net = require("node:net");
const readline = require("node:readline");
const args = process.argv.slice(2);
const port = Number(args[args.indexOf("--port") + 1]);
const server = spawn(args[0], args.slice(1), {
  stdio: ["ignore", "inherit", "inherit"],
});
function ready(left) {
  const s = net.connect(port, "127.0.0.1");
  s.on("connect", () => {
    s.destroy();
    start();
  });
  s.on("error", () => {
    if (left > 0) {
      setTimeout(() => ready(left - 1), 200);
      return;
    }
    console.error("bridge: port never opened");
    process.exit(2);
  });
}
function start() {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const pending = [];
  ws.onmessage = (m) => process.stdout.write(`${String(m.data)}\n`);
  ws.onopen = () => {
    for (const l of pending.splice(0)) ws.send(l);
  };
  const rl = readline.createInterface({ input: process.stdin });
  rl.on("line", (l) => {
    if (ws.readyState === 1) ws.send(l);
    else pending.push(l);
  });
  rl.on("close", () => {
    ws.close();
    server.kill("SIGTERM");
    setTimeout(() => process.exit(0), 500);
  });
}
ready(100);
