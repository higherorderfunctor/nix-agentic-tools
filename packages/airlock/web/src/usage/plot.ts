import type { UsageChart, UsageSummary } from "./domain.ts";

export type UsagePlotData = Pick<
  UsageChart,
  | "axis"
  | "bucketSeconds"
  | "bucketTotals"
  | "bucketTotalsPartial"
  | "errors"
  | "requestedEndUnix"
  | "requestedStartUnix"
  | "series"
> & { readonly summary: Pick<UsageSummary, "requests" | "tokenUnknownEvents"> };
