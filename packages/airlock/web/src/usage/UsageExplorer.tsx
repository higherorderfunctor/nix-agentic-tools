import { Box, Stack } from "@mantine/core";
import { useEffect, useMemo, useState } from "react";
import { Status, values } from "../components/data.tsx";
import type { AppRuntime } from "../data/app.ts";
import type { SubscriptionQuery } from "../data/protocol.ts";
import type { ViewState } from "../data/reducer.ts";
import { useVisibleSubscription } from "../data/visibility.ts";
import { buildUsageChart, type UsageChartRow } from "./domain.ts";
import {
  type ExplorerSelection,
  explorerChartOptions,
  explorerDimensions,
  explorerWindow,
  initialExplorerState,
  type UsageExplorerState,
} from "./explorer.ts";
import {
  type UsageExplorerCompleteView,
  type UsageExplorerStatus,
  UsageExplorerView,
} from "./UsageExplorerView.tsx";

type ChartQuery = Extract<SubscriptionQuery, { kind: "requests.chart" }>;

export function liveUsageView(
  selection: ExplorerSelection,
  observed: ViewState | null,
): {
  view: UsageExplorerCompleteView | null;
  status: UsageExplorerStatus;
} {
  const options = explorerChartOptions(selection);
  if (options === null)
    return {
      view: null,
      status: {
        kind: "unavailable",
        message:
          "Cost unavailable — Airlock has no authoritative request-cost data.",
      },
    };
  if (observed?.phase === "failed")
    return {
      view: null,
      status: {
        kind: "error",
        message:
          observed.error ??
          "Live usage failed. Check the connection and filters.",
      },
    };
  const metadata = observed?.meta;
  const window = metadata?.window;
  const precision = metadata?.chart;
  if (
    observed === null ||
    metadata == null ||
    window == null ||
    precision === undefined
  )
    return {
      view: null,
      status: { kind: "loading", message: "Waiting for live usage data." },
    };
  const chart = buildUsageChart(
    values<UsageChartRow>(observed, "request_chart"),
    {
      startUnix: window.since_unix,
      endUnix: window.until_unix,
      bucketSeconds: precision.bucket_seconds,
    },
    options,
  );
  if (!chart.ok)
    return {
      view: null,
      status: {
        kind: "error",
        message: `Usage chart refused: ${chart.kind}. Narrow the range or grouping.`,
      },
    };
  const totals = {
    cache_read_tokens: chart.summary.tokens.cacheRead,
    cache_write_tokens: chart.summary.tokens.cacheWrite,
    input_tokens: chart.summary.tokens.input,
    output_tokens: chart.summary.tokens.output,
    total: chart.summary.tokens.total,
  };
  return {
    status:
      observed.phase === "live"
        ? { kind: "ready" }
        : {
            kind: "stale",
            message: `Last complete usage view · ${observed.phase}.`,
          },
    view: {
      asOfUnix: metadata.as_of_unix,
      chart,
      selection,
      label:
        selection.metric === "requests"
          ? "Routed requests"
          : `Routed ${selection.part === "total" ? "total tokens" : selection.part.replaceAll("_", " ")}`,
      summary: {
        requests: chart.summary.requests,
        errorEvents: chart.summary.errorEvents,
        incompleteEvents: chart.summary.incompleteEvents,
        total:
          options.metric.kind === "requests"
            ? chart.summary.requests
            : totals[options.metric.part],
      },
    },
  };
}

function LiveChart({
  runtime,
  query,
  state,
  onChange,
}: {
  runtime: AppRuntime;
  query: ChartQuery;
  state: UsageExplorerState;
  onChange: (state: UsageExplorerState) => void;
}) {
  const subscription = useVisibleSubscription(runtime, query);
  const observed =
    subscription.result._tag === "Success" ? subscription.result.value : null;
  const projection = useMemo(
    () => liveUsageView(state.selection, observed),
    [state.selection, observed],
  );
  const status: UsageExplorerStatus =
    subscription.result._tag === "Failure"
      ? {
          kind: "error",
          message:
            "Live usage could not be loaded. Check the connection and exact filters.",
        }
      : projection.status;
  return (
    <Box ref={subscription.targetRef}>
      <Stack>
        {observed !== null && observed.meta !== null && (
          <Status state={observed} />
        )}
        <UsageExplorerView
          state={state}
          onChange={onChange}
          view={projection.view}
          status={status}
        />
      </Stack>
    </Box>
  );
}

function useLocalDay(enabled: boolean) {
  const [day, setDay] = useState(() => new Date().toDateString());
  useEffect(() => {
    if (!enabled) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const refresh = () => {
      if (document.visibilityState === "visible")
        setDay(new Date().toDateString());
      clearTimeout(timer);
      const midnight = new Date();
      midnight.setHours(24, 0, 0, 0);
      timer = setTimeout(refresh, midnight.getTime() - Date.now() + 1);
    };
    refresh();
    document.addEventListener("visibilitychange", refresh);
    return () => {
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [enabled]);
  return day;
}

export function UsageExplorer({ runtime }: { readonly runtime: AppRuntime }) {
  const [state, setState] = useState(initialExplorerState);
  const { selection } = state;
  const day = useLocalDay(selection.range === "yesterday");
  const calendar = selection.range === "yesterday" ? day : "";
  const dimensionKey = explorerDimensions(selection).join(",");
  const dimensions = useMemo(
    () =>
      dimensionKey === ""
        ? []
        : (dimensionKey.split(",") as ChartQuery["dimensions"]),
    [dimensionKey],
  );
  const { client, model, provider } = selection.filters;
  const range = selection.range;
  // biome-ignore lint/correctness/useExhaustiveDependencies: local midnight invalidates fixed Yesterday bounds even when all query controls stay unchanged.
  const query = useMemo<ChartQuery>(() => {
    const bounds = explorerWindow(range, Math.floor(Date.now() / 1000));
    const window: ChartQuery["window"] =
      bounds.startUnix === null
        ? { all: true }
        : range === "yesterday"
          ? { since_unix: bounds.startUnix, until_unix: bounds.endUnix }
          : { last_seconds: bounds.endUnix - bounds.startUnix };
    return {
      kind: "requests.chart",
      dimensions,
      window,
      ...(client === undefined ? {} : { client }),
      ...(model === undefined ? {} : { model }),
      ...(provider === undefined ? {} : { provider }),
    };
  }, [calendar, client, dimensions, model, provider, range]);
  return selection.metric === "cost" ? (
    <UsageExplorerView
      state={state}
      onChange={setState}
      view={null}
      status={liveUsageView(selection, null).status}
    />
  ) : (
    <LiveChart
      key={JSON.stringify(query)}
      runtime={runtime}
      query={query}
      state={state}
      onChange={setState}
    />
  );
}
