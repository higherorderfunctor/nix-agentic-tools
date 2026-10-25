import { Effect, Schema } from "effect";

const safeInteger = Schema.Int.pipe(
  Schema.check(
    Schema.makeFilter((value: number) =>
      Number.isSafeInteger(value) ? undefined : "numeric_range_unsupported",
    ),
  ),
);

const nonemptyString = Schema.String.pipe(
  Schema.check(
    Schema.makeFilter((value: string) =>
      value.length > 0 ? undefined : "empty string is not a valid value",
    ),
  ),
);

const subscriptionId = Schema.String.pipe(
  Schema.check(
    Schema.makeFilter((value: string) =>
      /^[A-Za-z0-9_-]{1,64}$/.test(value)
        ? undefined
        : "invalid subscription id",
    ),
  ),
);

const opaqueString = nonemptyString;

const utf8 = new TextEncoder();
const boundedInteger = (minimum: number, maximum: number, reason: string) =>
  safeInteger.pipe(
    Schema.check(
      Schema.makeFilter((value: number) =>
        value >= minimum && value <= maximum ? undefined : reason,
      ),
    ),
  );

const positiveWindowInteger = boundedInteger(1, 604_800, "window_out_of_range");
const tableLimit = boundedInteger(1, 200, "table_limit_out_of_range");
const seriesLimit = boundedInteger(1, 1_000, "series_limit_out_of_range");
const tailLimit = boundedInteger(1, 200, "tail_limit_out_of_range");
const decimalRequestId = Schema.String.pipe(
  Schema.check(
    Schema.makeFilter((value: string) =>
      /^[0-9]+$/.test(value) ? undefined : "request id must be decimal",
    ),
  ),
);

const auth = Schema.Literals(["api_key", "oauth_bearer", "oauth_managed"]);
const credentialStatus = Schema.Literals([
  "fresh",
  "stale",
  "exhausted",
  "unavailable",
]);
const snapshotSource = Schema.Literals([
  "out_of_band_fetch",
  "response_headers",
]);
const snapshotSurface = Schema.Literals([
  "claude_subscription",
  "codex_rate_limits",
  "console_balance",
  "response_headers",
  "zai_quota",
]);
const resetKind = Schema.Literals([
  "utilization_drop",
  "reset_time_change",
  "credit_refill",
]);
const outcome = Schema.Literals([
  "cancelled",
  "completed",
  "failed",
  "rejected",
]);

export const Route = Schema.Struct({
  client: Schema.String,
  group: Schema.String,
  protocol: Schema.String,
  models: Schema.Array(Schema.String),
  primary: Schema.Boolean,
});
export type Route = Schema.Schema.Type<typeof Route>;

export const Pool = Schema.Struct({
  label: Schema.String,
  limit: safeInteger,
  remaining: safeInteger,
  utilized: safeInteger,
  unit: Schema.Literals(["percent_milli"]),
  reset_at_unix: Schema.NullOr(safeInteger),
});
export type Pool = Schema.Schema.Type<typeof Pool>;

export const Credit = Schema.Struct({
  label: Schema.String,
  reset_at_unix: Schema.NullOr(safeInteger),
  limit_minor_units: safeInteger,
  remaining_minor_units: safeInteger,
  used_minor_units: safeInteger,
});
export type Credit = Schema.Schema.Type<typeof Credit>;

export const Metric = Schema.Struct({
  label: Schema.String,
  unit: Schema.String,
  value: safeInteger,
});
export type Metric = Schema.Schema.Type<typeof Metric>;

export const ClaudeLimit = Schema.Struct({
  kind: Schema.String,
  group: Schema.NullOr(Schema.String),
  severity: Schema.NullOr(Schema.String),
  percent_milli: safeInteger,
  reset_at_unix: Schema.NullOr(safeInteger),
  is_active: Schema.Boolean,
  scope: Schema.Struct({
    model_display_name: Schema.NullOr(Schema.String),
    surface_display_name: Schema.NullOr(Schema.String),
  }),
});
export type ClaudeLimit = Schema.Schema.Type<typeof ClaudeLimit>;

