import type {
  CollectionValue,
  DeltaOperations,
  DeltaRemovals,
  ServerFrame,
  SnapshotCollections,
  SubscriptionQuery,
  ViewMetadata,
} from "./protocol.ts";

export interface ViewGap {
  readonly code: string;
  readonly retryable: boolean;
  readonly action: "retry" | "resnapshot";
}

export type SyncPhase = "none" | "snapshot";

export interface ViewState {
  readonly phase:
    | "idle"
    | "subscribed"
    | "live"
    | "reconnecting"
    | "resynchronizing"
    | "paused"
    | "failed";
  readonly syncPhase: SyncPhase;
  readonly epoch: string | null;
  readonly lastSeq: number;
  readonly intervalMs: number;
  readonly entries: ReadonlyMap<string, CollectionValue>;
  readonly lastGoodEntries: ReadonlyMap<string, CollectionValue>;
  readonly retainedBytes: number;
  readonly meta: ViewMetadata | null;
  readonly gap: ViewGap | null;
  readonly error: string | null;
  readonly terminal: boolean;
  readonly lastServerContactUnix: number | null;
}

export type RecoveryAction = "none" | "reconnect" | "resnapshot";

export interface AppliedFrame {
  readonly state: ViewState;
  readonly acknowledgement: {
    readonly epoch: string;
    readonly seq: number;
  } | null;
  readonly recovery: RecoveryAction;
}

export const retainedViewByteLimit = 2_097_152;

export function initialViewState(): ViewState {
  return {
    phase: "idle",
    syncPhase: "none",
    epoch: null,
    lastSeq: 0,
    intervalMs: 0,
    entries: new Map(),
    lastGoodEntries: new Map(),
    retainedBytes: 0,
    meta: null,
    gap: null,
    error: null,
    terminal: false,
    lastServerContactUnix: null,
  };
}

function collectionNames(query: SubscriptionQuery): readonly string[] {
  switch (query.kind) {
    case "usage.overview":
      return ["credentials"];
    case "usage.series":
      return ["snapshots", "reset_events"];
    case "requests.table":
      return ["requests"];
    case "requests.chart":
      return ["request_chart"];
    case "logs.tail":
      return [];
  }
}

function entryLimit(query: SubscriptionQuery): number {
  switch (query.kind) {
    case "usage.overview":
      return 64;
    case "usage.series":
      return Math.min(query.limit * 2, 2_000);
    case "requests.table":
      return query.limit;
    case "requests.chart":
      return 10_000;
    case "logs.tail":
      return 0;
  }
}

function qualifiedKey(collection: string, key: string): string {
  return `${collection}:${key}`;
}

function retainedBytes(entries: ReadonlyMap<string, CollectionValue>): number {
  let total = 0;
  for (const [key, value] of entries) {
    total += new TextEncoder().encode(
      `${key}${JSON.stringify(value)}`,
    ).byteLength;
  }
  return total;
}

function withEntries(
  state: ViewState,
  entries: ReadonlyMap<string, CollectionValue>,
  live: boolean,
): ViewState {
  return {
    ...state,
    phase: live ? "live" : state.phase,
    entries,
    lastGoodEntries: live ? entries : state.lastGoodEntries,
    retainedBytes: retainedBytes(entries),
  };
}

function resynchronizing(
  state: ViewState,
  code: string,
  recovery: RecoveryAction = "resnapshot",
  retryable = true,
): AppliedFrame {
  return {
    state: {
      ...state,
      phase: "resynchronizing",
      syncPhase: "none",
      epoch: null,
      lastSeq: 0,
      gap: { code, retryable, action: "resnapshot" },
    },
    acknowledgement: null,
    recovery,
  };
}

function exactKeys(expected: readonly string[], actual: readonly string[]) {
  return (
    actual.length === expected.length &&
    expected.every((name) => actual.includes(name))
  );
}

function collectSnapshot(
  collections: SnapshotCollections,
  expected: readonly string[],
  limit: number,
): Map<string, CollectionValue> | null {
  if (!exactKeys(expected, Object.keys(collections))) return null;
  const result = new Map<string, CollectionValue>();
  for (const [name, entries] of Object.entries(collections)) {
    if (entries.length > limit) return null;
    for (const entry of entries) {
      const key = qualifiedKey(name, entry.key);
      if (result.has(key)) return null;
      result.set(key, entry.value as CollectionValue);
    }
  }
  return result.size > limit ? null : result;
}

type DeltaOperation = "remove" | CollectionValue;

