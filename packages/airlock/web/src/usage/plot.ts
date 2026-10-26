import type { UsageChart } from "./domain.ts";

export type UsagePlotData = Pick<
  UsageChart,
  | "axis"
  | "bucketSeconds"
  | "bucketTotals"
  | "errors"
  | "requestedEndUnix"
  | "requestedStartUnix"
  | "series"
>;