export const HeaderWindow = Schema.Struct({
  label: Schema.Literals(["five_hour", "seven_day"]),
  utilization_milli: safeInteger,
  reset_at_unix: Schema.NullOr(safeInteger),
  status: Schema.NullOr(
    Schema.Literals(["allowed", "allowed_warning", "rejected"]),
  ),
});
export type HeaderWindow = Schema.Schema.Type<typeof HeaderWindow>;

export const Snapshot = Schema.Struct({
  account_id: Schema.String,
  credential: Schema.String,
  provider: Schema.String,
  client: Schema.NullOr(Schema.String),
  group: Schema.NullOr(Schema.String),
  gap_reason: Schema.NullOr(Schema.String),
  fetched_at_unix: safeInteger,
  source: snapshotSource,
  surface: snapshotSurface,
  status: credentialStatus,
  claude_limits: Schema.Array(ClaudeLimit),
  credits: Schema.Array(Credit),
  header_windows: Schema.Array(HeaderWindow),
  metrics: Schema.Array(Metric),
  pools: Schema.Array(Pool),
  partial_gaps: Schema.Array(Schema.String),
});
export type Snapshot = Schema.Schema.Type<typeof Snapshot>;

export const Credential = Schema.Struct({
  account_id: Schema.NullOr(Schema.String),
  client: Schema.NullOr(Schema.String),
  group: Schema.NullOr(Schema.String),
  credential: Schema.String,
  provider: Schema.String,
  surface: Schema.String,
  auth,
  explicit_usage_selection: Schema.Boolean,
  global_quota_complete: Schema.Boolean,
  header_age_seconds: Schema.NullOr(safeInteger),
  latest_fetch: Schema.NullOr(Snapshot),
  latest_header: Schema.NullOr(Snapshot),
  status: credentialStatus,
  routes: Schema.Array(Route),
});
export type Credential = Schema.Schema.Type<typeof Credential>;

export const RequestRow = Schema.Struct({
  id: decimalRequestId,
  occurred_at_unix: safeInteger,
  client: Schema.NullOr(Schema.String),
  group: Schema.String,
  credential: Schema.String,
  provider: Schema.String,
  model: Schema.String,
  outcome,
  status_code: safeInteger,
  latency_ms: safeInteger,
  request_bytes: safeInteger,
  response_bytes: safeInteger,
  input_tokens: Schema.NullOr(safeInteger),
  output_tokens: Schema.NullOr(safeInteger),
  cache_read_tokens: Schema.NullOr(safeInteger),
  cache_write_tokens: Schema.NullOr(safeInteger),
  usage_complete: Schema.Boolean,
});
export type RequestRow = Schema.Schema.Type<typeof RequestRow>;

export const Aggregate = Schema.Struct({
  credential: Schema.String,
  group: Schema.String,
  model: Schema.String,
  provider: Schema.String,
  client: Schema.NullOr(Schema.String),
  outcome,
  bucket_start_unix: safeInteger,
  complete_events: safeInteger,
  error_events: safeInteger,
  events: safeInteger,
  latency_ms: safeInteger,
  request_bytes: safeInteger,
  response_bytes: safeInteger,
  successful_events: safeInteger,
  cache_read_tokens: Schema.NullOr(safeInteger),
  cache_write_tokens: Schema.NullOr(safeInteger),
  input_tokens: Schema.NullOr(safeInteger),
  output_tokens: Schema.NullOr(safeInteger),
});
export type Aggregate = Schema.Schema.Type<typeof Aggregate>;

export const ResetEvent = Schema.Struct({
  credential: Schema.String,
  pool: Schema.String,
  provider: Schema.String,
  surface: Schema.String,
  detected_at_unix: safeInteger,
  reset_at_unix: Schema.NullOr(safeInteger),
  kind: resetKind,
});
export type ResetEvent = Schema.Schema.Type<typeof ResetEvent>;

export type CollectionValue =
  | Credential
  | Snapshot
  | RequestRow
  | Aggregate
  | ResetEvent;

