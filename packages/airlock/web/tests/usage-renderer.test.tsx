import { MantineProvider } from "@mantine/core";
import {
  act,
  cleanup,
  fireEvent,
  render,
  renderHook,
  screen,
} from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { buildUsageChart, type UsageChart } from "../src/usage/domain.ts";
import {
  bucketPosition,
  usageGeometry,
  usageRenderFits,
  usageRenderLimits,
  usageRenderPoints,
} from "../src/usage/geometry.ts";
import { usageMotionStageMs, useUsageMotion } from "../src/usage/motion.ts";
import { UsagePlot } from "../src/usage/UsagePlot.tsx";

function chart(): UsageChart {
  const result = buildUsageChart(
    ["a", "b"].map((model) => ({
      bucket_start_unix: 0,
      dimensions: { provider: "p", model },
      complete_events: 1,
      error_events: 1,
      events: 10,
      input_tokens: model === "a" ? null : 20,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
    })),
    { startUnix: 50, endUnix: 75, bucketSeconds: 60 },
    {
      metric: { kind: "tokens", part: "total" },
      group: "provider",
      breakdown: "model",
    },
  );
  if (!result.ok) throw new Error(JSON.stringify(result));
  return result;
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("usage geometry", () => {
  it("preserves opaque identity and unknown stack bases, independently per stack", () => {
    const source = chart();
    const input = {
      ...source,
      series: [
        ...source.series,
        {
          id: "literal.[]",
          stackId: "another",
          stack: "p",
          name: "p / b",
          values: [7, 0],
        },
      ],
    };
    const geometry = usageGeometry(input, "area");
    expect(geometry?.series.map((item) => item.id)).toEqual(
      input.series.map((item) => item.id),
    );
    expect(geometry?.series.map((item) => item.ranges[0])).toEqual([
      null,
      null,
      [0, 7],
    ]);
    expect(geometry?.overlayMax).toBe(21);
    expect(geometry?.stackMax).toBe(21);
    expect(input.series[1]?.values[0]).toBe(20);
  });

  it("uses the largest independent stack and includes the authoritative total in mixed mode", () => {
    const input = {
      ...chart(),
      bucketTotals: [30, null],
      series: [
        { id: "a", stackId: "p", stack: "p", name: "a", values: [8, null] },
        { id: "b", stackId: "p", stack: "p", name: "b", values: [12, 0] },
        { id: "c", stackId: "q", stack: "q", name: "c", values: [10, 0] },
      ],
    };
    expect(usageGeometry(input, "line")?.stackMax).toBe(21);
    expect(usageGeometry(input, "mixed")?.stackMax).toBe(31.5);
    expect(usageGeometry(input, "mixed")?.overlayMax).toBe(31.5);
    expect(bucketPosition(input, 0)).toBe(50);
    expect(bucketPosition(input, 60)).toBe(75);
    expect(
      usageGeometry({ ...input, axis: Array(367).fill(0) }, "line"),
    ).toBeNull();
    expect(
      usageGeometry(
        { ...input, series: Array(257).fill(input.series[0]) },
        "line",
      ),
    ).toBeNull();
  });
});

function animationClock() {
  let now = 0;
  let next = 0;
  const pending = new Map<number, FrameRequestCallback>();
  vi.spyOn(performance, "now").mockImplementation(() => now);
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
    pending.set(++next, callback);
    return next;
  });
  vi.stubGlobal("cancelAnimationFrame", (id: number) => {
    pending.delete(id);
  });
  return {
    pending,
    advance(ms: number) {
      now += ms;
      const callbacks = [...pending.values()];
      pending.clear();
      act(() => {
        for (const callback of callbacks) callback(now);
      });
    },
  };
}

describe("usage motion", () => {
  it("moves geometry before tightening Y, then expands Y before stacking", () => {
    const clock = animationClock();
    const identity = {};
    const { result, rerender } = renderHook(
      ({ layout, maximum }) => useUsageMotion(identity, layout, maximum, true),
      {
        initialProps: { layout: "stack" as "stack" | "overlay", maximum: 100 },
      },
    );
    rerender({ layout: "overlay", maximum: 40 });
    clock.advance(120);
    expect(result.current).toMatchObject({ stacking: 0.5, maximum: 100 });
    clock.advance(180);
    expect(result.current.stacking).toBe(0);
    expect(result.current.maximum).toBeGreaterThan(40);
    clock.advance(180);
    expect(result.current).toMatchObject({ stacking: 0, maximum: 40 });
    rerender({ layout: "stack", maximum: 100 });
    clock.advance(120);
    expect(result.current.stacking).toBe(0);
    expect(result.current.maximum).toBe(70);
    clock.advance(240);
    expect(result.current).toMatchObject({ stacking: 0.5, maximum: 100 });
  });

  it("cancels stale frames on fast reversals, unmount and reduced motion", () => {
    const clock = animationClock();
    const identity = {};
    const { result, rerender, unmount } = renderHook(
      ({ layout, maximum, animate }) =>
        useUsageMotion(identity, layout, maximum, animate),
      {
        initialProps: {
          layout: "stack" as "stack" | "overlay",
          maximum: 100,
          animate: true,
        },
      },
    );
    rerender({ layout: "overlay", maximum: 40, animate: true });
    clock.advance(120);
    rerender({ layout: "stack", maximum: 100, animate: true });
    expect(clock.pending.size).toBe(1);
    clock.advance(usageMotionStageMs * 2);
    expect(result.current).toEqual({ stacking: 1, maximum: 100, phase: "" });
    rerender({ layout: "overlay", maximum: 40, animate: false });
    expect(result.current).toEqual({ stacking: 0, maximum: 40, phase: "" });
    expect(clock.pending.size).toBe(0);
    rerender({ layout: "stack", maximum: 100, animate: true });
    unmount();
    expect(clock.pending.size).toBe(0);
  });
});

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

