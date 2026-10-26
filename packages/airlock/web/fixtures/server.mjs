import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { WebSocketServer } from "ws";
import { decodeClientFrameSync } from "../src/data/protocol.ts";

const clientTranscript = JSON.parse(
  readFileSync(
    new URL(
      "../../web-fixtures/protocol-v1-client-transcript.json",
      import.meta.url,
    ),
  ),
);
const serverTranscript = JSON.parse(
  readFileSync(
    new URL(
      "../../web-fixtures/protocol-v1-server-transcript.json",
      import.meta.url,
    ),
  ),
);
const frames = Object.fromEntries(
  serverTranscript
    .filter((frame) => frame.meta?.chart === undefined)
    .map((frame) => [frame.type, frame]),
);
const args = new Set(process.argv.slice(2));
const scenarioIndex = process.argv.indexOf("--scenario");
const defaultScenario =
  scenarioIndex >= 0 ? process.argv[scenarioIndex + 1] : "normal";
const host = process.env.AIRLOCK_FIXTURE_HOST ?? "127.0.0.1";
const port = Number(process.env.AIRLOCK_FIXTURE_PORT ?? 5178);
const expectedOrigin =
  process.env.AIRLOCK_FIXTURE_ORIGIN ?? "http://127.0.0.1:5173";
const expectedHost =
  process.env.AIRLOCK_FIXTURE_HOST_HEADER ?? "127.0.0.1:5173";
const token = clientTranscript[0].token;
const nowUnix = 1_200;
const chartNowUnix = 1_800_000_000;
const cadence = {
  "requests.chart": 5_000,
  "requests.table": 1_000,
  "usage.overview": 5_000,
  "usage.series": 5_000,
};
let nextEpoch = 0;
const scenarioTriggered = new Set();
const timers = new Set();

function reject(socket, status, reason) {
  socket.write(`HTTP/1.1 ${status} ${reason}\r\nConnection: close\r\n\r\n`);
  socket.destroy();
}

function key(value) {
  return JSON.stringify(value);
}

function normalizedQuery(query) {
  const normalize = (value) =>
    value !== null && typeof value === "object" && !Array.isArray(value)
      ? Object.fromEntries(
          Object.entries(value)
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([name, field]) => [name, normalize(field)]),
        )
      : value;
  return key(normalize(query));
}

function resolvedWindow(query) {
  if (query.kind === "usage.overview") return null;
  const now = query.kind === "requests.chart" ? chartNowUnix : nowUnix;
  if ("all" in query.window)
    return { since_unix: chartNowUnix - 37 * 86400, until_unix: now };
  return "last_seconds" in query.window
    ? {
        since_unix: Math.max(1, now - query.window.last_seconds),
        until_unix: now,
      }
    : query.window;
}

function meta(query, scenario, oldest = null, more = false, nextBefore = null) {
  return {
    ...frames.snapshot.meta,
    as_of_unix: query.kind === "requests.chart" ? chartNowUnix : nowUnix,
    window: resolvedWindow(query),
    oldest_at_unix: oldest,
    has_more: more,
    next_before: nextBefore,
    known_gaps:
      scenario === "console-gap"
        ? ["console_balance_requires_ant_auth_login"]
        : scenario === "failed"
          ? ["usage_timeout"]
          : [],
  };
}

function credential(name = "credential-a", scenario = "normal") {
  return {
    account_id: null,
    client: null,
    group: null,
    credential: name,
    provider: name === "credential-b" ? "provider-b" : "provider-a",
    surface: "surface-a",
    auth: "api_key",
    explicit_usage_selection: false,
    global_quota_complete: scenario !== "partial",
    header_age_seconds: null,
    latest_fetch:
      name === "credential-a" && scenario !== "console-gap"
        ? snapshotRow(1_000, scenario)
        : null,
    latest_header: null,
    status:
      scenario === "stale"
        ? "stale"
        : scenario === "failed"
          ? "unavailable"
          : "fresh",
    routes: [],
  };
}

function snapshotRow(fetchedAt = 1_000, scenario = "normal") {
  return {
    account_id: "fixture-account-a",
    credential: "credential-a",
    provider: "provider-a",
    client: null,
    group: null,
    gap_reason: scenario === "failed" ? "usage_timeout" : null,
    fetched_at_unix: fetchedAt,
    source: "out_of_band_fetch",
    surface: "zai_quota",
    status:
      scenario === "stale"
        ? "stale"
        : scenario === "failed"
          ? "unavailable"
          : "fresh",
    claude_limits: [],
    credits: [],
    header_windows: [],
    metrics: [],
    pools: [],
    partial_gaps: scenario === "partial" ? ["seven_day_unavailable"] : [],
  };
}