const CredentialEntry = Schema.Struct({
  key: Schema.String,
  value: Credential,
});
const SnapshotEntry = Schema.Struct({ key: Schema.String, value: Snapshot });
const ResetEntry = Schema.Struct({ key: Schema.String, value: ResetEvent });
const RequestEntry = Schema.Struct({ key: Schema.String, value: RequestRow });
const AggregateEntry = Schema.Struct({ key: Schema.String, value: Aggregate });
const Removal = Schema.Struct({
  key: Schema.String,
  reason: Schema.Literals(["left_window"]),
});

const SnapshotCollections = Schema.Union([
  Schema.Struct({ credentials: Schema.Array(CredentialEntry) }),
  Schema.Struct({
    snapshots: Schema.Array(SnapshotEntry),
    reset_events: Schema.Array(ResetEntry),
  }),
  Schema.Struct({ requests: Schema.Array(RequestEntry) }),
  Schema.Struct({ request_usage: Schema.Array(AggregateEntry) }),
]);
export type SnapshotCollections = Schema.Schema.Type<
  typeof SnapshotCollections
>;

const DeltaOperations = SnapshotCollections;
export type DeltaOperations = SnapshotCollections;
const DeltaRemovals = Schema.Union([
  Schema.Struct({ credentials: Schema.Array(Removal) }),
  Schema.Struct({
    snapshots: Schema.Array(Removal),
    reset_events: Schema.Array(Removal),
  }),
  Schema.Struct({ requests: Schema.Array(Removal) }),
  Schema.Struct({ request_usage: Schema.Array(Removal) }),
]);
export type DeltaRemovals = Schema.Schema.Type<typeof DeltaRemovals>;

const RelativeWindow = Schema.Struct({ last_seconds: positiveWindowInteger });
const AbsoluteWindow = Schema.Struct({
  since_unix: safeInteger,
  until_unix: safeInteger,
});
const Window = Schema.Union([RelativeWindow, AbsoluteWindow]);
export type Window = Schema.Schema.Type<typeof Window>;

const requestFilters = {
  client: Schema.optionalKey(Schema.NullOr(Schema.String)),
  credential: Schema.optionalKey(Schema.String),
  group: Schema.optionalKey(Schema.String),
  model: Schema.optionalKey(Schema.String),
  outcome: Schema.optionalKey(outcome),
  provider: Schema.optionalKey(Schema.String),
} as const;

const UsageOverviewBody = Schema.Struct({
  provider: Schema.optionalKey(Schema.String),
  credential: Schema.optionalKey(Schema.String),
});
const UsageSeriesBody = Schema.Struct({
  provider: Schema.String,
  credential: Schema.String,
  source: snapshotSource,
  surface: snapshotSurface,
  window: Window,
  limit: seriesLimit,
});
const RequestsTableBody = Schema.Struct({
  window: Window,
  limit: tableLimit,
  ...requestFilters,
  before: Schema.optionalKey(opaqueString),
});
const RequestsSeriesBody = Schema.Struct({
  window: Window,
  bucket_seconds: Schema.Literals([60, 300, 3600]),
  ...requestFilters,
});
const LogsTailBody = Schema.Struct({
  stream: Schema.Literals(["requests", "audit"]),
  limit: tailLimit,
  after: Schema.optionalKey(opaqueString),
});

export const UsageOverviewQuery = Schema.Struct({
  kind: Schema.Literals(["usage.overview"]),
  ...UsageOverviewBody.fields,
});
export const UsageSeriesQuery = Schema.Struct({
  kind: Schema.Literals(["usage.series"]),
  ...UsageSeriesBody.fields,
});
export const RequestsTableQuery = Schema.Struct({
  kind: Schema.Literals(["requests.table"]),
  ...RequestsTableBody.fields,
});
export const RequestsSeriesQuery = Schema.Struct({
  kind: Schema.Literals(["requests.series"]),
  ...RequestsSeriesBody.fields,
});
export const LogsTailQuery = Schema.Struct({
  kind: Schema.Literals(["logs.tail"]),
  ...LogsTailBody.fields,
});
export const SubscriptionQuery = Schema.Union([
  UsageOverviewQuery,
  UsageSeriesQuery,
  RequestsTableQuery,
  RequestsSeriesQuery,
  LogsTailQuery,
]);
export type SubscriptionQuery = Schema.Schema.Type<typeof SubscriptionQuery>;
const WireSubscriptionQuery = Schema.Union([
  UsageOverviewBody,
  UsageSeriesBody,
  RequestsTableBody,
  RequestsSeriesBody,
  LogsTailBody,
]);
export type WireSubscriptionQuery = Schema.Schema.Type<
  typeof WireSubscriptionQuery
