import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { get as nodeGet } from "node:http";
import { connect, createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Effect, Fiber, Stream } from "effect";
import { describe, expect, it } from "vitest";
import WebSocket from "ws";
import type { SubscriptionQuery } from "../src/data/protocol.ts";
import type { ViewState } from "../src/data/reducer.ts";
import {
  makeMemoryDataLayerWithFactory,
  openBrowserSocket,
  Subscriptions,
} from "../src/data/services.ts";

type Frame = Record<string, unknown>;

const binary = process.env.AIRLOCK_REAL_BINARY;
const frontend = process.env.AIRLOCK_WEB_ROOT;
const token = "fixture-read-token";

function pause(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function getHttp(url: string): Promise<{
  status: number;
  headers: Record<string, string | string[] | undefined>;
  body: string;
}> {
  return new Promise((resolve, reject) => {
    const request = nodeGet(url, (response) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () =>
        resolve({
          status: response.statusCode ?? 0,
          headers: response.headers,
          body: Buffer.concat(chunks).toString("utf8"),
        }),
      );
      response.on("error", reject);
    });
    request.setTimeout(2_000, () => request.destroy(new Error("HTTP timeout")));
    request.on("error", reject);
  });
}

async function until(
  predicate: () => boolean,
  label: string,
  milliseconds = 10_000,
): Promise<void> {
  const deadline = Date.now() + milliseconds;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out: ${label}`);
    await pause(25);
  }
}

async function freePort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new Error("loopback port missing");
  }
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return address.port;
}

function canConnect(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect(port, "127.0.0.1");
    socket.once("connect", () => {
      socket.destroy();
      resolve(true);
    });
    socket.once("error", () => resolve(false));
  });
}

function tunnelEcho(proxyPort: number, targetPort: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const socket = connect(proxyPort, "127.0.0.1");
    const payload = "forwarded-while-control-stalled";
    let response = "";
    let connected = false;
    const timer = setTimeout(
      () => socket.destroy(new Error("CONNECT forwarding timeout")),
      2_000,
    );
    socket.once("connect", () => {
      const authorization = Buffer.from("harness:fake-proxy-token").toString(
        "base64",
      );
      socket.write(
        `CONNECT localhost:${targetPort} HTTP/1.1\r\nHost: localhost:${targetPort}\r\nProxy-Authorization: Basic ${authorization}\r\n\r\n`,
      );
    });
    socket.on("data", (data) => {
      response += String(data);
      if (!connected && response.includes("\r\n\r\n")) {
        if (!response.startsWith("HTTP/1.1 200 Connection Established")) {
          socket.destroy(
            new Error(`CONNECT rejected: ${response.slice(0, 100)}`),
          );
          return;
        }
        connected = true;
        response = response.split("\r\n\r\n", 2)[1] ?? "";
        socket.write(payload);
      }
      if (connected && response.includes(payload)) {
        clearTimeout(timer);
        socket.destroy();
        resolve();
      }
    });
    socket.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

function observedClient(
  port: number,
  options: {
    readonly withholdFirstAcknowledgements?: boolean;
  } = {},
) {
  const authority = `127.0.0.1:${port}`;
  const received: Frame[] = [];
  const sent: Frame[] = [];
  const connections: Array<{
    socket: WebSocket;
    frames: Frame[];
    sent: Frame[];
    suppressedAcknowledgements: number;
    closeCode: number | null;
  }> = [];
  const layer = makeMemoryDataLayerWithFactory(
    { url: `ws://${authority}/api/v1/live`, token },
    {
      open: () => {
        const socket = new WebSocket(
          `ws://${authority}/api/v1/live`,
          "airlock.v1",
          { headers: { Host: authority, Origin: `http://${authority}` } },
        );
        const connection = {
          socket,
          frames: [] as Frame[],
          sent: [] as Frame[],
          suppressedAcknowledgements: 0,
          closeCode: null as number | null,
        };
        connections.push(connection);
        socket.on("message", (data) => {
          const frame = JSON.parse(String(data)) as Frame;
          connection.frames.push(frame);
          received.push(frame);
        });
        socket.on("close", (code) => {
          connection.closeCode = code;
        });
        const originalSend = socket.send.bind(socket) as (
          data: string,
        ) => unknown;
        socket.send = ((data: unknown) => {
          const frame = JSON.parse(String(data)) as Frame;
          // Only the first slow-client connection withholds ACKs; recovery uses
          // the ordinary Effect client and must regain a live view.
          if (
            options.withholdFirstAcknowledgements &&
            connection === connections[0] &&
            frame.type === "ack"
          ) {
            connection.suppressedAcknowledgements += 1;
            return;
          }
          connection.sent.push(frame);
          sent.push(frame);
          return originalSend(String(data));
        }) as typeof socket.send;
        return openBrowserSocket(socket as unknown as globalThis.WebSocket);
      },
    },
    { retryInitialMs: 50, retryJitter: () => 0.5 },
  );
  return { connections, layer, received, sent };
}