function collectDelta(
  operations: DeltaOperations | DeltaRemovals,
  expected: readonly string[],
): Map<string, DeltaOperation> | null {
  if (!exactKeys(expected, Object.keys(operations))) return null;
  const result = new Map<string, DeltaOperation>();
  for (const [name, entries] of Object.entries(operations)) {
    for (const entry of entries) {
      const key = qualifiedKey(name, entry.key);
      if (result.has(key)) return null;
      result.set(
        key,
        "value" in entry ? (entry.value as CollectionValue) : "remove",
      );
    }
  }
  return result;
}

function applyOperations(
  entries: ReadonlyMap<string, CollectionValue>,
  operations: ReadonlyMap<string, DeltaOperation>,
): Map<string, CollectionValue> {
  const result = new Map(entries);
  for (const [key, value] of operations) {
    if (value === "remove") result.delete(key);
    else result.set(key, value);
  }
  return result;
}

function contact(state: ViewState, unix: number | null): ViewState {
  return unix === null ? state : { ...state, lastServerContactUnix: unix };
}

function validView(
  query: SubscriptionQuery,
  meta: ViewMetadata,
  entries: ReadonlyMap<string, CollectionValue>,
): boolean {
  if (query.kind !== "requests.chart") return meta.chart === undefined;
  const chart = meta.chart;
  const axis = meta.window;
  if (
    chart === undefined ||
    axis === null ||
    axis.since_unix < 0 ||
    axis.until_unix <= axis.since_unix ||
    JSON.stringify(chart.dimensions) !== JSON.stringify(query.dimensions)
  )
    return false;
  if (
    "last_seconds" in query.window &&
    (axis.until_unix !== meta.as_of_unix ||
      axis.since_unix !==
        Math.max(1, meta.as_of_unix - query.window.last_seconds))
  )
    return false;
  if (
    "since_unix" in query.window &&
    (axis.since_unix !== query.window.since_unix ||
      axis.until_unix !== query.window.until_unix)
  )
    return false;
  if ("all" in query.window) {
    const oldest = meta.oldest_at_unix;
    const since =
      oldest !== null && oldest < meta.as_of_unix
        ? oldest
        : Math.max(0, meta.as_of_unix - 86400);
    if (axis.until_unix !== meta.as_of_unix || axis.since_unix !== since)
      return false;
  }
  const bucket =
    "all" in query.window
      ? Math.max(
          1,
          Math.ceil(
            (Math.floor((axis.until_unix - 1) / 86400) -
              Math.floor(axis.since_unix / 86400) +
              1) /
              32,
          ),
        ) * 86400
      : axis.until_unix - axis.since_unix <= 2 * 86400
        ? 3600
        : 86400;
  if (chart.bucket_seconds !== bucket) return false;
  return [...entries.values()].every(
    (row) =>
      "dimensions" in row &&
      JSON.stringify(Object.keys(row.dimensions)) ===
        JSON.stringify(chart.dimensions) &&
      row.bucket_start_unix % bucket === 0 &&
      row.bucket_start_unix >= Math.floor(axis.since_unix / bucket) * bucket &&
      row.bucket_start_unix < axis.until_unix,
  );
}

function appliesToSubscription(frame: ServerFrame, id: string): boolean {
  return "id" in frame && frame.id === id;
}

