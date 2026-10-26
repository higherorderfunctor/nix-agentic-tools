import { RegistryProvider } from "@effect/atom-react";
import { MantineProvider } from "@mantine/core";
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import * as AsyncResult from "effect/reactivity/AsyncResult";
import * as Atom from "effect/reactivity/Atom";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { AppRuntime } from "../src/data/app.ts";
import * as app from "../src/data/app.ts";
import type { SubscriptionQuery } from "../src/data/protocol.ts";
import { initialViewState, type ViewState } from "../src/data/reducer.ts";
import { initialExplorerState, selectExplorer } from "../src/usage/explorer.ts";
import { liveUsageView, UsageExplorer } from "../src/usage/UsageExplorer.tsx";
import { App } from "../src/views/App.tsx";
import { RequestHistory } from "../src/views/RequestHistory.tsx";

type ChartQuery = Extract<SubscriptionQuery, { kind: "requests.chart" }>;
const initialQuery: ChartQuery = {
  kind: "requests.chart",
  dimensions: ["model", "provider"],
  window: { last_seconds: 86400 },
};
class Observer {
  readonly callback: IntersectionObserverCallback;
  constructor(callback: IntersectionObserverCallback) {
    this.callback = callback;
  }
  observe(target: Element) {
    this.callback(
      [{ target, isIntersecting: true }] as IntersectionObserverEntry[],
      this as unknown as IntersectionObserver,
    );
  }
  disconnect() {}
  unobserve() {}
}
beforeEach(() => {
  vi.stubGlobal("IntersectionObserver", Observer);
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockReturnValue({
    width: 800,
    height: 320,
    x: 0,
    y: 0,
    top: 0,
    left: 0,
    right: 800,
    bottom: 320,
    toJSON: () => ({}),
  });
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
  window.location.hash = "";
});
function frame(children: React.ReactNode) {
  return (
    <MantineProvider env="test">
      <RegistryProvider>{children}</RegistryProvider>
    </MantineProvider>
  );
}
function source(query: ChartQuery): ViewState {
  const now = 1800000000;
  const window =
    "all" in query.window
      ? { since_unix: now - 37 * 86400, until_unix: now }
      : "last_seconds" in query.window
        ? { since_unix: now - query.window.last_seconds, until_unix: now }
        : query.window;
  const bucket =
    "all" in query.window
      ? 172800
      : window.until_unix - window.since_unix <= 2 * 86400
        ? 3600
        : 86400;
  const row = {
    bucket_start_unix: Math.floor((window.until_unix - 1) / bucket) * bucket,
    dimensions: Object.fromEntries(
      query.dimensions.map((key) => [
        key,
        query[key] ?? (key === "client" ? null : `${key}-one`),
      ]),
    ),
    complete_events: 17,
    error_events: 1,
    events: 17,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    input_tokens: 100,
    output_tokens: 50,
    token_unknown_events: {
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      input_tokens: 0,
      output_tokens: 0,
    },
  };
  const entries = new Map([["request_chart:one", row]]);
  return {
    ...initialViewState(),
    phase: "live",
    entries,
    lastGoodEntries: entries,
    meta: {
      as_of_unix: now,
      window,
      oldest_at_unix: window.since_unix,
      has_more: false,
      next_before: null,
      truncated: false,
      known_gaps: [],
      request_loss_total: 0,
      provider_snapshot_loss_total: 0,
      reset_events_observed_only: true,
      reset_events_complete_since_unix: null,
      chart: { bucket_seconds: bucket, dimensions: query.dimensions },
    },
  };
}
function runtime(pending = false) {
  const queries: ChartQuery[] = [];
  const subscriptionAtom = vi.fn((query: SubscriptionQuery) => {
    if (query.kind !== "requests.chart") throw new Error("unexpected query");
    queries.push(query);
    const value =
      pending && queries.length > 1 ? initialViewState() : source(query);
    return Atom.make(AsyncResult.success(value));
  });
  return { queries, subscriptionAtom } satisfies AppRuntime & {
    queries: ChartQuery[];
  };
}

it("projects the same complete server axis and uses domain metric totals, including all-unknown populated tokens", () => {
  const query = { ...initialQuery, window: { all: true } } as const;
  const observed = source(query);
  const selection = selectExplorer(initialExplorerState, {
    range: "all",
    metric: "tokens",
    part: "output_tokens",
  }).selection;
  const row = observed.entries.get("request_chart:one");
  if (row === undefined || !("dimensions" in row))
    throw new Error("chart fixture absent");
  const entries = new Map([
    [
      "request_chart:one",
      {
        ...row,
        complete_events: 0,
        output_tokens: null,
        token_unknown_events: {
          cache_read_tokens: 0,
          cache_write_tokens: 0,
          input_tokens: 0,
          output_tokens: row.events,
        },
      },
    ],
  ]);
  const result = liveUsageView(selection, { ...observed, entries });
  expect(result.view?.chart.requestedStartUnix).toBe(
    observed.meta?.window?.since_unix,
  );
  expect(result.view?.chart.bucketSeconds).toBe(172800);
  expect(result.view?.chart).toHaveProperty("summary.requests", 17);
  expect(result.view?.summary.total).toBeNull();
  expect(
    liveUsageView(selection, { ...observed, phase: "reconnecting" }).status
      .kind,
  ).toBe("stale");
  expect(
    liveUsageView(selection, {
      ...observed,
      phase: "failed",
      error: "query_budget_exceeded",
    }),
  ).toMatchObject({
    view: null,
    status: { kind: "error", message: "query_budget_exceeded" },
  });
});

