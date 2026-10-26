import { MantineProvider } from "@mantine/core";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  within,
} from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { buildUsageChart } from "../src/usage/domain.ts";
import {
  explorerChartOptions,
  explorerDimensions,
  explorerSelectionKey,
  explorerWindow,
  initialExplorerState,
  selectExplorer,
} from "../src/usage/explorer.ts";
import { usageGeometry } from "../src/usage/geometry.ts";
import type { UsagePlotData } from "../src/usage/plot.ts";
import {
  type UsageExplorerCompleteView,
  UsageExplorerView,
} from "../src/usage/UsageExplorerView.tsx";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("explorer selection", () => {
  it("keeps split models independent when the user selects Stack by None", () => {
    const onChange = vi.fn<(state: typeof initialExplorerState) => void>();
    render(
      frame(
        <UsageExplorerView
          state={initialExplorerState}
          onChange={onChange}
          view={null}
          status={{ kind: "loading", message: "Loading" }}
        />,
      ),
    );
    fireEvent.change(screen.getByLabelText("Stack by"), {
      target: { value: "none" },
    });
    const selected = onChange.mock.lastCall?.[0];
    if (!selected) throw new Error("selection callback absent");
    const options = explorerChartOptions(selected.selection);
    expect(options).toEqual({
      group: "model",
      breakdown: "none",
      metric: { kind: "requests" },
    });
    if (!options) throw new Error("request options absent");
    const chart = buildUsageChart(
      [2, 3].map((events, index) => ({
        bucket_start_unix: 0,
        dimensions: { model: String(index) },
        complete_events: events,
        error_events: 0,
        events,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        input_tokens: 0,
        output_tokens: 0,
        token_unknown_events: {
          cache_read_tokens: 0,
          cache_write_tokens: 0,
          input_tokens: 0,
          output_tokens: 0,
        },
      })),
      { startUnix: 0, endUnix: 60, bucketSeconds: 60 },
      options,
    );
    if (!chart.ok) throw new Error(JSON.stringify(chart));
    expect(new Set(chart.series.map((item) => item.stackId)).size).toBe(2);
    const geometry = usageGeometry(chart, "bar");
    expect(geometry?.series.map((item) => item.ranges[0])).toEqual([
      [0, 2],
      [0, 3],
    ]);
    expect(geometry?.stackMax).toBeCloseTo(3 * 1.05);
  });
  it("stacks provider segments within independent model stacks", () => {
    const options = explorerChartOptions(initialExplorerState.selection);
    expect(options).toEqual({
      group: "model",
      breakdown: "provider",
      metric: { kind: "requests" },
    });
    if (options === null) throw new Error("requests options missing");
    const result = buildUsageChart(
      [
        ["a", "x"],
        ["b", "x"],
        ["a", "y"],
      ].map(([provider, model]) => ({
        bucket_start_unix: 0,
        dimensions: { provider: provider ?? "", model: model ?? "" },
        token_unknown_events: {
          cache_read_tokens: 0,
          cache_write_tokens: 0,
          input_tokens: 0,
          output_tokens: 0,
        },
        complete_events: 1,
        error_events: 0,
        events: 1,
        input_tokens: 1,
        output_tokens: 1,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
      })),
      { startUnix: 0, endUnix: 60, bucketSeconds: 60 },
      options,
    );
    if (!result.ok) throw new Error(JSON.stringify(result));
    expect(result.series.filter((item) => item.stack === "x")).toHaveLength(2);
    expect(new Set(result.series.map((item) => item.stackId)).size).toBe(2);
    expect(explorerDimensions(initialExplorerState.selection)).toEqual([
      "model",
      "provider",
    ]);
  });

  it("normalizes dependent selections atomically and leaves cost out of live chart options", () => {
    const model = selectExplorer(initialExplorerState, { stackBy: "model" });
    expect(model.selection).toMatchObject({
      stackBy: "model",
      splitBy: "none",
    });
    expect(
      selectExplorer(initialExplorerState, { splitBy: "provider" }).selection,
    ).toMatchObject({ stackBy: "none", splitBy: "provider" });
    const token = selectExplorer(initialExplorerState, {
      metric: "tokens",
      stackBy: "token",
    });
    expect(explorerChartOptions(token.selection)).toMatchObject({
      group: "model",
      breakdown: "token",
    });
    for (const patch of [
      { part: "input_tokens" },
      { metric: "requests" },
      { metric: "cost" },
    ] as const)
      expect(selectExplorer(token, patch).selection.stackBy).toBe("none");
    expect(
      explorerChartOptions(selectExplorer(token, { metric: "cost" }).selection),
    ).toBeNull();
    expect(
      explorerDimensions({
        ...model.selection,
        filters: { provider: "filtered" },
      }),
    ).toEqual(["model"]);
    expect(explorerSelectionKey({ ...model.selection, filters: {} })).not.toBe(
      explorerSelectionKey({ ...model.selection, filters: { client: null } }),
    );
    expect(
      explorerSelectionKey({
        ...model.selection,
        filters: { provider: "p", model: "m" },
      }),
    ).toBe(
      explorerSelectionKey({
        ...model.selection,
        filters: { model: "m", provider: "p" },
      }),
    );
  });

  it("resolves rolling30days and calendar yesterday across both DST transitions", () => {
    vi.stubEnv("TZ", "America/Denver");
    for (const [asOf, hours] of [
      ["2026-03-09T12:00:00-06:00", 23],
      ["2026-11-02T12:00:00-07:00", 25],
    ] as const) {
      const now = Date.parse(asOf) / 1000;
      const range = explorerWindow("yesterday", now);
      expect(range.endUnix - (range.startUnix ?? 0)).toBe(hours * 3600);
      expect(new Date((range.startUnix ?? 0) * 1000).getHours()).toBe(0);
      expect(explorerWindow("month", now)).toEqual({
        startUnix: now - 30 * 86400,
        endUnix: now,
      });
      expect(explorerWindow("all", now)).toEqual({
        startUnix: null,
        endUnix: now,
      });
    }
  });
});

