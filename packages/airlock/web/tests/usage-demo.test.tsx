import { MantineProvider } from "@mantine/core";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DemoUsageExplorer } from "../src/usage/DemoUsageExplorer.tsx";
import type { DemoFact } from "../src/usage/demo.ts";
import * as demo from "../src/usage/demo.ts";
import {
  type ExplorerSelection,
  initialExplorerState,
  selectExplorer,
} from "../src/usage/explorer.ts";
import { usageRenderFits } from "../src/usage/geometry.ts";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});
const select = (patch: Partial<ExplorerSelection>) =>
  selectExplorer(initialExplorerState, patch).selection;
function complete(selection: ExplorerSelection, facts?: readonly DemoFact[]) {
  const result = demo.demoView(selection, facts);
  if (result.view === null) throw new Error(JSON.stringify(result.status));
  return result.view;
}
const sum = (values: readonly (number | null)[]) =>
  values.some((value) => value === null)
    ? null
    : values.reduce<number>((total, value) => total + (value ?? 0), 0);

describe("deterministic synthetic usage", () => {
  it("is repeatable without wall-clock/random inputs and has sparse errors and incomplete facts", () => {
    vi.spyOn(Date, "now").mockImplementation(() => {
      throw new Error("wall clock accessed");
    });
    vi.spyOn(Math, "random").mockImplementation(() => {
      throw new Error("random source accessed");
    });
    const before = JSON.stringify(demo.demoFacts);
    for (const metric of ["requests", "tokens", "cost"] as const)
      expect(demo.demoView(select({ metric, range: "all" }))).toEqual(
        demo.demoView(select({ metric, range: "all" })),
      );
    expect(JSON.stringify(demo.demoFacts)).toBe(before);
    expect(demo.demoFacts.length).toBeLessThan(10000);
    expect(
      demo.demoAsOfUnix -
        Math.min(...demo.demoFacts.map((fact) => fact.atUnix)),
    ).toBe(72 * 86400 - 60);
    const current = complete(select({}));
    expect(
      current.chart.errors.filter((mark) => mark.errorEvents > 0),
    ).toHaveLength(1);
    expect(current.summary.incompleteEvents).toBe(1);
    expect(
      demo.demoFacts.filter((fact) => fact.usage.error_events > 0).length,
    ).toBeLessThan(15);
  });

  it("uses all five actual ranges for all metrics, retaining nullable token totals and independent known costs", () => {
    for (const range of ["24h", "yesterday", "7d", "month", "all"] as const) {
      const requests = complete(select({ range }));
      const tokens = complete(select({ range, metric: "tokens" }));
      const cost = complete(select({ range, metric: "cost" }));
      expect(cost.summary.requests).toBe(requests.summary.total);
      expect(tokens.summary.requests).toBe(requests.summary.total);
      expect(cost.chart.axis).toEqual(requests.chart.axis);
      expect(tokens.chart.errors).toEqual(cost.chart.errors);
      expect(typeof cost.summary.total).toBe("number");
      expect(usageRenderFits(cost.chart, "mixed")).toBe(true);
    }
    expect(
      complete(select({ range: "month", metric: "tokens" })).summary.total,
    ).toBeGreaterThan(0);
    expect(complete(select({ range: "all" })).chart.axis).toHaveLength(73);
    expect(demo.demoView(select({ range: "all" }), []).status.kind).toBe(
      "unavailable",
    );
  });

  it("conserves each metric across stack/split combinations while reusing authoritative series metadata", () => {
    for (const [stackBy, splitBy] of [
      ["provider", "model"],
      ["model", "provider"],
      ["client", "provider"],
      ["provider", "client"],
      ["none", "model"],
      ["provider", "none"],
      ["none", "none"],
    ] as const) {
      const requests = complete(select({ range: "all", stackBy, splitBy }));
      const tokens = complete(
        select({ range: "all", metric: "tokens", stackBy, splitBy }),
      );
      const cost = complete(
        select({ range: "all", metric: "cost", stackBy, splitBy }),
      );
      expect(
        cost.chart.series.map(({ values: _values, ...metadata }) => metadata),
      ).toEqual(
        requests.chart.series.map(
          ({ values: _values, ...metadata }) => metadata,
        ),
      );
      for (const view of [requests, tokens, cost]) {
        for (let bucket = 0; bucket < view.chart.axis.length; bucket++)
          expect(
            sum(view.chart.series.map((item) => item.values[bucket] ?? null)),
          ).toBe(view.chart.bucketTotals[bucket]);
        expect(sum(view.chart.bucketTotals)).toBe(view.summary.total);
        expect(usageRenderFits(view.chart, "mixed")).toBe(true);
      }
      expect(cost.summary.total).toBe(
        demo.demoFacts.reduce(
          (total, fact) => total + fact.costMicroDollars,
          0,
        ),
      );
      expect(requests.summary.total).toBe(
        demo.demoFacts.reduce((total, fact) => total + fact.usage.events, 0),
      );
    }
  });
});