function requestRow(id = "1") {
  return {
    id,
    occurred_at_unix: 1_000,
    client: null,
    group: "group-a",
    credential: "credential-a",
    provider: "provider-a",
    model: "model-a",
    outcome: "completed",
    status_code: 200,
    latency_ms: 10,
    request_bytes: 10,
    response_bytes: 10,
    input_tokens: 1,
    output_tokens: 1,
    cache_read_tokens: null,
    cache_write_tokens: null,
    usage_complete: true,
  };
}

function chartRows(query) {
  const window = resolvedWindow(query);
  const days =
    Math.floor((window.until_unix - 1) / 86400) -
    Math.floor(window.since_unix / 86400) +
    1;
  const bucket =
    "all" in query.window
      ? Math.max(1, Math.ceil(days / 32)) * 86400
      : window.until_unix - window.since_unix <= 2 * 86400
        ? 3600
        : 86400;
  const events = [
    { ...requestRow(), occurred_at_unix: chartNowUnix - 200 },
    {
      ...requestRow("old"),
      occurred_at_unix: chartNowUnix - 37 * 86400,
      client: "harness",
    },
  ];
  const rows = new Map();
  for (const event of events.filter(
    (row) => matchesQuery(query, row) && inWindow(query, row.occurred_at_unix),
  )) {
    const identity = [
      Math.floor(event.occurred_at_unix / bucket) * bucket,
      ...query.dimensions.map((dimension) => event[dimension]),
    ];
    const id = key(identity);
    const row = rows.get(id) ?? {
      key: id,
      value: [...identity, 0, 0, 0, 0, 0, 0, 0],
    };
    const offset = identity.length;
    row.value[offset] += 1;
    row.value[offset + 1] += Number(event.usage_complete);
    row.value[offset + 2] += Number(event.status_code >= 400);
    [
      "cache_read_tokens",
      "cache_write_tokens",
      "input_tokens",
      "output_tokens",
    ].forEach((field, index) => {
      const at = offset + 3 + index;
      row.value[at] =
        row.value[at] === null || event[field] === null
          ? null
          : row.value[at] + event[field];
    });
    rows.set(id, row);
  }
  return { rows: [...rows.values()], bucket };
}

function resetRow() {
  return {
    credential: "credential-a",
    pool: "pool-a",
    provider: "provider-a",
    surface: "zai_quota",
    detected_at_unix: 1_000,
    reset_at_unix: null,
    kind: "credit_refill",
  };
}

function matchesQuery(query, row) {
  if (query.provider !== undefined && row.provider !== query.provider)
    return false;
  if (query.credential !== undefined && row.credential !== query.credential) {
    return false;
  }
  if (query.client !== undefined && row.client !== query.client) return false;
  if (query.group !== undefined && row.group !== query.group) return false;
  if (query.model !== undefined && row.model !== query.model) return false;
  if (query.outcome !== undefined && row.outcome !== query.outcome)
    return false;
  return true;
}

function inWindow(query, unix) {
  const window = resolvedWindow(query);
  return (
    window === null || (unix >= window.since_unix && unix < window.until_unix)
  );
}

function tablePage(query) {
  const descending = [requestRow("3"), requestRow("2"), requestRow("1")];
  const filtered = descending.filter(
    (row) => matchesQuery(query, row) && inWindow(query, row.occurred_at_unix),
  );
  const after =
    query.before === undefined || query.before === null
      ? filtered
      : filtered.filter((row) => Number(row.id) < Number(query.before));
  const rows = after.slice(0, query.limit);
  const hasMore = after.length > rows.length;
  return {
    rows,
    hasMore,
    nextBefore: hasMore ? (rows.at(-1)?.id ?? null) : null,
  };
}

function rowsForQuery(query, scenario) {
  switch (query.kind) {
    case "usage.overview": {
      return [
        credential("credential-a", scenario),
        credential("credential-b", scenario),
      ].filter((row) => matchesQuery(query, row));
    }
    case "usage.series":
      return [snapshotRow(1_000, scenario), resetRow()];
    case "requests.table":
      return tablePage(query).rows;
    default:
      return [];
  }
}

