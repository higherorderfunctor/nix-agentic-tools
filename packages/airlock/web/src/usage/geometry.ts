import { usageChartLimits } from "./domain.ts";
import type { UsagePlotData } from "./plot.ts";

export type UsageLayout = "overlay" | "stack";
export type UsageRender = "area" | "bar" | "line" | "mixed";

export const usageRenderLimits = {
  animatedPoints: { area: 2000, bar: 250, line: 2000, mixed: 250 },
  points: { area: 10000, bar: 2000, line: 10000, mixed: 2000 },
} as const;

export function usageRenderPoints(chart: UsagePlotData, render: UsageRender) {
  return (
    chart.axis.length * (chart.series.length + (render === "mixed" ? 1 : 0))
  );
}

export function usageRenderFits(chart: UsagePlotData, render: UsageRender) {
  return (
    chart.axis.length <= usageChartLimits.maxBuckets &&
    chart.series.length <= usageChartLimits.maxSeries &&
    usageRenderPoints(chart, render) <= usageRenderLimits.points[render]
  );
}

// Unknown segments keep null geometry but do not erase known contributions above them.
export function usageGeometry(chart: UsagePlotData, render: UsageRender) {
  if (!usageRenderFits(chart, render)) return null;
  const bases = new Map<string, number[]>();
  let overlayMax = 1;
  let stackMax = 1;
  const series = chart.series.map((item) => {
    const base = bases.get(item.stackId) ?? chart.axis.map(() => 0);
    const ranges = item.values.map((value, i) => {
      const lower = base[i] ?? 0;
      const upper = lower + (value ?? 0);
      if (value !== null) overlayMax = Math.max(overlayMax, value);
      stackMax = Math.max(stackMax, upper);
      base[i] = upper;
      return value === null ? null : ([lower, value] as const);
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
  // Both layouts share scale headroom for every known contribution.
  return {
    series,
    overlayMax: overlayMax * 1.05,
    stackMax: Math.max(stackMax, overlayMax) * 1.05,
  };
}

export function bucketPosition(chart: UsagePlotData, start: number) {
  return Math.max(
    chart.requestedStartUnix,
    Math.min(chart.requestedEndUnix, start + chart.bucketSeconds / 2),
  );
}
