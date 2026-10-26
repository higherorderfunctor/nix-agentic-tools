import { Effect } from "effect";
import { describe, expect, it } from "vitest";
import type { ClientFrame } from "../src/data/protocol.ts";
import {
  decodeServerFrame,
  decodeServerJson,
  decodeSubscriptionQuery,
  encodeClientFrame,
  encodeClientFrameSync,
} from "../src/data/protocol.ts";

import { serverFrame } from "./protocol-fixtures.ts";

const metadata = {
  ...serverFrame("snapshot").meta,
  as_of_unix: 100,
  window: null,
};
const snapshot = {
  ...serverFrame("snapshot"),
  id: "overview-1",
  epoch: "epoch-a",
  collections: { credentials: [] },
  meta: metadata,
};

async function failure(input: unknown) {
  return Effect.runPromise(Effect.flip(decodeServerFrame(input)));
}

describe("server frame decoding", () => {
  it("accepts an exact closed snapshot frame", async () => {
    await expect(
      Effect.runPromise(decodeServerFrame(snapshot)),
    ).resolves.toMatchObject({
      type: "snapshot",
      id: "overview-1",
    });
  });

  it("rejects unknown fields without retaining the raw payload", async () => {
    const hostile = { ...snapshot, debug_payload: "secret-request-content" };
    const error = await failure(hostile);
    expect(error._tag).toBe("ProtocolDecodeError");
    expect(error.reason).toBe("schema_mismatch");
    expect(JSON.stringify(error)).not.toContain("secret-request-content");
  });

  it("rejects unsupported enum values and unknown nested fields", async () => {
    const enumFailure = await failure({ ...snapshot, type: "sse" });
    expect(enumFailure._tag).toBe("ProtocolDecodeError");
    const nestedFailure = await failure({
      ...snapshot,
      meta: { ...metadata, future_field: true },
    });
    expect(nestedFailure).toMatchObject({
      _tag: "ProtocolDecodeError",
      reason: "schema_mismatch",
    });
  });

  it("rejects unsafe integers as numeric range failures", async () => {
    const unsafe = await failure({
      ...snapshot,
      meta: { ...metadata, request_loss_total: Number.MAX_SAFE_INTEGER + 1 },
    });
    expect(unsafe._tag).toBe("ProtocolDecodeError");
  });

  it("rejects malformed JSON without exposing its content", async () => {
    const error = await Effect.runPromise(
      Effect.flip(decodeServerJson('{"v":1,"token":"secret"')),
    );
    expect(error).toMatchObject({
      _tag: "ProtocolDecodeError",
      reason: "invalid_json",
    });
    expect(JSON.stringify(error)).not.toContain("secret");
  });
});