const fact = (
  client: string | null,
  provider: string,
  costMicroDollars: number,
): DemoFact => ({
  atUnix: demo.demoAsOfUnix - 3600,
  costMicroDollars,
  dimensions: { client, model: "shared-model", provider },
  usage: {
    token_unknown_events: {
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      input_tokens: 0,
      output_tokens: 0,
    },
    complete_events: 2,
    error_events: 0,
    events: 2,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    input_tokens: 10,
    output_tokens: 5,
  },
});
const fixture = [
  fact(null, "a", 100000),
  fact("Unknown client", "b", 2000000),
  fact("editor", "a", 300000),
];

it("applies exact/null filters before aggregation, preserves literal unknown identity, and derives All from provided history", () => {
  const selection = select({
    range: "all",
    stackBy: "none",
    splitBy: "none",
    metric: "cost",
  });
  expect(complete(selection, fixture).chart.requestedStartUnix).toBe(
    fixture[0]?.atUnix,
  );
  expect(
    complete({ ...selection, filters: { client: null } }, fixture).summary
      .total,
  ).toBe(100000);
  expect(
    complete({ ...selection, filters: { client: "Unknown client" } }, fixture)
      .summary.total,
  ).toBe(2000000);
  expect(
    complete(
      { ...selection, filters: { provider: "a", model: "shared-model" } },
      fixture,
    ).summary.total,
  ).toBe(400000);
  expect(
    complete({ ...selection, filters: { provider: "missing" } }, fixture).chart
      .series,
  ).toEqual([]);
  const clients = complete(
    { ...selection, stackBy: "client" },
    fixture,
  ).chart.series.filter((item) => item.name === "Unknown client");
  expect(clients).toHaveLength(2);
  expect(clients[0]?.id).not.toBe(clients[1]?.id);
  expect(
    clients.map((item) => sum(item.values)).sort((a, b) => (a ?? 0) - (b ?? 0)),
  ).toEqual([100000, 2000000]);
});

it("keeps independently assigned cost separate when either costs or tokens change", () => {
  const selection = select({ metric: "cost" });
  const changed = fixture.map((item) => ({
    ...item,
    costMicroDollars: item.costMicroDollars * 3,
  }));
  expect(complete(selection, changed).summary.total).toBe(
    (complete(selection, fixture).summary.total ?? 0) * 3,
  );
  for (const metric of ["tokens", "requests"] as const)
    expect(complete({ ...selection, metric }, changed).chart).toEqual(
      complete({ ...selection, metric }, fixture).chart,
    );
  const unknown = fixture.map((item) => ({
    ...item,
    usage: {
      ...item.usage,
      input_tokens: null,
      token_unknown_events: {
        ...item.usage.token_unknown_events,
        input_tokens: item.usage.events,
      },
    },
  }));
  expect(complete(selection, unknown).summary.total).toBe(
    complete(selection, fixture).summary.total,
  );
  expect(
    complete({ ...selection, metric: "tokens" }, unknown).summary.total,
  ).toBeGreaterThan(0);
  expect(
    Object.keys(complete(selection, fixture).chart.summary).sort(),
  ).toEqual(["requests", "tokenUnknownEvents"]);
});

it("renders the explicit demo without socket/auth access and memoizes chart-only control changes", () => {
  const socket = vi.fn(() => {
    throw new Error("socket accessed");
  });
  const fetch = vi.fn(() => {
    throw new Error("network accessed");
  });
  vi.stubGlobal("WebSocket", socket);
  vi.stubGlobal("fetch", fetch);
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
  const projection = vi.spyOn(demo, "demoView");
  render(
    <MantineProvider env="test">
      <DemoUsageExplorer />
    </MantineProvider>,
  );
  expect(screen.getByText("Synthetic demo data")).toBeTruthy();
  expect(screen.getByText(/not provider pricing or live spend/)).toBeTruthy();
  const calls = projection.mock.calls.length;
  fireEvent.change(screen.getByLabelText("Layout"), {
    target: { value: "overlay" },
  });
  fireEvent.change(screen.getByLabelText("Style"), {
    target: { value: "line" },
  });
  fireEvent.click(screen.getByLabelText("Errors within buckets"));
  expect(projection.mock.calls).toHaveLength(calls);
  fireEvent.click(screen.getByRole("radio", { name: "Cost" }));
  expect(screen.getAllByText("Illustrative cost (USD)").length).toBeGreaterThan(
    0,
  );
  expect(projection.mock.calls.length).toBe(calls + 1);
  expect(socket).not.toHaveBeenCalled();
  expect(fetch).not.toHaveBeenCalled();
});