>;
const SubscribeFrame = Schema.Union([
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["subscribe"]),
    id: subscriptionId,
    kind: Schema.Literals(["usage.overview"]),
    query: UsageOverviewBody,
    resume: Schema.NullOr(
      Schema.Struct({ epoch: opaqueString, after_seq: safeInteger }),
    ),
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["subscribe"]),
    id: subscriptionId,
    kind: Schema.Literals(["usage.series"]),
    query: UsageSeriesBody,
    resume: Schema.NullOr(
      Schema.Struct({ epoch: opaqueString, after_seq: safeInteger }),
    ),
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["subscribe"]),
    id: subscriptionId,
    kind: Schema.Literals(["requests.table"]),
    query: RequestsTableBody,
    resume: Schema.NullOr(
      Schema.Struct({ epoch: opaqueString, after_seq: safeInteger }),
    ),
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["subscribe"]),
    id: subscriptionId,
    kind: Schema.Literals(["requests.series"]),
    query: RequestsSeriesBody,
    resume: Schema.NullOr(
      Schema.Struct({ epoch: opaqueString, after_seq: safeInteger }),
    ),
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["subscribe"]),
    id: subscriptionId,
    kind: Schema.Literals(["logs.tail"]),
    query: LogsTailBody,
    resume: Schema.NullOr(
      Schema.Struct({ epoch: opaqueString, after_seq: safeInteger }),
    ),
  }),
]);

const viewMetaWindow = Schema.NullOr(
  Schema.Struct({ since_unix: safeInteger, until_unix: safeInteger }),
);
const ViewMeta = Schema.Struct({
  as_of_unix: safeInteger,
  window: viewMetaWindow,
  oldest_at_unix: Schema.NullOr(safeInteger),
  has_more: Schema.Boolean,
  next_before: Schema.NullOr(opaqueString),
  truncated: Schema.Boolean,
  known_gaps: Schema.Array(Schema.String),
  request_loss_total: safeInteger,
  provider_snapshot_loss_total: safeInteger,
  reset_events_observed_only: Schema.Literals([true]),
  reset_events_complete_since_unix: Schema.Null,
});
type ViewMeta = Schema.Schema.Type<typeof ViewMeta>;
export type ViewMetadata = ViewMeta;

const gapCode = Schema.Literals([
  "client_overflow",
  "query_budget_exceeded",
  "resume_expired",
  "resume_mismatch",
  "resume_unavailable",
  "sequence_gap",
  "server_restart",
  "slow_consumer",
  "storage_busy",
  "storage_unavailable",
]);

export const ClientFrame = Schema.Union([
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["auth"]),
    token: Schema.String,
    resume_session: Schema.NullOr(opaqueString),
  }),
  SubscribeFrame,
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["ack"]),
    id: subscriptionId,
    epoch: opaqueString,
    seq: safeInteger,
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["unsubscribe"]),
    id: subscriptionId,
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["pong"]),
    nonce: opaqueString,
  }),
]);
export type ClientFrame = Schema.Schema.Type<typeof ClientFrame>;