async function frameMatching(
  frames: Frame[],
  predicate: (frame: Frame) => boolean,
  label: string,
  from = 0,
  milliseconds = 10_000,
): Promise<Frame> {
  await until(() => frames.slice(from).some(predicate), label, milliseconds);
  const frame = frames.slice(from).find(predicate);
  if (frame === undefined) throw new Error(`missing frame: ${label}`);
  return frame;
}

function seedIdentities(db: DatabaseSync, now: number): void {
  for (const suffix of ["a", "b"]) {
    db.prepare("INSERT OR IGNORE INTO providers VALUES (?, ?)").run(
      `provider-${suffix}`,
      now,
    );
    db.prepare("INSERT OR IGNORE INTO credentials VALUES (?, ?, ?)").run(
      `credential-${suffix}`,
      `provider-${suffix}`,
      now,
    );
    db.prepare("INSERT OR IGNORE INTO groups VALUES (?, ?)").run(
      `group-${suffix}`,
      now,
    );
    db.prepare("INSERT OR IGNORE INTO group_members VALUES (?, ?)").run(
      `group-${suffix}`,
      `credential-${suffix}`,
    );
  }
}

function insertRequest(db: DatabaseSync, suffix: string, model: string): void {
  db.prepare(
    "INSERT INTO request_events (occurred_at_unix, group_id, credential_id, model_id, outcome, status_code, request_bytes, response_bytes, latency_ms, input_tokens, output_tokens, usage_complete, dropped_events) VALUES (?, ?, ?, ?, 'completed', 200, 12, 24, 3, 1, 2, 1, 0)",
  ).run(
    Math.floor(Date.now() / 1000),
    `group-${suffix}`,
    `credential-${suffix}`,
    model,
  );
}

function insertSnapshot(
  db: DatabaseSync,
  suffix: string,
  status: "success" | "gap",
): void {
  const row = db
    .prepare(
      "INSERT INTO provider_snapshots (fetched_at_unix, provider_id, credential_id, account_id, source, surface, fetch_status, gap_reason) VALUES (?, ?, ?, 'fixture-account', 'out_of_band_fetch', 'zai_quota', ?, ?)",
    )
    .run(
      Math.floor(Date.now() / 1000),
      `provider-${suffix}`,
      `credential-${suffix}`,
      status,
      status === "gap" ? "usage_timeout" : null,
    );
  if (status === "success") {
    db.prepare(
      "INSERT INTO quota_pools (snapshot_id, ordinal, label, utilized, limit_value, reset_at_unix) VALUES (?, 0, 'five_hour', 25000, 100000, NULL)",
    ).run(row.lastInsertRowid);
  }
}

function hasValue(state: ViewState, field: string, value: unknown): boolean {
  return [...state.entries.values()].some(
    (entry) => field in entry && entry[field as keyof typeof entry] === value,
  );
}

function consume(query: SubscriptionQuery, states: ViewState[]) {
  return Effect.gen(function* () {
    const stream = yield* Subscriptions.useSync((service) =>
      service.stream(query),
    );
    yield* Stream.runForEach(stream, (state) =>
      Effect.sync(() => {
        states.push(state);
      }),
    );
  });
}

