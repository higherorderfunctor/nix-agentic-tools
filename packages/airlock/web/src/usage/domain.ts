export const usageChartLimits = {
  maxBuckets: 366,
  maxSeries: 256,
} as const;

export type UsageChartDimensionName = "client" | "model" | "provider";
export type UsageChartDimensions = Readonly<
  Partial<Record<UsageChartDimensionName, string | null>>
>;
export type UsageTokenDimension =
  | "cache_read_tokens"
  | "cache_write_tokens"
  | "input_tokens"
  | "output_tokens";
export type UsageTokenUnknownEvents = Readonly<
  Record<UsageTokenDimension, number>
>;
export type UsageTokenPart = "total" | UsageTokenDimension;
export type UsageMetric =
  | { readonly kind: "requests" }
  | { readonly kind: "tokens"; readonly part: UsageTokenPart };
export type UsageGroupDimension = "none" | UsageChartDimensionName;
export type UsageBreakdown = UsageGroupDimension | "token";

// Rows project validated, server-filtered aggregates. Missing dimensions were not queried.
export interface UsageChartRow {
  readonly bucket_start_unix: number;
  readonly dimensions: UsageChartDimensions;
  readonly complete_events: number;
  readonly error_events: number;
  readonly events: number;
  readonly cache_read_tokens: number | null;
  readonly cache_write_tokens: number | null;
  readonly input_tokens: number | null;
  readonly output_tokens: number | null;
  readonly token_unknown_events: UsageTokenUnknownEvents;
}

export interface UsageChartOptions {
  readonly metric: UsageMetric;
  readonly group: UsageGroupDimension;
  readonly breakdown: UsageBreakdown;
}

// Exact query clipping bounds; display coverage includes intersecting global buckets.
export interface UsageTimeAxis {
  readonly startUnix: number;
  readonly endUnix: number;
  readonly bucketSeconds: number;
}

export interface UsageSeries {
  readonly id: string;
  readonly stackId: string;
  readonly name: string;
  readonly stack: string;
  readonly values: readonly (number | null)[];
  readonly partial: readonly boolean[];
}

export interface UsageErrorMark {
  readonly bucketStartUnix: number;
  readonly bucketSeconds: number;
  readonly errorEvents: number;
  readonly events: number;
}

export interface UsageTokenTotals {
  readonly cacheRead: number | null;
  readonly cacheWrite: number | null;
  readonly input: number | null;
  readonly output: number | null;
  readonly total: number | null;
}

export interface UsageSummary {
  readonly requests: number;
  readonly errorEvents: number;
  readonly incompleteEvents: number;
  readonly tokens: UsageTokenTotals;
  readonly tokenUnknownEvents: UsageTokenUnknownEvents;
}

export interface UsageChart {
  readonly requestedStartUnix: number;
  readonly requestedEndUnix: number;
  readonly axis: readonly number[];
  readonly bucketSeconds: number;
  readonly bucketTotals: readonly (number | null)[];
  readonly bucketTotalsPartial: readonly boolean[];
  readonly errors: readonly UsageErrorMark[];
  readonly series: readonly UsageSeries[];
  readonly summary: UsageSummary;
}

export type UsageChartRefusal =
  | { readonly kind: "invalid_input"; readonly message: string }
  | {
      readonly kind: "resource_limit";
      readonly resource: "buckets" | "series";
      readonly observed: number;
      readonly limit: number;
    }
  | { readonly kind: "inconsistent_view"; readonly message: string }
  | {
      readonly kind: "numeric_overflow";
      readonly observed: string;
      readonly minimum: number;
      readonly maximum: number;
    };

export type UsageChartResult =
  | ({ readonly ok: true } & UsageChart)
  | ({ readonly ok: false } & UsageChartRefusal);

export const usageTokenDimensions = [
  "cache_read_tokens",
  "cache_write_tokens",
  "input_tokens",
  "output_tokens",
] as const satisfies readonly UsageTokenDimension[];

export const usageTokenLabels = {
  cache_read_tokens: "Cache read",
  cache_write_tokens: "Cache write",
  input_tokens: "Input",
  output_tokens: "Output",
} as const satisfies Record<UsageTokenDimension, string>;

const unknownLabels = {
  client: "Unknown client",
  model: "Unknown model",
  provider: "Unknown provider",
} as const satisfies Record<UsageChartDimensionName, string>;