export const ServerFrame = Schema.Union([
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["hello"]),
    session: opaqueString,
    server_time_unix: safeInteger,
    capabilities: Schema.Array(Schema.String),
    limits: Schema.Struct({
      max_subscriptions: safeInteger,
      max_frame_bytes: safeInteger,
      max_unacked_frames: safeInteger,
      replay_ttl_seconds: safeInteger,
    }),
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["subscribed"]),
    id: subscriptionId,
    epoch: opaqueString,
    mode: Schema.Literals(["snapshot", "resume"]),
    head_seq: safeInteger,
    interval_ms: safeInteger,
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["snapshot"]),
    id: subscriptionId,
    epoch: opaqueString,
    seq: safeInteger,
    collections: SnapshotCollections,
    meta: ViewMeta,
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["delta"]),
    id: subscriptionId,
    epoch: opaqueString,
    seq: safeInteger,
    prev_seq: safeInteger,
    upserts: DeltaOperations,
    removes: DeltaRemovals,
    meta: ViewMeta,
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["gap"]),
    id: subscriptionId,
    epoch: opaqueString,
    after_seq: safeInteger,
    code: gapCode,
    retryable: Schema.Boolean,
    action: Schema.Literals(["retry", "resnapshot"]),
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["error"]),
    id: Schema.NullOr(subscriptionId),
    code: Schema.Literals([
      "invalid_frame",
      "invalid_query",
      "numeric_range_unsupported",
      "range_too_large",
      "resource_limit",
      "storage_corrupt",
      "storage_unavailable",
      "subscription_conflict",
      "unauthorized",
      "unknown_subscription",
      "unsupported_subscription",
      "unsupported_version",
    ]),
    retryable: Schema.Boolean,
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["unsubscribed"]),
    id: subscriptionId,
  }),
  Schema.Struct({
    v: Schema.Literals([1]),
    type: Schema.Literals(["ping"]),
    nonce: opaqueString,
    server_time_unix: safeInteger,
  }),
]);
export type ServerFrame = Schema.Schema.Type<typeof ServerFrame>;

export class ProtocolDecodeError extends Schema.TaggedError<ProtocolDecodeError>()(
  "ProtocolDecodeError",
  { reason: Schema.String },
) {}
export class TransportFailure extends Schema.TaggedError<TransportFailure>()(
  "TransportFailure",
  { reason: Schema.String },
) {}
export class ClientOverflowError extends Schema.TaggedError<ClientOverflowError>()(
  "ClientOverflow",
  {},
) {}
export type ControlError =
  | ProtocolDecodeError
  | TransportFailure
  | ClientOverflowError;

const parseOptions = { onExcessProperty: "error" } as const;

function canonicalKey(value: readonly unknown[]): string {
  return JSON.stringify(value);
}

function validSnapshotKey(key: string): boolean {
  return key.length > 0;
}

function validResetKey(key: string, value: ResetEvent): boolean {
  let parsed: unknown;
  try {
    parsed = JSON.parse(key) as unknown;
  } catch {
    return false;
  }
  if (!Array.isArray(parsed) || parsed.length !== 5) return false;
  const [preceding, current, dimension, pool, kind] = parsed;
  return (
    typeof preceding === "string" &&
    preceding.length > 0 &&
    typeof current === "string" &&
    current.length > 0 &&
    (dimension === "quota" || dimension === "credit") &&
    pool === value.pool &&
    kind === value.kind &&
    key === canonicalKey(parsed)
  );
}

function validEntryIdentity(
  collection: string,
  entry: {
    readonly key: string;
    readonly value: CollectionValue;
  },
): boolean {
  const value = entry.value;
  switch (collection) {
    case "credentials":
      return "auth" in value
        ? entry.key === canonicalKey([value.provider, value.credential])
        : false;
    case "snapshots":
      return "fetched_at_unix" in value && validSnapshotKey(entry.key);
    case "requests":
      return "occurred_at_unix" in value && entry.key === value.id;
    case "request_usage":
      return "bucket_start_unix" in value
        ? entry.key ===
            canonicalKey([
              value.bucket_start_unix,
              value.client,
              value.group,
              value.provider,
              value.credential,
              value.model,
              value.outcome,
            ])
        : false;
    case "reset_events":
      return "detected_at_unix" in value
        ? validResetKey(entry.key, value)
        : false;
  }
  return false;
}