function collections(query, scenario) {
  switch (query.kind) {
    case "usage.overview":
      return {
        credentials: rowsForQuery(query, scenario).map((value) => ({
          key: key([value.provider, value.credential]),
          value,
        })),
      };
    case "usage.series":
      return {
        snapshots: rowsForQuery(query, scenario)
          .filter(
            (value) =>
              "fetched_at_unix" in value &&
              matchesQuery(query, value) &&
              value.source === query.source &&
              value.surface === query.surface &&
              inWindow(query, value.fetched_at_unix),
          )
          .slice(0, query.limit)
          .map((value) => ({
            key: "snapshot-1",
            value,
          })),
        reset_events:
          inWindow(query, 1_000) &&
          query.provider === "provider-a" &&
          query.credential === "credential-a" &&
          query.source === "out_of_band_fetch" &&
          query.surface === "zai_quota"
            ? [
                {
                  key: key([
                    "snapshot-0",
                    "snapshot-1",
                    "credit",
                    "pool-a",
                    "credit_refill",
                  ]),
                  value: resetRow(),
                },
              ]
            : [],
      };
    case "requests.table":
      return {
        requests: tablePage(query).rows.map((value) => ({
          key: value.id,
          value,
        })),
      };
    case "requests.chart":
      return { request_chart: chartRows(query).rows };
    default:
      return {};
  }
}

function unchangedCollections(query, scenario) {
  return Object.fromEntries(
    Object.keys(collections(query, scenario)).map((name) => [name, []]),
  );
}

function subscribedFrame(id, kind, epoch) {
  return {
    ...frames.subscribed,
    id,
    epoch,
    interval_ms: cadence[kind],
  };
}

function viewMeta(query, scenario) {
  const page = query.kind === "requests.table" ? tablePage(query) : undefined;
  const metadata = meta(
    query,
    scenario,
    page?.rows.at(-1)?.occurred_at_unix ?? null,
    page?.hasMore ?? false,
    page?.nextBefore ?? null,
  );
  if (query.kind === "requests.chart") {
    metadata.oldest_at_unix = chartNowUnix - 37 * 86400;
    metadata.chart = {
      bucket_seconds: chartRows(query).bucket,
      dimensions: query.dimensions,
    };
  }
  return metadata;
}

function snapshotFrame(query, scenario, id, epoch) {
  return {
    ...frames.snapshot,
    id,
    epoch,
    collections: collections(query, scenario),
    meta: viewMeta(query, scenario),
  };
}

function deltaFrame(query, scenario, id, epoch, seq) {
  const unchanged = unchangedCollections(query, scenario);
  return {
    ...frames.delta,
    id,
    epoch,
    seq,
    prev_seq: seq - 1,
    upserts: unchanged,
    removes: unchanged,
    meta: viewMeta(query, scenario),
  };
}

function errorFrame(id, code, retryable = false) {
  return { ...frames.error, id, code, retryable };
}

function scheduleClose(socket) {
  const timer = setTimeout(() => socket.close(), 20);
  timers.add(timer);
  timer.unref?.();
  socket.once("close", () => {
    clearTimeout(timer);
    timers.delete(timer);
  });
}

const server = createServer((request, response) => {
  if (request.url === "/healthz") {
    response.writeHead(200, {
      "Cache-Control": "no-store",
      "Content-Type": "application/json",
    });
    response.end(JSON.stringify({ ok: true, scenario: defaultScenario }));
    return;
  }
  response.writeHead(404, {
    "Cache-Control": "no-store",
    "Content-Type": "application/json",
  });
  response.end(
    JSON.stringify({
      api_version: 1,
      error: { code: "not_found", retryable: false },
    }),
  );
});

const wss = new WebSocketServer({
  noServer: true,
  handleProtocols: (protocols) =>
    protocols.has("airlock.v1") ? "airlock.v1" : false,
});

server.on("upgrade", (request, socket) => {
  if (
    request.headers.origin !== expectedOrigin ||
    request.headers.host !== expectedHost
  ) {
    reject(socket, 403, "Forbidden");
    return;
  }
  wss.handleUpgrade(request, socket, request.headers, (socket) =>
    wss.emit("connection", socket, request),
  );
});

