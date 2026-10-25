import { describe, expect, it } from "vitest";
import type {
  Credential,
  ServerFrame,
  SubscriptionQuery,
} from "../src/data/protocol.ts";
import {
  applyServerFrame,
  initialViewState,
  SubscriptionRegistry,
} from "../src/data/reducer.ts";

import { serverFrame } from "./protocol-fixtures.ts";

const query: SubscriptionQuery = {
  kind: "usage.series",
  provider: "claude",
  credential: "claude",
  source: "out_of_band_fetch",
  surface: "claude_subscription",
  window: { last_seconds: 86_400 },
  limit: 1000,
};

const credential: Credential = {
  account_id: null,
  client: "harness",
  group: "anthropic",
  credential: "claude",
  provider: "claude",
  surface: "claude_subscription",
  auth: "oauth_bearer",
  explicit_usage_selection: false,
  global_quota_complete: false,
  header_age_seconds: 100,
  latest_fetch: null,
  latest_header: null,
  status: "fresh",
  routes: [],
};

const metadata = {
  ...serverFrame("snapshot").meta,
  as_of_unix: 100,
  window: { since_unix: 0, until_unix: 100 },
};

const subscribed: ServerFrame = {
  ...serverFrame("subscribed"),
  id: "series-1",
  epoch: "epoch-a",
};

const snapshot: ServerFrame = {
  ...serverFrame("snapshot"),
  id: "series-1",
  epoch: "epoch-a",
  collections: {
    snapshots: [
      {
        key: "snapshot-1",
        value: {
          account_id: "claude",
          credential: "claude",
          provider: "claude",
          client: "harness",
          group: "anthropic",
          gap_reason: null,
          fetched_at_unix: 100,
          source: "out_of_band_fetch",
          surface: "claude_subscription",
          status: "fresh",
          claude_limits: [],
          credits: [],
          header_windows: [],
          metrics: [],
          pools: [],
          partial_gaps: [],
        },
      },
    ],
    reset_events: [],
  },
  meta: metadata,
};

function delta(seq: number, prevSeq: number): ServerFrame {
  return {
    ...serverFrame("delta"),
    id: "series-1",
    epoch: "epoch-a",
    seq,
    prev_seq: prevSeq,
    meta: metadata,
  };
}

function reduce(frames: readonly ServerFrame[], id = "series-1") {
  let state = initialViewState();
  const acknowledged: number[] = [];
  for (const frame of frames) {
    const result = applyServerFrame(state, frame, query, id);
    state = result.state;
    if (result.acknowledgement !== null)
      acknowledged.push(result.acknowledgement.seq);
  }
  return { state, acknowledged };
}