describe.skipIf(binary === undefined || frontend === undefined)(
  "packaged Airlock with the headless web data client",
  () => {
    it("starts the packaged launcher when control is disabled", async () => {
      if (binary === undefined) throw new Error("packaged binary missing");
      const state = mkdtempSync(join(tmpdir(), "airlock-web-no-control-"));
      const runtime = mkdtempSync("/dev/shm/airlock-web-no-control-");
      const port = await freePort();
      const config = join(state, "config.json");
      writeFileSync(
        config,
        JSON.stringify({
          clients: {},
          credentials: {},
          groups: {},
          listen: `127.0.0.1:${port}`,
          providers: {},
          state_dir: state,
          unknown_hosts: "deny",
        }),
      );
      const child = spawn(binary, ["serve", "--config", config], {
        env: { ...process.env, XDG_RUNTIME_DIR: runtime },
        stdio: ["ignore", "ignore", "pipe"],
      });
      const logs: string[] = [];
      child.stderr?.on("data", (data) => logs.push(String(data)));
      try {
        let ready = false;
        for (let attempt = 0; attempt < 200; attempt += 1) {
          if (await canConnect(port)) {
            ready = true;
            break;
          }
          if (child.exitCode !== null)
            throw new Error(`Airlock exited: ${logs.join("")}`);
          await pause(25);
        }
        expect(ready, logs.join("")).toBe(true);
      } finally {
        if (child.exitCode === null) {
          child.kill("SIGTERM");
          await new Promise<void>((resolve) =>
            child.once("exit", () => resolve()),
          );
        }
        rmSync(runtime, { recursive: true, force: true });
        rmSync(state, { recursive: true, force: true });
      }
    }, 10_000);

    it("serves built assets and propagates persisted scoped changes, reconnects, gaps, and slow-consumer backpressure", async () => {
      if (binary === undefined || frontend === undefined)
        throw new Error("integration inputs missing");
      const state = mkdtempSync(join(tmpdir(), "airlock-web-state-"));
      const runtime = mkdtempSync("/dev/shm/airlock-web-runtime-");
      const gatewayPort = await freePort();
      const controlPort = await freePort();
      const authority = `127.0.0.1:${controlPort}`;
      const base = `http://${authority}`;
      const tokenFile = join(state, "read-token");
      const proxyTokenFile = join(state, "proxy-token");
      const credentialFile = join(state, "provider-token");
      const configFile = join(state, "config.json");
      writeFileSync(tokenFile, token, { mode: 0o600 });
      writeFileSync(proxyTokenFile, "fake-proxy-token", { mode: 0o600 });
      writeFileSync(credentialFile, "fake-provider-token", { mode: 0o600 });
      writeFileSync(
        configFile,
        JSON.stringify({
          clients: {
            harness: { grants: ["group-a"], token_file: proxyTokenFile },
          },
          control: { listen: authority, read_token_file: tokenFile },
          credentials: {
            "credential-a": {
              auth: { file: credentialFile, type: "oauth_bearer" },
              provider: "provider-a",
            },
          },
          groups: {
            "group-a": {
              intercept: [],
              members: { "credential-a": { models: [] } },
              primary: "credential-a",
              protocol: "anthropic",
            },
          },
          listen: `127.0.0.1:${gatewayPort}`,
          providers: {
            "provider-a": { endpoints: { anthropic: "https://localhost" } },
          },
          state_dir: state,
          unknown_hosts: "tunnel",
        }),
      );
      const serveArgs = ["serve", "--config", configFile];
      if (process.env.AIRLOCK_REAL_RAW === "1") {
        serveArgs.push("--web-root", frontend);
      }
      const child = spawn(binary, serveArgs, {
        env: { ...process.env, XDG_RUNTIME_DIR: runtime },
        stdio: ["ignore", "pipe", "pipe"],
      });
      const logs: string[] = [];
      child.stdout?.on("data", (data) => logs.push(String(data)));
      child.stderr?.on("data", (data) => logs.push(String(data)));
      let database: DatabaseSync | undefined;
      let echoServer: ReturnType<typeof createServer> | undefined;
      let dataFiber: ReturnType<typeof Effect.runFork> | undefined;
      const recoveryFibers: Array<ReturnType<typeof Effect.runFork>> = [];
      try {
        let ready = false;
        for (let attempt = 0; attempt < 200; attempt += 1) {
          if ((await getHttp(base).catch(() => null))?.status === 200) {
            ready = true;
            break;
          }
          if (child.exitCode !== null)
            throw new Error(`Airlock exited: ${logs.join("")}`);
          await pause(25);
        }
        if (!ready)
          throw new Error(`Airlock startup timed out: ${logs.join("")}`);
        const index = await getHttp(base);
        expect(index.status).toBe(200);
        expect(index.headers["content-type"]).toContain("text/html");
        expect(index.headers["cache-control"]).toBe("no-store");
        expect(index.headers["content-security-policy"]).toContain(
          "frame-ancestors 'none'",
        );
        const html = index.body;
        const script = html.match(/src="(\/assets\/[^"]+\.js)"/)?.[1];
        const style = html.match(/href="(\/assets\/[^"]+\.css)"/)?.[1];
        expect(script).toBeDefined();
        expect(style).toBeDefined();
        const javascript = await getHttp(`${base}${script}`);
        const css = await getHttp(`${base}${style}`);
        expect(javascript.headers["content-type"]).toContain("javascript");
        expect(css.headers["content-type"]).toContain("text/css");
        expect(css.body).toContain("mantine-light-hidden");
        for (const path of [
          "/assets/missing.js",
          `/assets/${encodeURIComponent("../index.html")}`,
        ]) {
          expect((await getHttp(`${base}${path}`)).status).toBe(404);
        }

        database = new DatabaseSync(join(state, "airlock.sqlite3"));
        database.exec("PRAGMA foreign_keys=ON");
        seedIdentities(database, Math.floor(Date.now() / 1000));
        insertRequest(database, "a", "chart-model");
        database.exec(
          "UPDATE request_events SET occurred_at_unix=occurred_at_unix-1 WHERE model_id='chart-model'",
        );

        const { layer, received, sent } = observedClient(controlPort);
        const requests: ViewState[] = [];
        const quota: ViewState[] = [];
        const chart: ViewState[] = [];
        let releaseRequests: () => void = () => undefined;
        let releaseQuota: () => void = () => undefined;
        const requestsGate = new Promise<void>((resolve) => {
          releaseRequests = resolve;
        });
        const quotaGate = new Promise<void>((resolve) => {
          releaseQuota = resolve;
        });
        const requestQuery: SubscriptionQuery = {
          kind: "requests.table",
          limit: 200,
          provider: "provider-a",
          window: { last_seconds: 3600 },
        };
        const quotaQuery: SubscriptionQuery = {
          kind: "usage.series",
          credential: "credential-a",
          limit: 100,
          provider: "provider-a",
          source: "out_of_band_fetch",
          surface: "zai_quota",
          window: { last_seconds: 3600 },
        };
        const chartQuery: SubscriptionQuery = {
          kind: "requests.chart",
          window: { last_seconds: 3600 },
          dimensions: ["client", "model"],
          client: null,
          model: "chart-model",
          provider: "provider-a",
        };
        const program = Effect.gen(function* () {
          const requestFiber = yield* Effect.forkChild(
            consume(requestQuery, requests),
          );
          const quotaFiber = yield* Effect.forkChild(
            consume(quotaQuery, quota),
          );
          const chartFiber = yield* Effect.forkChild(
            consume(chartQuery, chart),
          );
          yield* Effect.promise(() => requestsGate);
          yield* Fiber.interrupt(requestFiber);
          yield* Effect.promise(() => quotaGate);
          yield* Fiber.interrupt(quotaFiber);
          yield* Fiber.interrupt(chartFiber);
        });
        dataFiber = Effect.runFork(
          Effect.scoped(Effect.provide(program, layer)),
        );
        await until(
          () =>
            requests.some((item) => item.phase === "live") &&
            quota.some((item) => item.phase === "live"),
          "both widgets initially live",
        );
        const requestId = sent.find(
          (item) => item.type === "subscribe" && item.kind === "requests.table",
        )?.id;
        const quotaId = sent.find(
          (item) => item.type === "subscribe" && item.kind === "usage.series",
        )?.id;
        expect(typeof requestId).toBe("string");
        expect(typeof quotaId).toBe("string");

        await until(
          () =>
            chart.some(
              (state) =>
                state.phase === "live" &&
                [...state.entries.values()].some(
                  (row) => "dimensions" in row && row.events === 1,
                ),
            ),
          "filtered chart snapshot",
        );
        const chartId = sent.find(
          (item) => item.type === "subscribe" && item.kind === "requests.chart",
        )?.id;
        const chartSnapshot = await frameMatching(
          received,
          (item) => item.type === "snapshot" && item.id === chartId,
          "chart snapshot",
        );
        expect(chartSnapshot).toMatchObject({
          meta: {
            chart: { bucket_seconds: 3600, dimensions: ["client", "model"] },
          },
        });
        insertRequest(database, "a", "chart-model");
        insertRequest(database, "b", "chart-model");
        insertRequest(database, "b", "unrelated");
        insertRequest(database, "a", "relevant");
        insertSnapshot(database, "b", "success");
        insertSnapshot(database, "a", "success");
        await until(
          () =>
            requests.some(
              (item) =>
                item.phase === "live" && hasValue(item, "model", "relevant"),
            ),
          "persisted request reaches request widget",
        );
        await until(
          () =>
            quota.some(
              (item) =>
                item.phase === "live" &&
                hasValue(item, "account_id", "fixture-account"),
            ),
          "persisted quota reaches quota widget",
          12_000,
        );
        const requestDelta = await frameMatching(
          received,
          (item) =>
            item.type === "delta" &&
            item.id === requestId &&
            ((item.upserts as { requests?: unknown[] })?.requests?.length ??
              0) > 0,
          "relevant request delta",
        );
        const upserts = (
          requestDelta.upserts as {
            requests: Array<{ value: { provider: string } }>;
          }
        ).requests;
        expect(upserts.length).toBeGreaterThan(0);
        expect(
          upserts.every((item) => item.value.provider === "provider-a"),
        ).toBe(true);
        await until(
          () =>
            chart.some(
              (state) =>
                state.phase === "live" &&
                [...state.entries.values()].some(
                  (row) =>
                    "dimensions" in row &&
                    row.events === 2 &&
                    row.dimensions.client === null &&
                    row.dimensions.model === "chart-model",
                ),
            ),
          "filtered chart delta",
          12000,
        );
        const chartDelta = await frameMatching(
          received,
          (item) =>
            item.type === "delta" &&
            item.id === chartId &&
            ((item.upserts as { request_chart?: unknown[] })?.request_chart
              ?.length ?? 0) > 0,
          "chart tuple delta",
        );
        const chartTuple = (
          chartDelta.upserts as {
            request_chart: Array<{ key: string; value: unknown[] }>;
          }
        ).request_chart[0];
        expect(chartTuple?.value).toHaveLength(10);
        expect(chartTuple?.value.slice(1)).toEqual([
          null,
          "chart-model",
          2,
          2,
          0,
          null,
          null,
          2,
          4,
        ]);
        expect(chartTuple?.key).toBe(
          JSON.stringify(chartTuple?.value.slice(0, 3)),
        );
        const quotaDelta = await frameMatching(
          received,
          (item) =>
            item.type === "delta" &&
            item.id === quotaId &&
            ((item.upserts as { snapshots?: unknown[] })?.snapshots?.length ??
              0) > 0,
          "relevant quota delta",
        );
        const quotaUpserts = (
          quotaDelta.upserts as {
            snapshots: Array<{ value: { provider: string } }>;
          }
        ).snapshots;
        expect(quotaUpserts.map((item) => item.value.provider)).toEqual([
          "provider-a",
        ]);

        insertSnapshot(database, "a", "gap");
        await until(
          () =>
            quota.some((item) => hasValue(item, "gap_reason", "usage_timeout")),
          "failed fetch stays visible",
          12_000,
        );
        releaseRequests();
        await until(
          () =>
            sent.some(
              (item) => item.type === "unsubscribe" && item.id === requestId,
            ),
          "request widget unsubscribe",
        );
        await frameMatching(
          received,
          (item) => item.type === "unsubscribed" && item.id === requestId,
          "unsubscribe acknowledgement",
        );
        const afterUnsubscribe = received.filter(
          (item) => item.id === requestId,
        ).length;
        insertRequest(database, "a", "after-unsubscribe");
        await pause(1_250);
        expect(received.filter((item) => item.id === requestId)).toHaveLength(
          afterUnsubscribe,
        );
        releaseQuota();
        await Effect.runPromise(Fiber.await(dataFiber));

        const reconnect = observedClient(controlPort);
        const reconnectStates: ViewState[] = [];
        const reconnectFiber = Effect.runFork(
          Effect.scoped(
            Effect.provide(
              consume(requestQuery, reconnectStates),
              reconnect.layer,
            ),
          ),
        );
        recoveryFibers.push(reconnectFiber);
        await until(
          () => reconnectStates.some((item) => item.phase === "live"),
          "Effect reconnect widget initially live",
        );
        const initialReconnect = reconnectStates.at(-1);
        const reconnectConnection = reconnect.connections[0];
        if (initialReconnect === undefined || reconnectConnection === undefined)
          throw new Error("reconnect baseline missing");
        const initialReconnectIndex = reconnectStates.length - 1;
        reconnectConnection.socket.close();
        await until(
          () =>
            reconnectConnection.closeCode !== null &&
            reconnectStates.at(-1)?.phase === "reconnecting",
          "Effect reconnect widget sees disconnection",
        );
        await until(
          () =>
            reconnect.connections[1]?.sent.some(
              (item) => item.type === "auth",
            ) === true &&
            reconnect.connections[1]?.sent.some(
              (item) => item.type === "subscribe",
            ) === true,
          "Effect reconnect replacement authenticates and subscribes",
        );
        const secondAuth = reconnect.connections[1]?.sent.find(
          (item) => item.type === "auth",
        );
        const secondSubscribe = reconnect.connections[1]?.sent.find(
          (item) => item.type === "subscribe",
        );
        expect(secondAuth).not.toHaveProperty("resume_session");
        expect(secondSubscribe).not.toHaveProperty("resume");
        await until(
          () =>
            reconnectStates
              .slice(initialReconnectIndex + 1)
              .some(
                (item) =>
                  item.phase === "live" &&
                  item.epoch !== initialReconnect.epoch,
              ),
          "Effect reconnect widget recovers with a fresh epoch",
        );
        await Effect.runPromise(Fiber.interrupt(reconnectFiber));

        const slow = observedClient(controlPort, {
          withholdFirstAcknowledgements: true,
        });
        const slowStates: ViewState[][] = Array.from({ length: 8 }, () => []);
        const slowProgram = Effect.gen(function* () {
          for (const states of slowStates)
            yield* Effect.forkChild(consume(requestQuery, states));
          yield* Effect.never;
        });
        const slowFiber = Effect.runFork(
          Effect.scoped(Effect.provide(slowProgram, slow.layer)),
        );
        recoveryFibers.push(slowFiber);
        await until(
          () =>
            slowStates.every((states) =>
              states.some((item) => item.phase === "live"),
            ),
          "all eight Effect slow-client widgets initially live",
        );
        const slowConnection = slow.connections[0];
        if (slowConnection === undefined)
          throw new Error("slow connection missing");
        const delivered = () =>
          slowConnection.frames.filter(
            (item) => item.type === "snapshot" || item.type === "delta",
          );
        await until(
          () =>
            delivered().length === 16 &&
            slowConnection.suppressedAcknowledgements === 16,
          "all sixteen real server data credits consumed without acknowledgement",
        );
        expect(slow.connections).toHaveLength(1);
        expect(slowConnection.sent.some((item) => item.type === "ack")).toBe(
          false,
        );
        expect(slowConnection.closeCode).toBeNull();

        // The new row is eligible after the next one-second request tick. With
        // all 16 credits consumed its delivery must wait in Flow::acquire.
        insertRequest(database, "a", "pending-while-credit-exhausted");
        await pause(1_500);
        expect(delivered()).toHaveLength(16);
        expect(
          slowStates.some((states) =>
            states.some((item) =>
              hasValue(item, "model", "pending-while-credit-exhausted"),
            ),
          ),
        ).toBe(false);
        expect(slowConnection.frames.some((item) => item.type === "gap")).toBe(
          false,
        );
        expect(slowConnection.closeCode).toBeNull();
        echoServer = createServer((socket) => socket.pipe(socket));
        await new Promise<void>((resolve) =>
          echoServer?.listen(0, "127.0.0.1", resolve),
        );
        const echoAddress = echoServer.address();
        if (echoAddress === null || typeof echoAddress === "string")
          throw new Error("echo port missing");
        await tunnelEcho(gatewayPort, echoAddress.port);
        expect(delivered()).toHaveLength(16);
        expect(slowConnection.closeCode).toBeNull();

        await until(
          () =>
            slowStates.some((states) =>
              states.some((item) => item.gap?.code === "slow_consumer"),
            ),
          `Effect slow-consumer gap remains visible (delivered=${delivered().length}, suppressed=${slowConnection.suppressedAcknowledgements}, gaps=${slowConnection.frames.filter((item) => item.type === "gap").length}, close=${slowConnection.closeCode})`,
          20_000,
        );
        await until(
          () => slowConnection.closeCode !== null,
          "slow consumer close",
        );
        expect(slowConnection.closeCode).toBe(1013);
        const recoveredStates = slowStates.find((states) =>
          states.some((item) => item.gap?.code === "slow_consumer"),
        );
        if (recoveredStates === undefined)
          throw new Error("slow-consumer view missing");
        const gapIndex = recoveredStates.findIndex(
          (item) => item.gap?.code === "slow_consumer",
        );
        const beforeGap = recoveredStates[gapIndex - 1];
        expect(recoveredStates[gapIndex]).toMatchObject({
          phase: "resynchronizing",
          epoch: null,
          gap: { code: "slow_consumer", action: "resnapshot" },
        });
        expect(recoveredStates[gapIndex]?.entries).toEqual(beforeGap?.entries);
        await until(
          () =>
            recoveredStates
              .slice(gapIndex + 1)
              .some(
                (item) =>
                  item.phase === "live" &&
                  item.epoch !== beforeGap?.epoch &&
                  hasValue(item, "model", "pending-while-credit-exhausted"),
              ),
          "Effect slow-consumer widget recovers with a fresh snapshot and pending row",
        );
        expect(slow.connections.length).toBeGreaterThanOrEqual(2);
        await Effect.runPromise(Fiber.interrupt(slowFiber));
        const insertedAt = Math.floor(Date.now() / 1000) - 1;
        database.exec("BEGIN");
        for (let index = 0; index < 4000; index++) {
          const model = `m${String(index).padStart(4, "0")}${"x".repeat(80)}`;
          database
            .prepare(
              "INSERT INTO request_events (occurred_at_unix,group_id,credential_id,model_id,outcome,status_code,request_bytes,response_bytes,latency_ms,input_tokens,output_tokens,usage_complete,dropped_events) VALUES (?, 'group-b', 'credential-b', ?, 'completed',200,0,0,0,1,2,1,0)",
            )
            .run(insertedAt, model);
        }
        database.exec("COMMIT");
        const refusedClient = observedClient(controlPort);
        const refusedStates: ViewState[] = [];
        const refusalFiber = Effect.runFork(
          Effect.scoped(
            Effect.provide(
              consume(
                {
                  kind: "requests.chart",
                  window: {
                    since_unix: insertedAt - 1,
                    until_unix: insertedAt + 1,
                  },
                  dimensions: ["model"],
                  provider: "provider-b",
                },
                refusedStates,
              ),
              refusedClient.layer,
            ),
          ),
        );
        recoveryFibers.push(refusalFiber);
        await until(
          () =>
            refusedStates.some(
              (state) => state.terminal && state.error === "range_too_large",
            ),
          "server decoded chart memory refusal",
        );
        expect(
          refusedClient.received.some((frame) => frame.type === "snapshot"),
        ).toBe(false);
      } finally {
        for (const fiber of recoveryFibers)
          await Effect.runPromise(Fiber.interrupt(fiber));
        if (dataFiber !== undefined)
          await Effect.runPromise(Fiber.interrupt(dataFiber));
        database?.close();
        if (echoServer?.listening) {
          await new Promise<void>((resolve) =>
            echoServer?.close(() => resolve()),
          );
        }
        if (child.exitCode === null) {
          child.kill("SIGTERM");
          await new Promise<void>((resolve) =>
            child.once("exit", () => resolve()),
          );
        }
        rmSync(runtime, { recursive: true, force: true });
        rmSync(state, { recursive: true, force: true });
      }
    }, 130_000);
  },
);