const plot: UsagePlotData = {
  axis: [0, 60, 120],
  bucketSeconds: 60,
  bucketTotals: [1_000_000, 1_000_000, 1_000_000],
  bucketTotalsPartial: [false, false, false],
  summary: {
    requests: 3,
    tokenUnknownEvents: {
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      input_tokens: 0,
      output_tokens: 0,
    },
  },
  requestedStartUnix: 0,
  requestedEndUnix: 180,
  errors: [],
  series: [
    {
      id: "synthetic",
      name: "Synthetic",
      stack: "All",
      stackId: "all",
      values: [1_000_000, 1_000_000, 1_000_000],
      partial: [false, false, false],
    },
  ],
};
const view: UsageExplorerCompleteView = {
  asOfUnix: 180,
  chart: plot,
  label: "Routed requests",
  selection: initialExplorerState.selection,
  summary: {
    total: 3_000_000,
    requests: 3,
    errorEvents: 0,
    incompleteEvents: 0,
  },
};
function frame(node: React.ReactNode) {
  return <MantineProvider env="test">{node}</MantineProvider>;
}

function sizePlot() {
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
}

it("applies exact filters explicitly, distinguishes unknown client, clears to omission, and preserves chart-only selection identity", async () => {
  sizePlot();
  const onChange = vi.fn();
  const { rerender } = render(
    frame(
      <UsageExplorerView
        state={initialExplorerState}
        onChange={onChange}
        view={view}
        status={{ kind: "loading", message: "Updating" }}
      />,
    ),
  );
  fireEvent.click(screen.getByRole("button", { name: "Client" }));
  fireEvent.change(await screen.findByLabelText("Client exact ID"), {
    target: { value: "literal client" },
  });
  expect(onChange).not.toHaveBeenCalled();
  fireEvent.click(await screen.findByRole("button", { name: "Apply" }));
  const applied = onChange.mock.lastCall?.[0];
  expect(applied.selection.filters).toEqual({ client: "literal client" });
  rerender(
    frame(
      <UsageExplorerView
        state={applied}
        onChange={onChange}
        view={view}
        status={{ kind: "loading", message: "Updating" }}
      />,
    ),
  );
  fireEvent.click(
    screen.getByRole("button", { name: "Client: literal client" }),
  );
  fireEvent.click(
    await screen.findByRole("button", { name: "Unknown client" }),
  );
  const unknown = onChange.mock.lastCall?.[0];
  expect(unknown.selection.filters).toEqual({ client: null });
  rerender(
    frame(
      <UsageExplorerView
        state={unknown}
        onChange={onChange}
        view={view}
        status={{ kind: "loading", message: "Updating" }}
      />,
    ),
  );
  fireEvent.click(screen.getByRole("button", { name: "Client: Unknown" }));
  fireEvent.click(await screen.findByRole("button", { name: "Clear" }));
  expect(onChange.mock.lastCall?.[0].selection.filters).toEqual({});
  fireEvent.change(screen.getByLabelText("Layout"), {
    target: { value: "overlay" },
  });
  expect(onChange.mock.lastCall?.[0].selection).toBe(unknown.selection);
});

it("hides mismatched complete data and shows explicit unavailable cost without a plot", () => {
  const changed = selectExplorer(initialExplorerState, { range: "all" });
  const { container, rerender } = render(
    frame(
      <UsageExplorerView
        state={changed}
        onChange={() => {}}
        view={view}
        status={{ kind: "ready" }}
      />,
    ),
  );
  expect(screen.getByText("Updating usage selection…")).toBeTruthy();
  expect(container.querySelector("figure")).toBeNull();
  const cost = selectExplorer(changed, { metric: "cost" });
  rerender(
    frame(
      <UsageExplorerView
        state={cost}
        onChange={() => {}}
        view={null}
        status={{
          kind: "unavailable",
          message:
            "Cost unavailable — Airlock has no authoritative request-cost data.",
        }}
      />,
    ),
  );
  expect(screen.getByText(/Cost unavailable/)).toBeTruthy();
  expect(container.querySelector("figure")).toBeNull();
  expect(screen.getByRole("radio", { name: "Cost" })).toBeTruthy();
  expect(screen.queryByText("Today")).toBeNull();
});

it("uses supplied money formatting on summary, Y scale and bucket values without a token summary", () => {
  sizePlot();
  const cost = selectExplorer(initialExplorerState, { metric: "cost" });
  const money = new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
  });
  const { container } = render(
    frame(
      <UsageExplorerView
        state={cost}
        onChange={() => {}}
        status={{ kind: "ready" }}
        view={{
          ...view,
          selection: cost.selection,
          label: "Illustrative cost (USD)",
          formatValue: (value) => money.format(value / 1_000_000),
        }}
      />,
    ),
  );
  expect(screen.getByText("$3.00")).toBeTruthy();
  expect(
    within(screen.getByRole("list", { name: "Chart series" })).getByText(
      "Synthetic",
    ),
  ).toBeTruthy();
  expect(
    container.querySelector(".recharts-yAxis-tick-labels")?.textContent,
  ).toContain("$");
  fireEvent.click(screen.getByRole("combobox", { name: "Inspect bucket" }));
  fireEvent.click(
    within(screen.getByRole("listbox")).getAllByRole(
      "option",
    )[0] as HTMLElement,
  );
  expect(screen.getByText("Synthetic: $1.00")).toBeTruthy();
  expect(screen.getByText("Total: $1.00")).toBeTruthy();
});
