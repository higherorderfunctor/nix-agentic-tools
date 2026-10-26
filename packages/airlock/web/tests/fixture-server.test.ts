import { type ChildProcessByStdio, spawn } from "node:child_process";
import { get as httpGet, request as httpRequest } from "node:http";
import type { Readable } from "node:stream";
import { Effect, Stream } from "effect";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import WebSocket from "ws";
import type { SubscriptionQuery } from "../src/data/protocol.ts";
import type { ViewState } from "../src/data/reducer.ts";
import {
  makeMemoryDataLayerWithFactory,
  openBrowserSocket,
  Subscriptions,
} from "../src/data/services.ts";

import { clientTranscript, serverFrame } from "./protocol-fixtures.ts";

const host = "127.0.0.1";
const port = 5198;
const origin = `http://${host}:5173`;
const auth = clientTranscript.find((frame) => frame.type === "auth");
if (auth === undefined) throw new Error("missing auth fixture");
const token = auth.token;

function health() {
  return new Promise<boolean>((resolve, reject) => {
    const request = httpGet(
      { host, port, path: "/healthz", timeout: 500 },
      (response) => {
        response.resume();
        resolve(response.statusCode === 200);
      },
    );
    request.on("timeout", () =>
      request.destroy(new Error("health check timed out")),
    );
    request.on("error", reject);
  });
}

