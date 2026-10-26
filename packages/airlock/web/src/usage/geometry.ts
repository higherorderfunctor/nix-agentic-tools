import { type UsageChart, usageChartLimits } from "./domain.ts";

export type UsageLayout = "overlay" | "stack";
export type UsageRender = "area" | "bar" | "line" | "mixed";

export const usageRenderLimits = {
  animatedPoints: { area: 2000, bar: 250, line: 2000, mixed: 250 },
  points: { area: 10000, bar: 2000, line: 10000, mixed: 2000 },
} as const;

export function usageRenderPoints(chart: UsageChart, render: UsageRender) {
  return (
    chart.axis.length * (chart.series.length + (render === "mixed" ? 1 : 0))
  );
}

export function usageRenderFits(chart: UsageChart, render: UsageRender) {
  return (
    chart.axis.length <= usageChartLimits.maxBuckets &&
    chart.series.length <= usageChartLimits.maxSeries &&
    usageRenderPoints(chart, render) <= usageRenderLimits.points[render]
  );
}

// A missing lower contribution makes the stack above it unknown too.
export function usageGeometry(chart: UsageChart, render: UsageRender) {
  if (!usageRenderFits(chart, render)) return null;
  const bases = new Map<string, (number | null)[]>();
  let overlayMax = 1;
  let stackMax = 1;
  const series = chart.series.map((item) => {
    const base = bases.get(item.stackId) ?? chart.axis.map(() => 0);
    const ranges = item.values.map((value, i) => {
      const lower = base[i] ?? null;
      const upper = lower === null || value === null ? null : lower + value;
      if (value !== null) overlayMax = Math.max(overlayMax, value);
      if (upper !== null) stackMax = Math.max(stackMax, upper);
      base[i] = upper;
      return lower === null || value === null
        ? null
        : ([lower, value] as const);
    });
    bases.set(item.stackId, base);
    return { ...item, ranges };
  });
  if (render === "mixed") {
    for (const value of chart.bucketTotals) {
      overlayMax = Math.max(overlayMax, value ?? 0);
      stackMax = Math.max(stackMax, value ?? 0);
    }
  }
  // Known values hidden above an unknown base must fit when overlay reveals them.
  return {
    series,
    overlayMax: overlayMax * 1.05,
    stackMax: Math.max(stackMax, overlayMax) * 1.05,
  };
}

export function bucketPosition(chart: UsageChart, start: number) {
  return Math.max(
    chart.requestedStartUnix,
    Math.min(chart.requestedEndUnix, start + chart.bucketSeconds / 2),
  );
}