export function applyServerFrame(
  previous: ViewState,
  frame: ServerFrame,
  query: SubscriptionQuery,
  id: string,
  receivedAtUnix: number | null = null,
): AppliedFrame {
  const unchanged: AppliedFrame = {
    state: contact(previous, receivedAtUnix),
    acknowledgement: null,
    recovery: "none",
  };

  if (previous.terminal) {
    return { state: previous, acknowledgement: null, recovery: "none" };
  }
  const state = unchanged.state;
  if (frame.type === "hello" || frame.type === "ping") return unchanged;

  if (frame.type === "error") {
    if (frame.id !== null && frame.id !== id) return unchanged;
    if (!frame.retryable) {
      return {
        state: {
          ...state,
          phase: "failed",
          syncPhase: "none",
          gap: null,
          error: frame.code,
          terminal: true,
        },
        acknowledgement: null,
        recovery: "none",
      };
    }
    return {
      state: {
        ...state,
        phase: "reconnecting",
        syncPhase: "none",
        error: frame.code,
        gap: {
          code: frame.code,
          retryable: true,
          action: "retry",
        },
      },
      acknowledgement: null,
      recovery: "reconnect",
    };
  }

  if (!appliesToSubscription(frame, id)) return unchanged;
  const expected = collectionNames(query);
  const limit = entryLimit(query);

  switch (frame.type) {
    case "subscribed": {
      if (frame.interval_ms <= 0) {
        return resynchronizing(state, "invalid_frame");
      }
      if (state.epoch !== null && state.epoch === frame.epoch) {
        return resynchronizing(state, "server_restart");
      }
      return {
        state: {
          ...state,
          phase: "subscribed",
          syncPhase: "snapshot",
          epoch: frame.epoch,
          lastSeq: 0,
          intervalMs: frame.interval_ms,
          gap: null,
          error: null,
        },
        acknowledgement: null,
        recovery: "none",
      };
    }

    case "snapshot": {
      if (state.syncPhase !== "snapshot") {
        return resynchronizing(state, "sequence_gap");
      }
      if (state.epoch !== frame.epoch || frame.seq !== state.lastSeq + 1) {
        return resynchronizing(state, "sequence_gap");
      }
      const entries = collectSnapshot(frame.collections, expected, limit);
      if (entries !== null && !validView(query, frame.meta, entries))
        return resynchronizing(state, "invalid_frame");
      if (entries === null || retainedBytes(entries) > retainedViewByteLimit) {
        return resynchronizing(
          state,
          entries === null ? "invalid_frame" : "resource_limit",
        );
      }
      return {
        state: withEntries(
          {
            ...state,
            phase: "live",
            syncPhase: "none",
            lastSeq: frame.seq,
            meta: frame.meta,
            gap: null,
            error: null,
          },
          entries,
          true,
        ),
        acknowledgement: { epoch: frame.epoch, seq: frame.seq },
        recovery: "none",
      };
    }

    case "delta": {
      if (state.phase !== "live") {
        return resynchronizing(state, "sequence_gap");
      }
      if (state.epoch === null || state.epoch !== frame.epoch) {
        return resynchronizing(state, "server_restart");
      }
      if (frame.seq <= state.lastSeq) {
        return {
          state,
          acknowledgement: { epoch: frame.epoch, seq: state.lastSeq },
          recovery: "none",
        };
      }
      if (
        frame.prev_seq !== state.lastSeq ||
        frame.seq !== frame.prev_seq + 1
      ) {
        return resynchronizing(state, "sequence_gap");
      }
      const upserts = collectDelta(frame.upserts, expected);
      const removes = collectDelta(frame.removes, expected);
      if (upserts === null || removes === null) {
        return resynchronizing(state, "invalid_frame");
      }
      for (const key of upserts.keys()) {
        if (removes.has(key)) return resynchronizing(state, "invalid_frame");
      }
      const changed = new Map([...upserts, ...removes]);
      const entries = applyOperations(state.entries, changed);
      if (!validView(query, frame.meta, entries))
        return resynchronizing(state, "invalid_frame");
      if (
        entries.size > limit ||
        retainedBytes(entries) > retainedViewByteLimit
      ) {
        return resynchronizing(state, "resource_limit");
      }
      return {
        state: withEntries(
          {
            ...state,
            phase: "live",
            syncPhase: "none",
            lastSeq: frame.seq,
            meta: frame.meta,
            gap: null,
            error: null,
          },
          entries,
          true,
        ),
        acknowledgement: { epoch: frame.epoch, seq: frame.seq },
        recovery: "none",
      };
    }

    case "gap": {
      if (frame.action === "retry") {
        return {
          state: {
            ...state,
            phase: "reconnecting",
            syncPhase: "none",
            gap: {
              code: frame.code,
              retryable: frame.retryable,
              action: "retry",
            },
          },
          acknowledgement: null,
          recovery: "reconnect",
        };
      }
      return resynchronizing(state, frame.code, "resnapshot", frame.retryable);
    }

    case "unsubscribed":
      return {
        state: {
          ...state,
          phase: "paused",
          syncPhase: "none",
          gap: null,
        },
        acknowledgement: null,
        recovery: "none",
      };
  }
}

export interface SubscriptionLease {
  readonly id: string;
  readonly release: () => void;
}

export class SubscriptionRegistry {
  readonly #active = new Set<string>();
  #next = 1;

  acquire(query: SubscriptionQuery): SubscriptionLease {
    if (this.#active.size >= 8) {
      throw new RangeError("max subscriptions exceeded");
    }
    const id = `${query.kind.replace(/\./g, "-")}-${this.#next.toString(36)}`;
    this.#next += 1;
    this.#active.add(id);
    let released = false;
    return {
      id,
      release: () => {
        if (released) return;
        released = true;
        this.#active.delete(id);
      },
    };
  }

  get activeCount(): number {
    return this.#active.size;
  }
}