async function startServer() {
  const child = spawn(process.execPath, ["fixtures/server.mjs"], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      AIRLOCK_FIXTURE_HOST: host,
      AIRLOCK_FIXTURE_PORT: String(port),
      AIRLOCK_FIXTURE_HOST_HEADER: `${host}:${port}`,
      AIRLOCK_FIXTURE_ORIGIN: origin,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const logs: string[] = [];
  child.stdout.on("data", (chunk) => logs.push(String(chunk)));
  child.stderr.on("data", (chunk) => logs.push(String(chunk)));
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (await health().catch(() => false)) {
      return { child, logs };
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  child.kill("SIGTERM");
  throw new Error(`fixture server did not start: ${logs.join("")}`);
}

function connect(originOverride = origin) {
  return new WebSocket(
    `ws://${host}:${port}/api/v1/live?scenario=normal`,
    "airlock.v1",
    {
      headers: { Host: `${host}:${port}`, Origin: originOverride },
    },
  );
}

function opened(socket: WebSocket) {
  return new Promise<void>((resolve, reject) => {
    socket.once("open", () => resolve());
    socket.once("error", reject);
  });
}

function messageQueue(socket: WebSocket) {
  const queued: Record<string, unknown>[] = [];
  const waiting: Array<(frame: Record<string, unknown>) => void> = [];
  socket.on("message", (data) => {
    const frame = JSON.parse(String(data)) as Record<string, unknown>;
    const next = waiting.shift();
    if (next === undefined) queued.push(frame);
    else next(frame);
  });
  return () =>
    queued.length > 0
      ? Promise.resolve(queued.shift() as Record<string, unknown>)
      : new Promise<Record<string, unknown>>((resolve) =>
          waiting.push(resolve),
        );
}

function closed(socket: WebSocket) {
  if (socket.readyState === WebSocket.CLOSED) return Promise.resolve();
  return new Promise<void>((resolve) => socket.once("close", resolve));
}

function fixtureLayer(scenario: string) {
  const sent: string[][] = [];
  return {
    sent,
    layer: makeMemoryDataLayerWithFactory(
      { url: `ws://${host}:${port}/api/v1/live`, token },
      {
        open: () => {
          const socket = new WebSocket(
            `ws://${host}:${port}/api/v1/live?scenario=${scenario}`,
            "airlock.v1",
            { headers: { Host: `${host}:${port}`, Origin: origin } },
          );
          const records: string[] = [];
          const send = socket.send.bind(socket) as (data: string) => unknown;
          socket.send = ((data: unknown) => {
            const frame = String(data);
            records.push(frame);
            return send(frame);
          }) as typeof socket.send;
          sent.push(records);
          return openBrowserSocket(socket as unknown as globalThis.WebSocket);
        },
      },
      { retryInitialMs: 10 },
    ),
  };
}

async function runFixtureScenario(
  scenario: string,
  query: SubscriptionQuery,
  finished: (state: ViewState) => boolean,
): Promise<{ states: ViewState[]; sent: string[][] }> {
  const fixture = fixtureLayer(scenario);
  const states: ViewState[] = [];
  const program = Effect.gen(function* () {
    const stream = yield* Subscriptions.useSync((service) =>
      service.stream(query),
    );
    const pull = yield* Stream.toPull(stream);
    for (let index = 0; index < 1_000; index += 1) {
      const chunk = yield* pull;
      for (const state of chunk) {
        states.push(state);
        if (finished(state)) return;
      }
    }
    throw new Error("fixture subscription never reached its expected state");
  });
  await Effect.runPromise(
    Effect.scoped(Effect.provide(program, fixture.layer)),
  );
  return { states, sent: fixture.sent };
}

async function runFixtureSubscription(
  scenario: string,
  query: SubscriptionQuery,
  finished: (state: ViewState) => boolean,
): Promise<ViewState[]> {
  const { states } = await runFixtureScenario(scenario, query, finished);
  return states;
}

async function liveState(
  scenario: string,
  query: SubscriptionQuery,
): Promise<ViewState> {
  const states = await runFixtureSubscription(
    scenario,
    query,
    (state) => state.phase === "live",
  );
  const state = states.at(-1);
  if (state === undefined) throw new Error("fixture produced no final state");
  return state;
}

describe("fixture backend", () => {
  let child: ChildProcessByStdio<null, Readable, Readable> | undefined;
  let logs: string[] = [];

  beforeAll(async () => {
    const server = await startServer();
    child = server.child;
    logs = server.logs;
  });

  afterAll(() => {
    child?.kill("SIGTERM");
  });

  it("serves the fake local protocol to valid origin, auth, and subscription", async () => {
    const socket = connect();
    const next = messageQueue(socket);
    await opened(socket);
    expect(socket.protocol).toBe("airlock.v1");

    socket.send(JSON.stringify(auth));
    await expect(next()).resolves.toEqual({
      ...serverFrame("hello"),
      server_time_unix: 1200,
    });

    socket.send(
      JSON.stringify({
        v: 1,
        type: "subscribe",
        id: "usage-overview",
        kind: "usage.overview",
        query: {},
      }),
    );
    await expect(next()).resolves.toMatchObject({
      type: "subscribed",
      id: "usage-overview",
    });
    await expect(next()).resolves.toMatchObject({
      type: "snapshot",
      id: "usage-overview",
      epoch: expect.stringMatching(/^fixture-epoch-/),
      seq: 1,
    });
    await expect(next()).resolves.toMatchObject({
      type: "delta",
      id: "usage-overview",
      epoch: expect.stringMatching(/^fixture-epoch-/),
      seq: 2,
      prev_seq: 1,
      upserts: { credentials: [] },
      removes: { credentials: [] },
    });

    socket.send(
      JSON.stringify({
        v: 1,
        type: "ack",
        id: "usage-overview",
        epoch: "fixture-epoch-1",
        seq: 2,
      }),
    );
    socket.send(
      JSON.stringify({ v: 1, type: "unsubscribe", id: "usage-overview" }),
    );
    await expect(next()).resolves.toMatchObject({
      type: "unsubscribed",
      id: "usage-overview",
    });
    await new Promise((resolve) => setTimeout(resolve, 20));

    socket.close();
    await closed(socket);
    expect(logs.join("")).not.toContain(token);
  });

  it("preserves request page metadata on deltas and rejects an active ID with a changed query", async () => {
    const socket = connect();
    const next = messageQueue(socket);
    await opened(socket);
    socket.send(JSON.stringify(auth));
    await next();
    const subscribe = {
      v: 1,
      type: "subscribe",
      id: "page",
      kind: "requests.table",
      query: { window: { last_seconds: 600 }, limit: 2 },
    };
    socket.send(JSON.stringify(subscribe));
    await next();
    const snapshot = await next();
    const delta = await next();
    expect(snapshot.meta).toMatchObject({
      has_more: true,
      next_before: "2",
      oldest_at_unix: 1000,
    });
    expect(delta.meta).toMatchObject({
      has_more: true,
      next_before: "2",
      oldest_at_unix: 1000,
    });
    socket.send(
      JSON.stringify({
        ...subscribe,
        query: { window: { last_seconds: 600 }, limit: 1 },
      }),
    );
    await expect(next()).resolves.toMatchObject({
      type: "error",
      id: "page",
      code: "subscription_conflict",
    });
    socket.close();
    await closed(socket);
  });

  it.each([
    { window: { last_seconds: 0 }, limit: 2 },
    { window: { last_seconds: 600 }, limit: 201 },
    { window: { since_unix: 1100, until_unix: 900 }, limit: 2 },
    { window: { last_seconds: 600 }, limit: 2, before: "" },
    { window: { last_seconds: 600 }, limit: 2, future: true },
  ])(
    "rejects invalid table queries with the shared client decoder: %j",
    async (query) => {
      const socket = connect();
      const next = messageQueue(socket);
      await opened(socket);
      socket.send(JSON.stringify(auth));
      await next();
      socket.send(
        JSON.stringify({
          v: 1,
          type: "subscribe",
          id: "invalid-table",
          kind: "requests.table",
          query,
        }),
      );
      await expect(next()).resolves.toMatchObject({
        type: "error",
        code: "invalid_query",
        retryable: false,
      });
      socket.close();
      await closed(socket);
    },
  );

  it("accepts reordered fresh query fields and nested window fields", async () => {
    const first = connect();
    const firstNext = messageQueue(first);
    await opened(first);
    first.send(JSON.stringify(auth));
    await firstNext();
    first.send(
      JSON.stringify({
        v: 1,
        type: "subscribe",
        id: "reordered",
        kind: "requests.table",
        query: { window: { since_unix: 900, until_unix: 1100 }, limit: 2 },
      }),
    );
    const firstSubscribed = await firstNext();
    const firstSnapshot = await firstNext();
    await firstNext();
    first.close();
    await closed(first);

    const second = connect();
    const secondNext = messageQueue(second);
    await opened(second);
    second.send(JSON.stringify(auth));
    await secondNext();
    second.send(
      JSON.stringify({
        v: 1,
        type: "subscribe",
        id: "reordered",
        kind: "requests.table",
        query: { limit: 2, window: { until_unix: 1100, since_unix: 900 } },
      }),
    );
    const secondSubscribed = await secondNext();
    const secondSnapshot = await secondNext();
    expect(secondSubscribed.epoch).not.toBe(firstSubscribed.epoch);
    expect(secondSnapshot).toMatchObject({
      type: "snapshot",
      seq: 1,
      collections: firstSnapshot.collections,
      meta: firstSnapshot.meta,
    });
    second.close();
    await closed(second);
  });

  it("drives every supported kind through the actual Effect layer", async () => {
    const overview = await liveState("normal", { kind: "usage.overview" });
    expect(overview.phase).toBe("live");
    expect(overview.entries.size).toBe(2);

    const filteredOverview = await liveState("normal", {
      kind: "usage.overview",
      provider: "provider-a",
    });
    expect(filteredOverview.entries.size).toBe(1);

    const series = await liveState("normal", {
      kind: "usage.series",
      provider: "provider-a",
      credential: "credential-a",
      source: "out_of_band_fetch",
      surface: "zai_quota",
      window: { last_seconds: 600 },
      limit: 100,
    });
    expect(series.entries.size).toBe(2);

    const firstPage = await liveState("normal", {
      kind: "requests.table",
      window: { last_seconds: 600 },
      limit: 2,
    });
    expect(firstPage.entries.size).toBe(2);
    expect(firstPage.meta).toMatchObject({ has_more: true, next_before: "2" });

    const secondPage = await liveState("normal", {
      kind: "requests.table",
      window: { last_seconds: 600 },
      limit: 2,
      before: "2",
    });
    expect(secondPage.entries.size).toBe(1);
    expect(secondPage.meta).toMatchObject({
      has_more: false,
      next_before: null,
    });

    const requestSeries = await liveState("normal", {
      kind: "requests.series",
      window: { last_seconds: 600 },
      bucket_seconds: 60,
      provider: "provider-a",
      model: "model-a",
    });
    expect(requestSeries.entries.size).toBe(1);
    const aggregate = [...requestSeries.entries.values()][0];
    expect(aggregate).toMatchObject({ bucket_start_unix: 960 });
    expect(requestSeries.meta?.window).toEqual({
      since_unix: 600,
      until_unix: 1200,
    });
  });

  it("applies exact provider, credential, page, and fixed-window filters", async () => {
    const absentProvider = await liveState("normal", {
      kind: "usage.series",
      provider: "provider-b",
      credential: "credential-a",
      source: "out_of_band_fetch",
      surface: "zai_quota",
      window: { since_unix: 900, until_unix: 1100 },
      limit: 100,
    });
    expect(absentProvider.entries.size).toBe(0);
    expect(absentProvider.intervalMs).toBe(5000);
    expect(absentProvider.meta?.window).toEqual({
      since_unix: 900,
      until_unix: 1100,
    });

    const outsideWindow = await liveState("normal", {
      kind: "requests.table",
      window: { since_unix: 0, until_unix: 100 },
      limit: 2,
    });
    expect(outsideWindow.entries.size).toBe(0);
    expect(outsideWindow.intervalMs).toBe(1000);

    const selected = await liveState("normal", {
      kind: "requests.series",
      window: { last_seconds: 600 },
      bucket_seconds: 300,
      provider: "provider-a",
      credential: "credential-a",
      client: null,
    });
    expect([...selected.entries.values()][0]).toMatchObject({
      bucket_start_unix: 900,
    });
    const excluded = await liveState("normal", {
      kind: "requests.series",
      window: { last_seconds: 600 },
      bucket_seconds: 300,
      client: "different-client",
    });
    expect(excluded.entries.size).toBe(0);
  });

  it("rejects logs.tail through the actual Effect layer", async () => {
    const states = await runFixtureSubscription(
      "normal",
      {
        kind: "logs.tail",
        stream: "requests",
        limit: 10,
      },
      (state) => state.phase === "failed",
    );
    expect(states.at(-1)).toMatchObject({
      phase: "failed",
      error: "unsupported_subscription",
      terminal: true,
    });
  });

  it("reconnects with fresh authentication and subscriptions after disconnect", async () => {
    const seenLiveEpochs = new Set<string>();
    const result = await runFixtureScenario(
      "disconnect",
      {
        kind: "usage.overview",
      },
      (state) => {
        if (state.phase === "live" && state.epoch !== null)
          seenLiveEpochs.add(state.epoch);
        return seenLiveEpochs.size >= 2;
      },
    );
    expect(result.sent).toHaveLength(2);
    const secondAuth = JSON.parse(result.sent[1]?.[0] ?? "{}") as Record<
      string,
      unknown
    >;
    const secondSubscribe = JSON.parse(result.sent[1]?.[1] ?? "{}") as Record<
      string,
      unknown
    >;
    expect(secondAuth).not.toHaveProperty("resume_session");
    expect(secondSubscribe).not.toHaveProperty("resume");
    expect([...seenLiveEpochs]).toHaveLength(2);
    expect(result.states.some((state) => state.phase === "reconnecting")).toBe(
      true,
    );
    expect(result.states.at(-1)?.lastSeq).toBe(1);
  });

  it("recovers from a deterministic slow consumer with a fresh snapshot", async () => {
    let overflowed = false;
    const result = await runFixtureScenario(
      "client-overflow",
      { kind: "usage.overview" },
      (state) => {
        if (state.gap?.code === "client_overflow") overflowed = true;
        return overflowed && state.phase === "live";
      },
    );
    expect(overflowed).toBe(true);
    expect(result.sent).toHaveLength(2);
    const retrySubscribe = JSON.parse(result.sent[1]?.[1] ?? "{}") as Record<
      string,
      unknown
    >;
    expect(retrySubscribe).toMatchObject({ type: "subscribe" });
    expect(retrySubscribe).not.toHaveProperty("resume");
  });

  it("reports a server slow_consumer gap separately from client overflow", async () => {
    const states = await runFixtureSubscription(
      "slow-consumer",
      { kind: "usage.overview" },
      (state) => state.gap?.code === "slow_consumer",
    );
    expect(states.at(-1)?.gap?.code).toBe("slow_consumer");
  });

  it.each(["malformed", "unknown-field", "unsafe-number"])(
    "fails loudly for %s frames",
    async (scenario) => {
      const states = await runFixtureSubscription(
        scenario,
        { kind: "usage.overview" },
        (state) => state.phase === "failed",
      );
      expect(states.at(-1)).toMatchObject({ phase: "failed", terminal: true });
    },
  );

  it.each([
    ["stale", "stale", []],
    ["partial", "fresh", ["seven_day_unavailable"]],
    ["failed", "unavailable", []],
    ["console-gap", "fresh", []],
  ] as const)(
    "exposes %s as distinct metadata",
    async (scenario, status, partialGaps) => {
      const state = await liveState(scenario, { kind: "usage.overview" });
      const row = [...state.entries.values()].find(
        (value) => "credential" in value && value.credential === "credential-a",
      );
      expect(row).toMatchObject({ status });
      if (row && "latest_fetch" in row && row.latest_fetch !== null) {
        expect(row.latest_fetch.partial_gaps).toEqual(partialGaps);
      }
      if (scenario === "console-gap") {
        expect(state.meta?.known_gaps).toContain(
          "console_balance_requires_ant_auth_login",
        );
      }
      if (scenario === "failed") {
        expect(state.meta?.known_gaps).toContain("usage_timeout");
      }
    },
  );

  it("rejects a foreign origin before WebSocket upgrade", async () => {
    const status = await new Promise<number>((resolve, reject) => {
      const request = httpRequest(
        {
          host,
          port,
          path: "/api/v1/live?scenario=normal",
          headers: {
            Connection: "Upgrade",
            Host: `${host}:${port}`,
            Origin: "http://127.0.0.1:9999",
            "Sec-WebSocket-Key": "AAAAAAAAAAAAAAAAAAAAAA==",
            "Sec-WebSocket-Version": "13",
            Upgrade: "websocket",
          },
          timeout: 500,
        },
        (response) => {
          response.resume();
          resolve(response.statusCode ?? 0);
        },
      );
      request.on("timeout", () =>
        request.destroy(new Error("upgrade check timed out")),
      );
      request.on("error", reject);
      request.end();
    });
    expect(status).toBe(403);
  });
});
