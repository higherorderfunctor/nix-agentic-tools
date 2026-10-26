import type {
  UsageBreakdown,
  UsageChartDimensionName,
  UsageChartOptions,
  UsageTokenPart,
} from "./domain.ts";
import type { UsageLayout, UsageRender } from "./geometry.ts";

export type ExplorerMetric = "cost" | "requests" | "tokens";
export type ExplorerRange = "24h" | "yesterday" | "7d" | "month" | "all";
export interface ExplorerFilters {
  readonly client?: string | null;
  readonly model?: string;
  readonly provider?: string;
}
export interface ExplorerSelection {
  readonly filters: ExplorerFilters;
  readonly metric: ExplorerMetric;
  readonly part: UsageTokenPart;
  readonly range: ExplorerRange;
  readonly splitBy: "none" | UsageChartDimensionName;
  readonly stackBy: UsageBreakdown;
}
export interface UsageExplorerState {
  readonly layout: UsageLayout;
  readonly render: UsageRender;
  readonly selection: ExplorerSelection;
  readonly showErrors: boolean;
}
export const initialExplorerState: UsageExplorerState = {
  layout: "stack",
  render: "area",
  showErrors: true,
  selection: {
    filters: {},
    metric: "requests",
    part: "total",
    range: "24h",
    splitBy: "model",
    stackBy: "provider",
  },
};

export function selectExplorer(
  state: UsageExplorerState,
  patch: Partial<ExplorerSelection>,
): UsageExplorerState {
  const selection = { ...state.selection, ...patch };
  if (
    selection.stackBy === "token" &&
    (selection.metric !== "tokens" || selection.part !== "total")
  )
    selection.stackBy = "none";
  if (selection.stackBy !== "none" && selection.stackBy === selection.splitBy) {
    if (patch.splitBy !== undefined) selection.stackBy = "none";
    else selection.splitBy = "none";
  }
  return { ...state, selection };
}

// UI split identifies the independent stacks; UI stack identifies their segments.
export function explorerChartOptions(
  selection: ExplorerSelection,
): UsageChartOptions | null {
  if (selection.metric === "cost") return null;
  return {
    breakdown: selection.stackBy,
    group: selection.splitBy,
    metric:
      selection.metric === "tokens"
        ? { kind: "tokens", part: selection.part }
        : { kind: "requests" },
  };
}

export function explorerDimensions(
  selection: ExplorerSelection,
): UsageChartDimensionName[] {
  return [
    ...new Set(
      [selection.stackBy, selection.splitBy].filter(
        (value): value is UsageChartDimensionName =>
          value !== "none" && value !== "token",
      ),
    ),
  ].sort();
}

// This resolves a UI selection; the subscription adapter owns the wire window.
export function explorerWindow(range: ExplorerRange, asOfUnix: number) {
  if (range === "all") return { startUnix: null, endUnix: asOfUnix };
  if (range === "yesterday") {
    const end = new Date(asOfUnix * 1000);
    end.setHours(0, 0, 0, 0);
    const start = new Date(end);
    start.setDate(start.getDate() - 1);
    return { startUnix: start.getTime() / 1000, endUnix: end.getTime() / 1000 };
  }
  const seconds = { "24h": 86400, "7d": 604800, month: 2592000 }[range];
  return { startUnix: asOfUnix - seconds, endUnix: asOfUnix };
}

export function explorerSelectionKey(selection: ExplorerSelection) {
  return JSON.stringify({
    metric: selection.metric,
    part: selection.part,
    range: selection.range,
    splitBy: selection.splitBy,
    stackBy: selection.stackBy,
    filters: {
      client: selection.filters.client,
      model: selection.filters.model,
      provider: selection.filters.provider,
    },
  });
}