it("reuses the chart query for metrics and visual controls, applying exact filters only on Apply", async () => {
  const live = runtime();
  render(frame(<UsageExplorer runtime={live} />));
  await screen.findByRole("figure", { name: "Routed requests" });
  expect(live.queries).toEqual([initialQuery]);
  fireEvent.click(screen.getByRole("radio", { name: "Tokens" }));
  fireEvent.click(screen.getByRole("radio", { name: "In" }));
  fireEvent.change(screen.getByLabelText("Style"), {
    target: { value: "line" },
  });
  fireEvent.change(screen.getByLabelText("Layout"), {
    target: { value: "overlay" },
  });
  fireEvent.click(screen.getByLabelText("Errors within buckets"));
  expect(live.queries).toHaveLength(1);
  fireEvent.click(screen.getByRole("button", { name: "Provider" }));
  fireEvent.change(await screen.findByLabelText("Provider exact ID"), {
    target: { value: "exact-provider" },
  });
  expect(live.queries).toHaveLength(1);
  fireEvent.click(await screen.findByRole("button", { name: "Apply" }));
  await waitFor(() =>
    expect(live.queries.at(-1)).toEqual({
      ...initialQuery,
      provider: "exact-provider",
    }),
  );
  fireEvent.change(screen.getByLabelText("Stack by"), {
    target: { value: "model" },
  });
  await waitFor(() =>
    expect(live.queries.at(-1)?.dimensions).toEqual(["model"]),
  );
});

it("hides another query's retained plot while replacement data is pending", async () => {
  const live = runtime(true);
  render(frame(<UsageExplorer runtime={live} />));
  await screen.findByRole("figure", { name: "Routed requests" });
  fireEvent.click(screen.getByRole("radio", { name: "7d" }));
  await waitFor(() =>
    expect(live.queries.at(-1)?.window).toEqual({ last_seconds: 604800 }),
  );
  expect(screen.queryByRole("figure")).toBeNull();
  expect(screen.getByText("Waiting for live usage data.")).toBeTruthy();
});

it("leaves live chart queries while Cost is unavailable and resumes the selected range on return", async () => {
  const live = runtime();
  render(frame(<UsageExplorer runtime={live} />));
  await screen.findByRole("figure", { name: "Routed requests" });
  fireEvent.click(screen.getByRole("radio", { name: "Cost" }));
  expect(screen.getByText(/Cost unavailable/)).toBeTruthy();
  expect(screen.queryByRole("figure")).toBeNull();
  fireEvent.click(screen.getByRole("radio", { name: "Month" }));
  expect(live.queries).toHaveLength(1);
  fireEvent.click(screen.getByRole("radio", { name: "Requests" }));
  await waitFor(() =>
    expect(live.queries.at(-1)?.window).toEqual({ last_seconds: 2592000 }),
  );
});

it("refreshes Yesterday at local midnight across DST and does not refresh rolling queries", async () => {
  vi.useFakeTimers();
  vi.stubEnv("TZ", "America/Denver");
  vi.setSystemTime(new Date("2026-11-01T23:59:59-07:00"));
  const live = runtime();
  render(frame(<UsageExplorer runtime={live} />));
  fireEvent.click(screen.getByRole("radio", { name: "Yesterday" }));
  const first = live.queries.at(-1)?.window;
  expect(first).toEqual({
    since_unix: Date.parse("2026-10-31T00:00:00-06:00") / 1000,
    until_unix: Date.parse("2026-11-01T00:00:00-06:00") / 1000,
  });
  await act(async () => {
    await vi.advanceTimersByTimeAsync(1100);
  });
  const second = live.queries.at(-1)?.window;
  expect(second).toEqual({
    since_unix: Date.parse("2026-11-01T00:00:00-06:00") / 1000,
    until_unix: Date.parse("2026-11-02T00:00:00-07:00") / 1000,
  });
  fireEvent.click(screen.getByRole("radio", { name: "24h" }));
  const calls = live.queries.length;
  await act(async () => {
    await vi.advanceTimersByTimeAsync(86400000);
  });
  expect(live.queries).toHaveLength(calls);
});

it("keeps raw details unsubscribed until expanded and never creates live runtime for unauthenticated Demo", async () => {
  const subscriptionAtom = vi.fn(() =>
    Atom.make(AsyncResult.success(initialViewState())),
  );
  const raw = render(frame(<RequestHistory runtime={{ subscriptionAtom }} />));
  expect(subscriptionAtom).not.toHaveBeenCalled();
  fireEvent.click(
    screen.getByRole("button", { name: "Expand raw request details" }),
  );
  await waitFor(() => expect(subscriptionAtom).toHaveBeenCalledOnce());
  fireEvent.click(
    screen.getByRole("button", { name: "Collapse raw request details" }),
  );
  expect(screen.queryByText("Raw-table filters and live tail")).toBeNull();
  raw.unmount();
  const factory = vi.spyOn(app, "fixtureAppRuntime");
  const socket = vi.fn();
  vi.stubGlobal("WebSocket", socket);
  window.location.hash = "#demo";
  render(frame(<App />));
  expect(screen.getByText("Synthetic demo data")).toBeTruthy();
  expect(screen.queryByLabelText(/Airlock read token/)).toBeNull();
  expect(factory).not.toHaveBeenCalled();
  expect(socket).not.toHaveBeenCalled();
  expect(screen.queryByRole("link", { name: "Request history" })).toBeNull();
});
