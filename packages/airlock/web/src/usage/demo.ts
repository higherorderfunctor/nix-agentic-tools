import {
  buildUsageChart,
  type UsageChartDimensionName,
  type UsageChartRow,
  type UsageTokenDimension,
} from "./domain.ts";
import {
  type ExplorerSelection,
  explorerChartOptions,
  explorerDimensions,
  explorerWindow,
} from "./explorer.ts";
import type { UsagePlotData } from "./plot.ts";
import type {
  UsageExplorerCompleteView,
  UsageExplorerStatus,
} from "./UsageExplorerView.tsx";

export const demoAsOfUnix = Date.UTC(2026, 9, 26, 23) / 1000;
const demoHours = 72 * 24;
export interface DemoFact {
  readonly atUnix: number;
  readonly costMicroDollars: number;
  readonly dimensions: Readonly<Record<UsageChartDimensionName, string | null>>;
  readonly usage: Omit<UsageChartRow, "bucket_start_unix" | "dimensions">;
}

// Assigned fixture costs are independent of token counts and are not provider prices.
export const demoFacts: readonly DemoFact[] = (() => {
  const facts: DemoFact[] = [];
  for (let hour = 0; hour < demoHours; hour++) {
    const at = demoAsOfUnix - demoHours * 3600 + hour * 3600;
    const date = new Date(at * 1000);
    const workday =
      date.getUTCDay() > 0 &&
      date.getUTCDay() < 6 &&
      date.getUTCHours() >= 14 &&
      date.getUTCHours() < 23;
    const batch = date.getUTCHours() === 3 && hour % 5 === 0;
    if (!workday && !batch && hour % 7 !== 0) continue;
    for (let lane = 0; lane < 6; lane++) {
      const ordinal = facts.length;
      const events =
        (workday ? 18 : 4) +
        lane * 3 +
        (batch ? 80 : 0) +
        (hour % 29 === 0 ? 200 : 0);
      const incomplete =
        ordinal % 997 === 31 || (hour === demoHours - 4 && lane === 1);
      facts.push({
        atUnix: at + lane * 300 + 60,
        costMicroDollars:
          10000 + ((ordinal * 7919) % 90000) + (batch ? 300000 : 0),
        dimensions: {
          client:
            ["editor", "nightly-batch", null, "Unknown client"][
              (hour + lane) % 4
            ] ?? null,
          model: lane % 2 === 0 ? "atlas-large" : "orion-fast",
          provider:
            lane % 3 === 0 ? "Anthropic" : lane % 3 === 1 ? "OpenAI" : "z.ai",
        },
        usage: {
          complete_events: events - Number(incomplete),
          error_events:
            ordinal % 503 === 27 || (hour === demoHours - 5 && lane === 2)
              ? 1 + (lane % 2)
              : 0,
          events,
          cache_read_tokens: events * (lane % 3) * 40,
          cache_write_tokens: events * (lane % 2) * 15,
          input_tokens:
            incomplete && ordinal % 2 === 0
              ? null
              : events * (200 + ((hour * 17 + lane * 101) % 700)),
          output_tokens:
            incomplete && ordinal % 2 !== 0 ? null : events * (70 + lane * 20),
        },
      });
    }
  }
  return facts;
})();

type MutableRow = {
  -readonly [Key in keyof UsageChartRow]: UsageChartRow[Key];
};
type Aggregate = { row: MutableRow; costMicroDollars: number };
const add = (left: number | null, right: number | null): number | null =>
  left === null || right === null ? null : left + right;

function aggregate(
  facts: readonly DemoFact[],
  selection: ExplorerSelection,
  start: number,
  end: number,
  bucket: number,
) {
  const dimensions = explorerDimensions(selection);
  const groups = new Map<string, Aggregate>();
  for (const fact of facts) {
    if (
      fact.atUnix < start ||
      fact.atUnix >= end ||
      !Object.entries(selection.filters).every(
        ([key, value]) =>
          fact.dimensions[key as UsageChartDimensionName] === value,
      )
    )
      continue;
    const bucketStart = Math.floor(fact.atUnix / bucket) * bucket;
    const identity = JSON.stringify([
      bucketStart,
      dimensions.map((key) => fact.dimensions[key]),
    ]);
    const current = groups.get(identity);
    if (current === undefined)
      groups.set(identity, {
        row: {
          ...fact.usage,
          bucket_start_unix: bucketStart,
          dimensions: Object.fromEntries(
            dimensions.map((key) => [key, fact.dimensions[key]]),
          ),
        },
        costMicroDollars: fact.costMicroDollars,
      });
    else {
      current.row.complete_events += fact.usage.complete_events;
      current.row.error_events += fact.usage.error_events;
      current.row.events += fact.usage.events;
      for (const key of Object.keys(fact.usage).filter((key) =>
        key.endsWith("_tokens"),
      ) as UsageTokenDimension[])
        current.row[key] = add(current.row[key], fact.usage[key]);
      current.costMicroDollars += fact.costMicroDollars;
    }
  }
  return [...groups.values()];
}