it("offers bucket inspection with unknowns and bucket-level error counts", () => {
  sizePlot();
  const input = chart();
  const { container, rerender } = render(
    <MantineProvider>
      <UsagePlot
        chart={input}
        label="Routed tokens"
        layout="overlay"
        render="line"
      />
    </MantineProvider>,
  );
  const selector = screen.getByRole("combobox", { name: "Inspect bucket" });
  fireEvent.click(selector);
  fireEvent.click(screen.getAllByRole("option")[0] as HTMLElement);
  expect(screen.getByText("p / a: Unknown")).toBeTruthy();
  expect(screen.getByText("p / b: 20")).toBeTruthy();
  expect(screen.getByText("2 errors within bucket / 20 requests")).toBeTruthy();
  expect(
    container.querySelectorAll(".recharts-reference-line line"),
  ).toHaveLength(1);
  expect(
    container
      .querySelector(".recharts-reference-line line")
      ?.getAttribute("stroke-width"),
  ).toBe("1");
  rerender(
    <MantineProvider>
      <UsagePlot
        chart={input}
        label="Routed tokens"
        layout="overlay"
        render="mixed"
        showErrors={false}
      />
    </MantineProvider>,
  );
  expect(
    container.querySelectorAll(".recharts-reference-line line"),
  ).toHaveLength(0);
});

it.each(["line", "area", "mixed"] as const)(
  "keeps isolated %s values visible without dots on continuous segments",
  (mode) => {
    sizePlot();
    const source = chart();
    const series = source.series[0];
    if (series === undefined) throw new Error("fixture series absent");
    const input = {
      ...source,
      requestedStartUnix: 0,
      requestedEndUnix: 180,
      axis: [0, 60, 120],
      bucketTotals: [null, 10, null],
      errors: [],
      series: [{ ...series, values: [null, 10, null] }],
    };
    const plot = (
      value: UsageChart,
      layout: "overlay" | "stack" = "overlay",
    ) => (
      <MantineProvider>
        <UsagePlot chart={value} label="Tokens" layout={layout} render={mode} />
      </MantineProvider>
    );
    const { container, rerender } = render(plot(input));
    const dots = () => [...container.querySelectorAll("circle.recharts-dot")];
    expect(dots()).toHaveLength(1);
    expect(Number(dots()[0]?.getAttribute("cx"))).toBeGreaterThan(72);
    expect(Number(dots()[0]?.getAttribute("cy"))).toBeLessThan(282);
    rerender(
      plot({
        ...input,
        bucketTotals: [10, 10, 10],
        series: [{ ...series, values: [10, 10, 10] }],
      }),
    );
    expect(dots()).toHaveLength(0);
    // The upper raw series is continuous, but its displayed stack has one known point.
    rerender(
      plot(
        {
          ...input,
          series: [
            { ...series, values: [null, 0, null] },
            { ...series, id: "upper", values: [10, 10, 10] },
          ],
        },
        "stack",
      ),
    );
    expect(dots()).toHaveLength(mode === "mixed" ? 1 : 2);
  },
);

it("refuses point budgets before reading values and counts the mixed total line", () => {
  const source = chart();
  const dense = (count: number): UsageChart => ({
    ...source,
    axis: Array.from({ length: 100 }, (_, i) => i * 60),
    series: Array.from({ length: count }, (_, i) => ({
      id: String(i),
      name: String(i),
      stack: "All",
      stackId: "all",
      get values(): readonly (number | null)[] {
        throw new Error("per-point allocation reached");
      },
    })),
  });
  const bars = dense(usageRenderLimits.points.bar / 100);
  expect(usageRenderFits(bars, "bar")).toBe(true);
  expect(usageRenderPoints(bars, "mixed")).toBe(
    usageRenderLimits.points.bar + 100,
  );
  expect(usageGeometry(bars, "mixed")).toBeNull();
  const lines = dense(usageRenderLimits.points.line / 100);
  expect(usageRenderFits(lines, "line")).toBe(true);
  const excessive = dense(lines.series.length + 1);
  expect(usageGeometry(excessive, "line")).toBeNull();
  expect(usageGeometry(excessive, "area")).toBeNull();
  const plot = (value: UsageChart) => (
    <MantineProvider>
      <UsagePlot chart={value} label="Tokens" layout="stack" render="mixed" />
    </MantineProvider>
  );
  const { container, rerender } = render(plot(bars));
  expect(screen.getByText(/or choose line mode/)).toBeTruthy();
  expect(container.querySelector(".recharts-wrapper")).toBeNull();
  rerender(plot(excessive));
  expect(screen.queryByText(/choose line mode/)).toBeNull();
});