type Sum = {
  readonly value: bigint;
  readonly known: bigint;
  readonly unknown: bigint;
};
const emptySum = (): Sum => ({ value: 0n, known: 0n, unknown: 0n });
type Identity =
  | readonly ["total"]
  | readonly [UsageChartDimensionName, string | null]
  | readonly ["token", UsageTokenDimension];

class NumericOverflow extends Error {}

function safeNumber(value: bigint): number {
  if (value > BigInt(Number.MAX_SAFE_INTEGER) || value < 0n) {
    throw new NumericOverflow(value.toString());
  }
  return Number(value);
}

function at<T>(values: readonly T[], index: number): T {
  const value = values[index];
  if (value === undefined)
    throw new Error("chart accumulator index out of bounds");
  return value;
}

function nullableNumber(value: Sum): number | null {
  return value.known === 0n && value.unknown > 0n
    ? null
    : safeNumber(value.value);
}

function partial(value: Sum): boolean {
  return value.known > 0n && value.unknown > 0n;
}

function add(left: Sum, right: Sum): Sum {
  return {
    value: left.value + right.value,
    known: left.known + right.known,
    unknown: left.unknown + right.unknown,
  };
}

function tokens(row: UsageChartRow): Sum[] | null {
  const values: Sum[] = [];
  if (
    ![row.events, row.complete_events, row.error_events].every(
      (value) => Number.isSafeInteger(value) && value >= 0,
    ) ||
    row.complete_events > row.events ||
    row.error_events > row.events
  )
    return null;
  for (const key of usageTokenDimensions) {
    const unknown = row.token_unknown_events?.[key];
    const value = row[key];
    if (
      !Number.isSafeInteger(unknown) ||
      unknown < 0 ||
      unknown > row.events ||
      (value !== null && (!Number.isSafeInteger(value) || value < 0)) ||
      (row.events > 0 && (value === null) !== (unknown === row.events)) ||
      (row.events === 0 && value !== null && value !== 0)
    )
      return null;
    values.push({
      value: BigInt(value ?? 0),
      known: BigInt(row.events - unknown),
      unknown: BigInt(unknown),
    });
  }
  return values;
}

function identity(
  row: UsageChartRow,
  dimension: UsageGroupDimension,
): Identity {
  return dimension === "none"
    ? ["total"]
    : [dimension, row.dimensions[dimension] ?? null];
}

function label(value: Identity): string {
  if (value[0] === "total") return "Total";
  if (value[0] === "token") return usageTokenLabels[value[1]];
  return value[1] ?? unknownLabels[value[0]];
}