describe("closed query and frame boundaries", () => {
  const credentialValue = {
    account_id: null,
    client: "harness",
    group: "anthropic",
    credential: "claude",
    provider: "claude",
    surface: "claude_subscription",
    auth: "oauth_bearer" as const,
    explicit_usage_selection: false,
    global_quota_complete: false,
    header_age_seconds: 1,
    latest_fetch: null,
    latest_header: null,
    status: "fresh" as const,
    routes: [],
  };

  function frameWithCollection(collections: Record<string, unknown>): unknown {
    return { ...snapshot, collections, meta: metadata };
  }

  it("requires request row ids and canonical entry keys", async () => {
    const request = {
      key: "17",
      value: {
        id: "17",
        occurred_at_unix: 1,
        client: null,
        group: "anthropic",
        credential: "claude",
        provider: "claude",
        model: "claude",
        outcome: "completed",
        status_code: 200,
        latency_ms: 1,
        request_bytes: 1,
        response_bytes: 1,
        input_tokens: null,
        output_tokens: null,
        cache_read_tokens: null,
        cache_write_tokens: null,
        usage_complete: true,
      },
    };
    await expect(
      Effect.runPromise(
        decodeServerFrame(frameWithCollection({ requests: [request] })),
      ),
    ).resolves.toMatchObject({ type: "snapshot" });
    await expect(
      failure(frameWithCollection({ requests: [{ ...request, key: "17a" }] })),
    ).resolves.toMatchObject({ reason: "entry_key_mismatch" });
    await expect(
      failure(
        frameWithCollection({
          requests: [{ ...request, value: { ...request.value, id: "18" } }],
        }),
      ),
    ).resolves.toMatchObject({ reason: "entry_key_mismatch" });
  });

  it("validates credential keys against canonical identity tuples", async () => {
    await expect(
      failure(
        frameWithCollection({
          credentials: [{ key: "fixture-credential", value: credentialValue }],
        }),
      ),
    ).resolves.toMatchObject({ reason: "entry_key_mismatch" });
    await expect(
      Effect.runPromise(
        decodeServerFrame(
          frameWithCollection({
            credentials: [
              {
                key: JSON.stringify(["claude", "claude"]),
                value: credentialValue,
              },
            ],
          }),
        ),
      ),
    ).resolves.toMatchObject({ type: "snapshot" });
  });

  it("accepts the design identities for every collection", async () => {
    const credentialEntry = {
      key: JSON.stringify(["provider-a", "credential-a"]),
      value: {
        ...credentialValue,
        credential: "credential-a",
        provider: "provider-a",
      },
    };
    const snapshotEntry = {
      key: "123",
      value: {
        account_id: "a",
        credential: "credential-a",
        provider: "provider-a",
        client: null,
        group: null,
        gap_reason: null,
        fetched_at_unix: 1_792_886_400,
        source: "out_of_band_fetch",
        surface: "zai_quota",
        status: "fresh",
        claude_limits: [],
        credits: [],
        header_windows: [],
        metrics: [],
        pools: [],
        partial_gaps: [],
      },
    };
    const resetEntry = {
      key: JSON.stringify(["122", "123", "credit", "pool-a", "credit_refill"]),
      value: {
        credential: "credential-a",
        pool: "pool-a",
        provider: "provider-a",
        surface: "zai_quota",
        detected_at_unix: 1_792_886_400,
        reset_at_unix: null,
        kind: "credit_refill",
      },
    };
    await expect(
      failure(
        frameWithCollection({
          snapshots: [snapshotEntry],
          reset_events: [
            { ...resetEntry, key: resetEntry.key.replace(",", ", ") },
          ],
        }),
      ),
    ).resolves.toMatchObject({ reason: "entry_key_mismatch" });
    const requestEntry = {
      key: "42",
      value: {
        id: "42",
        occurred_at_unix: 1_792_886_400,
        client: null,
        group: "g",
        credential: "credential-a",
        provider: "provider-a",
        model: "m",
        outcome: "completed",
        status_code: 200,
        latency_ms: 1,
        request_bytes: 1,
        response_bytes: 1,
        input_tokens: null,
        output_tokens: null,
        cache_read_tokens: null,
        cache_write_tokens: null,
        usage_complete: true,
      },
    };
    const chartEntry = {
      key: JSON.stringify([1792886400, null, "m"]),
      value: [
        1792886400,
        null,
        "m",
        1,
        1,
        0,
        null,
        null,
        null,
        null,
        1,
        1,
        1,
        1,
      ],
    };

    await expect(
      Effect.runPromise(
        decodeServerFrame(
          frameWithCollection({ credentials: [credentialEntry] }),
        ),
      ),
    ).resolves.toMatchObject({ type: "snapshot" });
    await expect(
      Effect.runPromise(
        decodeServerFrame(
          frameWithCollection({
            snapshots: [snapshotEntry],
            reset_events: [resetEntry],
          }),
        ),
      ),
    ).resolves.toMatchObject({ type: "snapshot" });
    await expect(
      Effect.runPromise(
        decodeServerFrame(frameWithCollection({ requests: [requestEntry] })),
      ),
    ).resolves.toMatchObject({ type: "snapshot" });
    await expect(
      Effect.runPromise(
        decodeServerFrame({
          ...snapshot,
          collections: { request_chart: [chartEntry] },
          meta: {
            ...metadata,
            window: { since_unix: 1792886400, until_unix: 1792890000 },
            chart: { bucket_seconds: 3600, dimensions: ["client", "model"] },
          },
        }),
      ),
    ).resolves.toMatchObject({ type: "snapshot" });
  });

  it("accepts zero and real Unix timestamps while bounding only their difference", async () => {
    await expect(
      Effect.runPromise(
        decodeSubscriptionQuery({
          kind: "requests.table",
          window: { since_unix: 1_792_800_000, until_unix: 1_792_886_400 },
          limit: 100,
        }),
      ),
    ).resolves.toMatchObject({ kind: "requests.table" });
    await expect(
      Effect.runPromise(
        decodeSubscriptionQuery({
          kind: "requests.table",
          window: { since_unix: 0, until_unix: 100 },
          limit: 100,
        }),
      ),
    ).resolves.toMatchObject({ kind: "requests.table" });
    await expect(
      Effect.runPromise(
        Effect.flip(
          decodeSubscriptionQuery({
            kind: "requests.table",
            window: { since_unix: 0, until_unix: 604_801 },
            limit: 100,
          }),
        ),
      ),
    ).resolves.toMatchObject({ reason: "invalid_query" });
  });

  it("sends a closed query without the local kind discriminator", async () => {
    const subscribe = {
      v: 1,
      type: "subscribe",
      id: "quota-claude",
      kind: "usage.series",
      query: {
        provider: "claude",
        credential: "claude",
        source: "out_of_band_fetch",
        surface: "claude_subscription",
        window: { last_seconds: 86_400 },
        limit: 1000,
      },
    } as const;
    await expect(Effect.runPromise(encodeClientFrame(subscribe))).resolves.toBe(
      JSON.stringify({
        ...subscribe,
        query: {
          provider: "claude",
          credential: "claude",
          source: "out_of_band_fetch",
          surface: "claude_subscription",
          window: { last_seconds: 86_400 },
          limit: 1000,
        },
      }),
    );
    expect(
      JSON.parse(encodeClientFrameSync(subscribe)).query,
    ).not.toHaveProperty("kind");
  });

  it("rejects v1 reset completeness values other than null", async () => {
    const error = await failure({
      ...snapshot,
      meta: {
        ...metadata,
        reset_events_complete_since_unix: 100,
      },
    });
    expect(error).toMatchObject({ reason: "schema_mismatch" });
  });

  it("rejects invalid query domains without clamping", async () => {
    await expect(
      Effect.runPromise(
        Effect.flip(
          decodeSubscriptionQuery({
            kind: "requests.table",
            window: { last_seconds: 604_801 },
            limit: 1,
          }),
        ),
      ),
    ).resolves.toMatchObject({ reason: "invalid_query" });
    await expect(
      Effect.runPromise(
        Effect.flip(
          decodeSubscriptionQuery({
            kind: "requests.table",
            window: { last_seconds: 1 },
            limit: 201,
          }),
        ),
      ),
    ).resolves.toMatchObject({ reason: "invalid_query" });
    await expect(
      Effect.runPromise(
        Effect.flip(
          decodeSubscriptionQuery({
            kind: "requests.table",
            window: { since_unix: 20, until_unix: 10 },
            limit: 1,
          }),
        ),
      ),
    ).resolves.toMatchObject({ reason: "invalid_query" });
  });

  it("rejects retired resume fields on outbound subscribes", async () => {
    const retired = {
      v: 1,
      type: "subscribe",
      id: "usage-overview-1",
      kind: "usage.series",
      query: {
        provider: "provider-a",
        credential: "credential-a",
        source: "out_of_band_fetch",
        surface: "zai_quota",
        window: { last_seconds: 86_400 },
        limit: 1000,
      },
      resume: null,
    } as ClientFrame;
    await expect(
      Effect.runPromise(encodeClientFrame(retired)),
    ).rejects.toMatchObject({ reason: "schema_mismatch" });
  });

  it("bounds UTF-8 bytes before JSON parsing", async () => {
    const oversized = JSON.stringify({
      ...snapshot,
      collections: {
        credentials: [
          {
            key: "large",
            value: { ...credentialValue, credential: "x".repeat(1_100_000) },
          },
        ],
      },
    });
    await expect(
      Effect.runPromise(Effect.flip(decodeServerJson(oversized))),
    ).resolves.toMatchObject({ reason: "frame_byte_limit_exceeded" });
  });
});