function validateEntryIdentity(frame: ServerFrame): boolean {
  if (frame.type !== "snapshot" && frame.type !== "delta") return true;
  const collectionSets: readonly Readonly<Record<string, unknown>>[] =
    frame.type === "snapshot"
      ? [frame.collections as Record<string, unknown>]
      : [frame.upserts as Record<string, unknown>];
  return collectionSets.every((collections) =>
    Object.entries(collections).every(([name, entries]) =>
      (
        entries as readonly {
          readonly key: string;
          readonly value: CollectionValue;
        }[]
      ).every((entry) => validEntryIdentity(name, entry)),
    ),
  );
}

export const decodeServerFrame = (
  input: unknown,
): Effect.Effect<ServerFrame, ProtocolDecodeError> =>
  Schema.decodeUnknownEffect(
    ServerFrame,
    parseOptions,
  )(input).pipe(
    Effect.flatMap((frame) =>
      validateEntryIdentity(frame)
        ? Effect.succeed(frame)
        : Effect.fail(
            new ProtocolDecodeError({ reason: "entry_key_mismatch" }),
          ),
    ),
    Effect.mapError((error) =>
      error instanceof ProtocolDecodeError
        ? error
        : new ProtocolDecodeError({ reason: "schema_mismatch" }),
    ),
  );

export function decodeServerJsonSync(input: string): ServerFrame {
  if (input.length === 0) {
    throw new ProtocolDecodeError({ reason: "empty_frame" });
  }
  if (utf8.encode(input).byteLength > 1_048_576) {
    throw new ProtocolDecodeError({ reason: "frame_byte_limit_exceeded" });
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(input) as unknown;
  } catch {
    throw new ProtocolDecodeError({ reason: "invalid_json" });
  }
  try {
    const frame = Schema.decodeUnknownSync(ServerFrame, parseOptions)(parsed);
    if (!validateEntryIdentity(frame)) {
      throw new ProtocolDecodeError({ reason: "entry_key_mismatch" });
    }
    return frame;
  } catch (error) {
    throw error instanceof ProtocolDecodeError
      ? error
      : new ProtocolDecodeError({ reason: "schema_mismatch" });
  }
}

export function decodeClientFrameSync(input: unknown): ClientFrame {
  const frame = Schema.decodeUnknownSync(ClientFrame, parseOptions)(input);
  if (frame.type === "subscribe" && !validWireQuery(frame.query)) {
    throw new ProtocolDecodeError({ reason: "invalid_query" });
  }
  return frame;
}

export function encodeClientFrameSync(frame: ClientFrame): string {
  return JSON.stringify(decodeClientFrameSync(frame));
}

export function decodeServerJson(
  input: string,
): Effect.Effect<ServerFrame, ControlError> {
  return Effect.try({
    try: () => decodeServerJsonSync(input),
    catch: (error) =>
      error instanceof ProtocolDecodeError
        ? error
        : new ProtocolDecodeError({ reason: "schema_mismatch" }),
  });
}

function validWindow(window: Window): boolean {
  if ("last_seconds" in window) return true;
  return (
    window.until_unix > window.since_unix &&
    window.until_unix - window.since_unix <= 604_800
  );
}

function validQuery(query: SubscriptionQuery): boolean {
  if (
    query.kind === "usage.series" ||
    query.kind === "requests.table" ||
    query.kind === "requests.series"
  ) {
    return validWindow(query.window);
  }
  return true;
}

function validWireQuery(query: WireSubscriptionQuery): boolean {
  return "window" in query ? validWindow(query.window) : true;
}

export function decodeSubscriptionQuery(
  input: unknown,
): Effect.Effect<SubscriptionQuery, ProtocolDecodeError> {
  return Schema.decodeUnknownEffect(
    SubscriptionQuery,
    parseOptions,
  )(input).pipe(
    Effect.filterOrFail(
      validQuery,
      () => new ProtocolDecodeError({ reason: "invalid_query" }),
    ),
    Effect.mapError(() => new ProtocolDecodeError({ reason: "invalid_query" })),
  );
}

export function encodeClientFrame(
  frame: ClientFrame,
): Effect.Effect<string, ProtocolDecodeError> {
  return Effect.try({
    try: () => encodeClientFrameSync(frame),
    catch: (error) =>
      error instanceof ProtocolDecodeError
        ? error
        : new ProtocolDecodeError({ reason: "schema_mismatch" }),
  });
}