describe("subscription reducer", () => {
  it("applies only contiguous frames and acknowledges applied data", () => {
    const { state, acknowledged } = reduce([subscribed, snapshot, delta(2, 1)]);
    expect(state.phase).toBe("live");
    expect(state.lastSeq).toBe(2);
    expect([...state.entries.keys()]).toEqual(["snapshots:snapshot-1"]);
    expect(acknowledged).toEqual([1, 2]);
  });

  it("rejects matching and foreign snapshots before subscription separately", () => {
    const matching = reduce([snapshot]);
    expect(matching.state.phase).toBe("resynchronizing");
    expect(matching.state.gap?.code).toBe("sequence_gap");
    expect(matching.state.epoch).toBeNull();
    const foreign = reduce([
      { ...snapshot, id: "other" },
      {
        v: 1,
        type: "error",
        id: "other",
        code: "storage_unavailable",
        retryable: true,
      },
    ]);
    expect(foreign.state.phase).toBe("idle");
    expect(foreign.state.error).toBeNull();
  });

  it("invalidates an old epoch after a sequence gap", () => {
    const { state } = reduce([subscribed, snapshot, delta(3, 1)]);
    expect(state.phase).toBe("resynchronizing");
    expect(state.epoch).toBeNull();
    expect(state.gap?.code).toBe("sequence_gap");
    const afterOldDelta = applyServerFrame(
      state,
      delta(4, 3),
      query,
      "series-1",
    );
    expect(afterOldDelta.state.phase).toBe("resynchronizing");
    expect(afterOldDelta.acknowledgement).toBeNull();
  });

  it("rejects wrong-kind collections and duplicate keys", () => {
    const wrongKind = reduce([
      subscribed,
      {
        ...snapshot,
        collections: { credentials: [{ key: "claude", value: credential }] },
      },
    ]);
    expect(wrongKind.state.phase).toBe("resynchronizing");
    if (!("snapshots" in snapshot.collections))
      throw new Error("test fixture lost its snapshots collection");
    const snapshotEntry = snapshot.collections.snapshots[0];
    if (snapshotEntry === undefined)
      throw new Error("test fixture lost its snapshot entry");
    const duplicate = reduce([
      subscribed,
      {
        ...snapshot,
        collections: {
          snapshots: [snapshotEntry, snapshotEntry],
          reset_events: [],
        },
      },
    ]);
    expect(duplicate.state.phase).toBe("resynchronizing");
  });

  it("bounds keyed state and rejects duplicate operation keys", () => {
    const tableQuery: SubscriptionQuery = {
      kind: "requests.table",
      window: { last_seconds: 3600 },
      limit: 1,
      provider: "claude",
    };
    const row = {
      key: "row-1",
      value: {
        id: "row-1",
        occurred_at_unix: 1,
        client: null,
        group: "anthropic",
        credential: "claude",
        provider: "claude",
        model: "model",
        outcome: "completed" as const,
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
    const tableSnapshot: ServerFrame = {
      v: 1,
      type: "subscribed",
      id: "table-1",
      epoch: "epoch-table",
      mode: "snapshot",
      head_seq: 0,
      interval_ms: 1000,
    };
    const first: ServerFrame = {
      ...tableSnapshot,
      type: "snapshot",
      seq: 1,
      collections: { requests: [row] },
      meta: metadata,
    };
    const secondRow = {
      ...row,
      key: "row-2",
      value: { ...row.value, id: "row-2" },
    };
    const overflow: ServerFrame = {
      ...tableSnapshot,
      type: "delta",
      seq: 2,
      prev_seq: 1,
      upserts: { requests: [secondRow] },
      removes: { requests: [] },
      meta: metadata,
    };
    let state = initialViewState();
    for (const frame of [tableSnapshot, first]) {
      state = applyServerFrame(state, frame, tableQuery, "table-1").state;
    }
    const result = applyServerFrame(state, overflow, tableQuery, "table-1");
    expect(result.state.phase).toBe("resynchronizing");
    expect(result.state.gap?.code).toBe("resource_limit");
    const duplicateOverflow: ServerFrame = {
      ...overflow,
      upserts: { requests: [secondRow, secondRow] },
    };
    const duplicate = applyServerFrame(
      state,
      duplicateOverflow,
      tableQuery,
      "table-1",
    );
    expect(duplicate.state.gap?.code).toBe("invalid_frame");
  });

  it("allocates unique bounded leases and releases them", () => {
    const registry = new SubscriptionRegistry();
    const leases = [registry.acquire(query), registry.acquire(query)];
    expect(new Set(leases.map((lease) => lease.id)).size).toBe(2);
    expect(registry.activeCount).toBe(2);
    for (const lease of leases) lease.release();
    expect(registry.activeCount).toBe(0);
    const more = Array.from({ length: 8 }, () => registry.acquire(query));
    expect(registry.activeCount).toBe(8);
    expect(() => registry.acquire(query)).toThrow(RangeError);
    for (const lease of more) lease.release();
    expect(registry.activeCount).toBe(0);
  });
});

describe("reducer round-2 regressions", () => {
  const tableQuery: SubscriptionQuery = {
    kind: "requests.table",
    window: { last_seconds: 3600 },
    limit: 1,
    provider: "claude",
  };
  const tableSubscribed: ServerFrame = {
    v: 1,
    type: "subscribed",
    id: "requests-table-1",
    epoch: "table-epoch",
    mode: "snapshot",
    head_seq: 0,
    interval_ms: 1000,
  };
  const row = {
    key: "1",
    value: {
      id: "1",
      occurred_at_unix: 1,
      client: null,
      group: "anthropic",
      credential: "claude",
      provider: "claude",
      model: "claude-sonnet",
      outcome: "completed" as const,
      status_code: 200,
      latency_ms: 10,
      request_bytes: 1,
      response_bytes: 2,
      input_tokens: 1,
      output_tokens: 1,
      cache_read_tokens: null,
      cache_write_tokens: null,
      usage_complete: true,
    },
  };
  const tableSnapshot: ServerFrame = {
    v: 1,
    type: "snapshot",
    id: "requests-table-1",
    epoch: "table-epoch",
    seq: 1,
    collections: { requests: [row] },
    meta: metadata,
  };

  function tableDelta(upserts: (typeof row)[], seq = 2): ServerFrame {
    return {
      v: 1,
      type: "delta",
      id: "requests-table-1",
      epoch: "table-epoch",
      seq,
      prev_seq: seq - 1,
      upserts: { requests: upserts },
      removes: { requests: [] },
      meta: metadata,
    };
  }

  function tableReduce(frames: readonly ServerFrame[]) {
    let state = initialViewState();
    const acknowledgements: number[] = [];
    for (const frame of frames) {
      const applied = applyServerFrame(
        state,
        frame,
        tableQuery,
        "requests-table-1",
      );
      state = applied.state;
      if (applied.acknowledgement !== null)
        acknowledgements.push(applied.acknowledgement.seq);
    }
    return { state, acknowledgements };
  }

  it("rejects a delta before the snapshot establishes data", () => {
    const result = tableReduce([tableSubscribed, tableDelta([], 1)]);
    expect(result.state.phase).toBe("resynchronizing");
    expect(result.state.syncPhase).toBe("none");
    expect(result.acknowledgements).toEqual([]);
  });

  it("does not let a duplicate old snapshot roll back a resumed view", () => {
    const before = tableReduce([tableSubscribed, tableSnapshot]);
    const resumed = applyServerFrame(
      before.state,
      { ...tableSubscribed, mode: "resume", head_seq: 1 },
      tableQuery,
      "requests-table-1",
    );
    expect(resumed.state.phase).toBe("live");
    const rollback = applyServerFrame(
      resumed.state,
      tableSnapshot,
      tableQuery,
      "requests-table-1",
    );
    expect(rollback.state.phase).toBe("resynchronizing");
    expect(rollback.state.epoch).toBeNull();
    expect(rollback.acknowledgement).toBeNull();
  });

  it("rejects a fresh snapshot handshake that reuses the live epoch", () => {
    const before = tableReduce([tableSubscribed, tableSnapshot]);
    const unsolicited = applyServerFrame(
      before.state,
      { ...tableSubscribed, head_seq: 0 },
      tableQuery,
      "requests-table-1",
    );
    const rollback = applyServerFrame(
      unsolicited.state,
      tableSnapshot,
      tableQuery,
      "requests-table-1",
    );
    expect(unsolicited.state.phase).toBe("resynchronizing");
    expect(rollback.state.phase).toBe("resynchronizing");
    expect(rollback.state.epoch).toBeNull();
    expect(rollback.state.lastSeq).toBe(0);
    expect(rollback.acknowledgement).toBeNull();
  });

  it("records receipt time separately from provider observation time", () => {
    const before = tableReduce([tableSubscribed, tableSnapshot]);
    const result = applyServerFrame(
      before.state,
      {
        v: 1,
        type: "subscribed",
        id: "other-subscription",
        epoch: "other-epoch",
        mode: "snapshot",
        head_seq: 0,
        interval_ms: 1000,
      },
      tableQuery,
      "requests-table-1",
      1_792_886_400,
    );
    expect(result.state.lastServerContactUnix).toBe(1_792_886_400);
    expect(result.state.meta?.as_of_unix).toBe(100);
    const appliedDelta = applyServerFrame(
      result.state,
      tableDelta([], 2),
      tableQuery,
      "requests-table-1",
      1_792_886_401,
    );
    expect(appliedDelta.state.lastServerContactUnix).toBe(1_792_886_401);
    expect(appliedDelta.state.meta?.as_of_unix).toBe(100);
  });

  it("marks a fully applied resume live without waiting for another delta", () => {
    const before = tableReduce([tableSubscribed, tableSnapshot]);
    const result = applyServerFrame(
      before.state,
      { ...tableSubscribed, mode: "resume", head_seq: 1 },
      tableQuery,
      "requests-table-1",
    );
    expect(result.state.phase).toBe("live");
    expect(result.state.syncPhase).toBe("none");
  });

  it("makes nonretryable failures terminal while preserving last-good data", () => {
    const before = tableReduce([tableSubscribed, tableSnapshot]);
    const failed = applyServerFrame(
      before.state,
      {
        v: 1,
        type: "error",
        id: "requests-table-1",
        code: "unauthorized",
        retryable: false,
      },
      tableQuery,
      "requests-table-1",
    );
    expect(failed.state.phase).toBe("failed");
    expect(failed.state.terminal).toBe(true);
    expect(failed.state.entries).toBe(before.state.entries);
    const revived = applyServerFrame(
      failed.state,
      tableDelta([], 2),
      tableQuery,
      "requests-table-1",
    );
    expect(revived.state).toStrictEqual(failed.state);
    expect(revived.acknowledgement).toBeNull();
  });

  it("computes final cardinality instead of operation counts", () => {
    const updated = tableReduce([
      tableSubscribed,
      tableSnapshot,
      tableDelta([{ ...row, value: { ...row.value, latency_ms: 20 } }]),
    ]);
    expect(updated.state.phase).toBe("live");
    expect(updated.state.entries.size).toBe(1);
    expect(updated.acknowledgements).toEqual([1, 2]);

    const removal = tableReduce([
      tableSubscribed,
      tableSnapshot,
      {
        v: 1,
        type: "delta",
        id: "requests-table-1",
        epoch: "table-epoch",
        seq: 2,
        prev_seq: 1,
        upserts: { requests: [] },
        removes: { requests: [{ key: "1", reason: "left_window" }] },
        meta: metadata,
      },
      tableDelta(
        [
          {
            key: "2",
            value: { ...row.value, id: "2", occurred_at_unix: 2 },
          },
        ],
        3,
      ),
    ]);
    expect(removal.state.phase).toBe("live");
    expect(removal.state.entries.size).toBe(1);
    expect(removal.acknowledgements).toEqual([1, 2, 3]);
  });
});