export function buildUsageChart(
  rows: readonly UsageChartRow[],
  axisInput: UsageTimeAxis,
  options: UsageChartOptions,
): UsageChartResult {
  const { startUnix, endUnix, bucketSeconds } = axisInput;
  const { breakdown, group, metric } = options;
  if (
    !Number.isSafeInteger(startUnix) ||
    !Number.isSafeInteger(endUnix) ||
    !Number.isSafeInteger(bucketSeconds) ||
    startUnix < 0 ||
    endUnix <= startUnix ||
    bucketSeconds <= 0
  ) {
    return { ok: false, kind: "invalid_input", message: "invalid time axis" };
  }
  if (
    (group !== "none" && group === breakdown) ||
    (breakdown === "token" &&
      (metric.kind !== "tokens" || metric.part !== "total"))
  ) {
    return {
      ok: false,
      kind: "invalid_input",
      message: "incompatible group, breakdown or metric",
    };
  }

  const bucket = BigInt(bucketSeconds);
  const first = BigInt(startUnix) / bucket;
  const count = (BigInt(endUnix) - 1n) / bucket - first + 1n;
  if (count > BigInt(usageChartLimits.maxBuckets)) {
    return {
      ok: false,
      kind: "resource_limit",
      resource: "buckets",
      observed: Number(count),
      limit: usageChartLimits.maxBuckets,
    };
  }
  const axis = Array.from({ length: Number(count) }, (_, i) =>
    Number((first + BigInt(i)) * bucket),
  );
  const indexes = new Map(axis.map((start, i) => [start, i]));
  const zeros = () => new Array<bigint>(axis.length).fill(0n);
  const sums = () => axis.map(emptySum);
  const bucketTotals: Sum[] = sums();
  const events = zeros();
  const errors = zeros();
  const series = new Map<
    string,
    Omit<UsageSeries, "values" | "partial"> & { values: Sum[] }
  >();
  let requests = 0n;
  let errorEvents = 0n;
  let incompleteEvents = 0n;
  const tokenTotals: Sum[] = usageTokenDimensions.map(emptySum);

  for (const row of rows) {
    for (const dimension of [group, breakdown]) {
      if (
        dimension !== "none" &&
        dimension !== "token" &&
        row.dimensions[dimension] === undefined
      ) {
        return {
          ok: false,
          kind: "inconsistent_view",
          message: `required ${dimension} dimension is absent from the query view`,
        };
      }
    }
    const index = indexes.get(row.bucket_start_unix);
    if (index === undefined) {
      return {
        ok: false,
        kind: "inconsistent_view",
        message: `aggregate bucket ${row.bucket_start_unix} is outside the aligned axis`,
      };
    }
    const parts = tokens(row);
    if (parts === null)
      return {
        ok: false,
        kind: "inconsistent_view",
        message: "invalid token counts or known-subtotal coverage",
      };
    const tokenTotal = parts.reduce(add, emptySum());
    const value =
      metric.kind === "requests"
        ? { value: BigInt(row.events), known: BigInt(row.events), unknown: 0n }
        : metric.part === "total"
          ? tokenTotal
          : at(parts, usageTokenDimensions.indexOf(metric.part));
    requests += BigInt(row.events);
    errorEvents += BigInt(row.error_events);
    incompleteEvents += BigInt(row.events) - BigInt(row.complete_events);
    for (let i = 0; i < tokenTotals.length; i++)
      tokenTotals[i] = add(at(tokenTotals, i), at(parts, i));
    events[index] = at(events, index) + BigInt(row.events);
    errors[index] = at(errors, index) + BigInt(row.error_events);
    bucketTotals[index] = add(at(bucketTotals, index), value);

    const groupIdentity = identity(row, group);
    const split: Identity[] =
      breakdown === "token"
        ? usageTokenDimensions.map((dimension) => ["token", dimension])
        : [identity(row, breakdown)];
    for (const part of split) {
      const id = JSON.stringify([groupIdentity, part]);
      let entry = series.get(id);
      if (entry === undefined) {
        if (series.size === usageChartLimits.maxSeries) {
          return {
            ok: false,
            kind: "resource_limit",
            resource: "series",
            observed: series.size + 1,
            limit: usageChartLimits.maxSeries,
          };
        }
        entry = {
          id,
          stackId: JSON.stringify(groupIdentity),
          stack: label(groupIdentity),
          name:
            group === "none"
              ? label(part)
              : breakdown === "none"
                ? label(groupIdentity)
                : `${label(groupIdentity)} / ${label(part)}`,
          values: sums(),
        };
        series.set(id, entry);
      }
      const contribution =
        part[0] === "token"
          ? at(parts, usageTokenDimensions.indexOf(part[1]))
          : value;
      entry.values[index] = add(at(entry.values, index), contribution);
    }
  }

  try {
    const totals = tokenTotals.map(nullableNumber);
    return {
      ok: true,
      requestedStartUnix: startUnix,
      requestedEndUnix: endUnix,
      axis,
      bucketSeconds,
      bucketTotals: bucketTotals.map(nullableNumber),
      bucketTotalsPartial: bucketTotals.map(partial),
      errors: axis.map((start, i) => ({
        bucketStartUnix: start,
        bucketSeconds,
        errorEvents: safeNumber(at(errors, i)),
        events: safeNumber(at(events, i)),
      })),
      series: [...series.values()]
        .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
        .map((entry) => ({
          ...entry,
          values: entry.values.map(nullableNumber),
          partial: entry.values.map(partial),
        })),
      summary: {
        requests: safeNumber(requests),
        errorEvents: safeNumber(errorEvents),
        incompleteEvents: safeNumber(incompleteEvents),
        tokenUnknownEvents: Object.fromEntries(
          usageTokenDimensions.map((key, index) => [
            key,
            safeNumber(at(tokenTotals, index).unknown),
          ]),
        ) as Record<UsageTokenDimension, number>,
        tokens: {
          cacheRead: at(totals, 0),
          cacheWrite: at(totals, 1),
          input: at(totals, 2),
          output: at(totals, 3),
          total: nullableNumber(tokenTotals.reduce(add, emptySum())),
        },
      },
    };
  } catch (error) {
    if (!(error instanceof NumericOverflow)) throw error;
    return {
      ok: false,
      kind: "numeric_overflow",
      observed: error.message,
      minimum: 0,
      maximum: Number.MAX_SAFE_INTEGER,
    };
  }
}