wss.on("connection", (socket, request) => {
  if (socket.protocol !== "airlock.v1") {
    socket.close(1002, "unsupported protocol");
    return;
  }
  const url = new URL(request.url ?? "/api/v1/live", `http://${expectedHost}`);
  const scenario = url.searchParams.get("scenario") ?? defaultScenario;
  let authenticated = false;
  const active = new Map();

  socket.on("message", (data, isBinary) => {
    if (isBinary) return;
    let frame;
    try {
      frame = JSON.parse(String(data));
    } catch {
      socket.close(1002, "invalid frame");
      return;
    }
    try {
      frame = decodeClientFrameSync(frame);
    } catch {
      socket.send(
        JSON.stringify(
          errorFrame(null, authenticated ? "invalid_query" : "unauthorized"),
        ),
      );
      if (!authenticated) socket.close(1008, "unauthorized");
      return;
    }
    if (!authenticated) {
      if (frame.type !== "auth" || frame.token !== token) {
        socket.send(JSON.stringify(errorFrame(null, "unauthorized")));
        socket.close(1008, "unauthorized");
        return;
      }
      authenticated = true;
      nextEpoch += 1;
      socket.send(
        JSON.stringify({
          ...frames.hello,
          server_time_unix: nowUnix,
        }),
      );
      return;
    }

    if (frame.type === "subscribe") {
      if (
        active.size >= frames.hello.limits.max_subscriptions &&
        !active.has(frame.id)
      ) {
        socket.send(
          JSON.stringify(errorFrame(frame.id, "resource_limit", true)),
        );
        return;
      }
      if (frame.kind === "logs.tail") {
        socket.send(
          JSON.stringify(errorFrame(frame.id, "unsupported_subscription")),
        );
        return;
      }
      const query = { kind: frame.kind, ...frame.query };
      if (
        active.has(frame.id) &&
        normalizedQuery(active.get(frame.id)) !== normalizedQuery(query)
      ) {
        socket.send(
          JSON.stringify(errorFrame(frame.id, "subscription_conflict")),
        );
        return;
      }
      const epoch = `fixture-epoch-${++nextEpoch}`;
      active.set(frame.id, query);
      socket.send(JSON.stringify(subscribedFrame(frame.id, frame.kind, epoch)));
      const snapshot = snapshotFrame(query, scenario, frame.id, epoch);
      if (scenario === "malformed") {
        socket.send("{");
        return;
      }
      if (scenario === "unknown-field") {
        socket.send(JSON.stringify({ ...snapshot, future: 1 }));
        return;
      }
      if (scenario === "unsafe-number") {
        socket.send(
          JSON.stringify({
            ...snapshot,
            meta: {
              ...snapshot.meta,
              as_of_unix: Number.MAX_SAFE_INTEGER + 1,
            },
          }),
        );
        return;
      }
      socket.send(JSON.stringify(snapshot));
      if (scenario === "disconnect" && !scenarioTriggered.has(scenario)) {
        scenarioTriggered.add(scenario);
        scheduleClose(socket);
        return;
      }
      if (scenario === "slow-consumer" && !scenarioTriggered.has(scenario)) {
        scenarioTriggered.add(scenario);
        socket.send(
          JSON.stringify({
            ...frames.gap,
            id: frame.id,
            epoch,
            after_seq: 1,
            code: "slow_consumer",
            retryable: true,
            action: "resnapshot",
          }),
        );
        scheduleClose(socket);
        return;
      }
      if (scenario === "client-overflow" && !scenarioTriggered.has(scenario)) {
        scenarioTriggered.add(scenario);
        for (let seq = 2; seq <= 100; seq += 1) {
          socket.send(
            JSON.stringify(deltaFrame(query, scenario, frame.id, epoch, seq)),
          );
        }
        scheduleClose(socket);
        return;
      }
      const delta = deltaFrame(query, scenario, frame.id, epoch, 2);
      socket.send(JSON.stringify(delta));
      return;
    }

    if (frame.type === "unsubscribe") {
      active.delete(frame.id);
      socket.send(JSON.stringify({ ...frames.unsubscribed, id: frame.id }));
      return;
    }
    if (frame.type === "ack" || frame.type === "pong") return;
    socket.close(1002, "invalid frame");
  });
});

server.listen(port, host, () => {
  console.log(
    `Airlock fixture listening on http://${host}:${port} scenario=${defaultScenario}`,
  );
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    for (const timer of timers) clearTimeout(timer);
    wss.close();
    server.close(() => process.exit(0));
  });
}
if (args.has("--check")) process.exit(0);