function costPlot(
  aggregates: readonly Aggregate[],
  requests: UsagePlotData,
  selection: ExplorerSelection,
): UsagePlotData | null {
  const stackBy = selection.stackBy;
  if (stackBy === "token") return null;
  const totals = requests.axis.map(() => 0);
  const values = new Map<string, number[]>();
  for (const { row, costMicroDollars } of aggregates) {
    const index = requests.axis.indexOf(row.bucket_start_unix);
    if (index < 0) return null;
    // Match the domain's typed key; names, stack IDs and colors keep its metadata.
    const group =
      selection.splitBy === "none"
        ? ["total"]
        : [selection.splitBy, row.dimensions[selection.splitBy] ?? null];
    const segment =
      stackBy === "none"
        ? ["total"]
        : [stackBy, row.dimensions[stackBy] ?? null];
    const id = JSON.stringify([group, segment]);
    const amounts = values.get(id) ?? requests.axis.map(() => 0);
    amounts[index] = (amounts[index] ?? 0) + costMicroDollars;
    totals[index] = (totals[index] ?? 0) + costMicroDollars;
    values.set(id, amounts);
  }
  if (values.size !== requests.series.length) return null;
  const series = [];
  for (const item of requests.series) {
    const amounts = values.get(item.id);
    if (amounts === undefined) return null;
    series.push({ ...item, values: amounts });
  }
  return {
    ...requests,
    bucketTotals: totals,
    series,
  };
}

const costFormat = new Intl.NumberFormat("en-US", {
  currency: "USD",
  maximumFractionDigits: 3,
  style: "currency",
});
export const formatDemoCost = (value: number) =>
  costFormat.format(value / 1_000_000);
export function demoView(
  selection: ExplorerSelection,
  facts: readonly DemoFact[] = demoFacts,
  asOfUnix = demoAsOfUnix,
): { view: UsageExplorerCompleteView | null; status: UsageExplorerStatus } {
  const window = explorerWindow(selection.range, asOfUnix);
  const oldest = facts.reduce(
    (start, fact) => Math.min(start, fact.atUnix),
    asOfUnix,
  );
  if (oldest >= asOfUnix)
    return {
      view: null,
      status: {
        kind: "unavailable",
        message: "No synthetic history before the demo clock.",
      },
    };
  const startUnix = window.startUnix ?? oldest;
  const bucketSeconds =
    selection.range === "24h" || selection.range === "yesterday" ? 3600 : 86400;
  const aggregates = aggregate(
    facts,
    selection,
    startUnix,
    window.endUnix,
    bucketSeconds,
  );
  const result = buildUsageChart(
    aggregates.map((entry) => entry.row),
    { startUnix, endUnix: window.endUnix, bucketSeconds },
    explorerChartOptions(selection) ?? {
      metric: { kind: "requests" },
      group: selection.splitBy,
      breakdown: selection.stackBy,
    },
  );
  if (!result.ok)
    return {
      view: null,
      status: {
        kind: "error",
        message: `Synthetic view refused: ${result.kind}. Narrow the range or grouping.`,
      },
    };
  const { ok: _ok, summary, ...plot } = result;
  const chart =
    selection.metric === "cost" ? costPlot(aggregates, plot, selection) : plot;
  if (chart === null)
    return {
      view: null,
      status: {
        kind: "error",
        message:
          "Synthetic cost series identities do not match the request projection.",
      },
    };
  return {
    status: { kind: "ready" },
    view: {
      asOfUnix,
      chart,
      selection,
      label:
        selection.metric === "cost"
          ? "Illustrative cost (USD)"
          : `Synthetic ${selection.metric === "requests" ? "requests" : selection.part === "total" ? "total tokens" : selection.part.replaceAll("_", " ")}`,
      ...(selection.metric === "cost" ? { formatValue: formatDemoCost } : {}),
      summary: {
        errorEvents: summary.errorEvents,
        incompleteEvents: summary.incompleteEvents,
        requests: summary.requests,
        total: chart.bucketTotals.reduce<number | null>(add, 0),
      },
    },
  };
}