describe("compact chart codec", () => {
  const entry = {
    key: JSON.stringify([0, null, "model-a"]),
    value: [0, null, "model-a", 12, 11, 2, null, 0, 100, 40, 12, 0, 3, 0],
  };
  const frame = {
    v: 1,
    type: "snapshot",
    id: "chart",
    epoch: "e",
    seq: 1,
    collections: { request_chart: [entry] },
    meta: {
      ...metadata,
      as_of_unix: 1000,
      window: { since_unix: 1, until_unix: 1000 },
      chart: { bucket_seconds: 3600, dimensions: ["client", "model"] },
    },
  };
  it("decodes through both ingress paths into the same narrow selected identities", async () => {
    const { decodeServerJsonSync } = await import("../src/data/protocol.ts");
    const decoded = decodeServerJsonSync(JSON.stringify(frame));
    expect(await Effect.runPromise(decodeServerFrame(frame))).toEqual(decoded);
    expect(decoded).toMatchObject({
      collections: {
        request_chart: [
          {
            key: entry.key,
            value: {
              bucket_start_unix: 0,
              dimensions: { client: null, model: "model-a" },
              events: 12,
              complete_events: 11,
              error_events: 2,
              cache_read_tokens: null,
              cache_write_tokens: 0,
              input_tokens: 100,
              output_tokens: 40,
              token_unknown_events: {
                cache_read_tokens: 12,
                cache_write_tokens: 0,
                input_tokens: 3,
                output_tokens: 0,
              },
            },
          },
        ],
      },
    });
    for (const dimensions of [[], ["model"], ["client", "provider"]]) {
      const identities = dimensions.map((dimension) =>
        dimension === "client" ? null : "valid-id",
      );
      const tuple = [0, ...identities, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0];
      const view = {
        ...frame,
        meta: { ...frame.meta, chart: { bucket_seconds: 3600, dimensions } },
        collections: {
          request_chart: [
            {
              key: JSON.stringify(tuple.slice(0, 1 + dimensions.length)),
              value: tuple,
            },
          ],
        },
      };
      const result = decodeServerJsonSync(JSON.stringify(view));
      if (
        result.type !== "snapshot" ||
        !("request_chart" in result.collections)
      )
        throw new Error("chart missing");
      expect(
        Object.keys(
          result.collections.request_chart[0]?.value.dimensions ?? {},
        ),
      ).toEqual(dimensions);
    }
  });
  it("rejects malformed tuples, metadata, unsafe numbers and canonical identities in both paths", async () => {
    const { decodeServerJsonSync } = await import("../src/data/protocol.ts");
    const malformed = [
      { ...entry, value: entry.value.slice(1) },
      { ...entry, value: entry.value.slice(0, -4) },
      { ...entry, value: [...entry.value.slice(0, 10), -1, 0, 0, 0] },
      {
        ...entry,
        value: [
          ...entry.value.slice(0, 10),
          Number.MAX_SAFE_INTEGER + 1,
          0,
          0,
          0,
        ],
      },
      { ...entry, value: [...entry.value.slice(0, 10), 13, 0, 0, 0] },
      { ...entry, value: [...entry.value.slice(0, 10), 0, 0, 0, 0] },
      {
        ...entry,
        value: [0, null, "model-a", 12, 11, 2, 0, 0, 100, 40, 12, 0, 0, 0],
      },
      { ...entry, key: "ordinal-0" },
      {
        ...entry,
        value: [0, null, "model-a", 12, 13, 2, null, 0, 100, 40, 12, 0, 0, 0],
      },
      {
        ...entry,
        value: [0, null, "model-a", 12, 11, -1, null, 0, 100, 40, 12, 0, 0, 0],
      },
      {
        ...entry,
        value: [
          0,
          null,
          "model-a",
          12,
          11,
          2,
          null,
          0,
          Number.MAX_SAFE_INTEGER + 1,
          40,
          12,
          0,
          0,
          0,
        ],
      },
      {
        ...entry,
        value: [0, null, null, 12, 11, 2, null, 0, 100, 40, 12, 0, 0, 0],
      },
      {
        ...entry,
        value: [0, null, "", 12, 11, 2, null, 0, 100, 40, 12, 0, 0, 0],
      },
    ];
    const badFrames: unknown[] = malformed.map((row) => ({
      ...frame,
      collections: { request_chart: [row] },
    }));
    for (const dimensions of [
      ["model", "client"],
      ["client", "client"],
      ["client", "model", "provider"],
    ])
      badFrames.push({
        ...frame,
        collections: { request_chart: [] },
        meta: { ...frame.meta, chart: { bucket_seconds: 3600, dimensions } },
      });
    badFrames.push({
      ...frame,
      collections: { request_chart: [] },
      meta: metadata,
    });
    badFrames.push({ ...snapshot, meta: frame.meta });
    for (const bad of badFrames) {
      expect(() => decodeServerJsonSync(JSON.stringify(bad))).toThrow();
      expect(await failure(bad)).toMatchObject({ _tag: "ProtocolDecodeError" });
    }
  });
  it("accepts chart30-day and all windows while rejecting obsolete and unsupported fields", async () => {
    const query = {
      kind: "requests.chart",
      dimensions: ["model", "provider"],
      window: { last_seconds: 2592000 },
      client: null,
    };
    await expect(
      Effect.runPromise(decodeSubscriptionQuery(query)),
    ).resolves.toEqual(query);
    await expect(
      Effect.runPromise(
        decodeSubscriptionQuery({ ...query, window: { all: true } }),
      ),
    ).resolves.toMatchObject({ window: { all: true } });
    for (const extra of [
      { bucket_seconds: 3600 },
      { credential: "key" },
      { group: "g" },
      { outcome: "completed" },
    ])
      await expect(
        Effect.runPromise(decodeSubscriptionQuery({ ...query, ...extra })),
      ).rejects.toBeDefined();
    for (const window of [
      { last_seconds: 2592001 },
      { all: false },
      { since_unix: 0, until_unix: 10 },
    ])
      await expect(
        Effect.runPromise(decodeSubscriptionQuery({ ...query, window })),
      ).rejects.toBeDefined();
    await expect(
      Effect.runPromise(
        decodeSubscriptionQuery({
          ...query,
          dimensions: ["provider", "model"],
        }),
      ),
    ).rejects.toBeDefined();
  });
});
