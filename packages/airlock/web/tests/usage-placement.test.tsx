import { MantineProvider } from "@mantine/core";
import { act, cleanup, render } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { buildUsageChart } from "../src/usage/domain.ts";
import type { UsageLayout, UsageRender } from "../src/usage/geometry.ts";
import { UsagePlot } from "../src/usage/UsagePlot.tsx";

beforeEach(() => {
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
});

function fixture(sparse = false, startUnix = 0, endUnix = 180) {
  const values = sparse
    ? [
        [2, null, 4],
        [3, 2, null],
        [1, 3, 2],
        [5, 1, 7],
      ]
    : [
        [2, 4, 2],
        [3, 1, 3],
        [7, 2, 7],
        [1, 6, 1],
      ];
  const result = buildUsageChart(
    values.flatMap((series, order) =>
      series.map((value, bucket) => ({
        bucket_start_unix: bucket * 60,
        dimensions: {
          model: order < 2 ? "a" : "b",
          provider: order % 2 === 0 ? "x" : "y",
        },
        complete_events: value === null ? 0 : 1,
        error_events: 0,
        events: 1,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        input_tokens: value,
        output_tokens: 0,
        token_unknown_events: {
          cache_read_tokens: 0,
          cache_write_tokens: 0,
          input_tokens: value === null ? 1 : 0,
          output_tokens: 0,
        },
      })),
    ),
    { startUnix, endUnix, bucketSeconds: 60 },
    {
      metric: { kind: "tokens", part: "input_tokens" },
      group: "model",
      breakdown: "provider",
    },
  );
  if (!result.ok) throw new Error(JSON.stringify(result));
  return result;
}

function coordinates(element: Element | null) {
  const value = (name: string) => {
    const attribute = element?.getAttribute(name);
    if (attribute == null) throw new Error(`missing SVG ${name}`);
    return Number(attribute);
  };
  return {
    x: value("x"),
    y: value("y"),
    width: value("width"),
    height: value("height"),
  };
}
function bars(container: HTMLElement) {
  return [...container.querySelectorAll(".recharts-bar")].map((series) =>
    [...series.querySelectorAll("path.recharts-rectangle")].map(coordinates),
  );
}
const bottom = (rect: ReturnType<typeof coordinates>) => rect.y + rect.height;
const center = (rect: ReturnType<typeof coordinates>) =>
  rect.x + rect.width / 2;
function plot(
  chart: ReturnType<typeof fixture>,
  render: UsageRender,
  layout: UsageLayout,
) {
  return (
    <MantineProvider env="test">
      <UsagePlot
        chart={chart}
        render={render}
        layout={layout}
        label="Placement fixture"
      />
    </MantineProvider>
  );
}

it.each(["bar", "mixed"] as const)(
  "aligns %s stack segments and timestamp centers in three buckets with two independent stacks",
  (mode) => {
    const { container } = render(plot(fixture(), mode, "stack"));
    const bounds = coordinates(container.querySelector("clipPath rect"));
    const series = bars(container);
    expect(series).toHaveLength(4);
    expect(series.map((items) => items.length)).toEqual([3, 3, 3, 3]);
    for (let bucket = 0; bucket < 3; bucket++) {
      const rectangles = series.map((items) => items[bucket]);
      const [ax, ay, bx, by] = rectangles;
      if (!ax || !ay || !bx || !by) throw new Error("missing bar");
      expect(ax.x).toBeCloseTo(ay.x, 2);
      expect(bx.x).toBeCloseTo(by.x, 2);
      expect(ax.width).toBeCloseTo(ay.width, 2);
      expect(bx.width).toBeCloseTo(by.width, 2);
      expect(ax.x + ax.width).toBeLessThan(bx.x);
      expect(bottom(ax)).toBeCloseTo(bounds.y + bounds.height, 2);
      expect(bottom(bx)).toBeCloseTo(bounds.y + bounds.height, 2);
      expect(bottom(ay)).toBeCloseTo(ax.y, 2);
      expect(bottom(by)).toBeCloseTo(bx.y, 2);
      expect((ax.height + ay.height) / (bx.height + by.height)).toBeCloseTo(
        5 / 8,
        2,
      );
      for (const rect of [ax, ay, bx, by]) {
        expect(rect.x).toBeGreaterThanOrEqual(
          bounds.x + (bucket * bounds.width) / 3,
        );
        expect(rect.x + rect.width).toBeLessThanOrEqual(
          bounds.x + ((bucket + 1) * bounds.width) / 3,
        );
      }
      expect((center(ax) + center(bx)) / 2).toBeCloseTo(
        bounds.x + ((bucket + 0.5) * bounds.width) / 3,
        2,
      );
    }
  },
);

it.each(["bar", "mixed"] as const)(
  "groups every %s series within its bucket with a zero baseline",
  (mode) => {
    const { container } = render(plot(fixture(), mode, "overlay"));
    const bounds = coordinates(container.querySelector("clipPath rect"));
    const series = bars(container);
    for (let bucket = 0; bucket < 3; bucket++) {
      const rectangles = series.map((items) => items[bucket]);
      for (const [order, rect] of rectangles.entries()) {
        if (!rect) throw new Error("missing grouped bar");
        expect(bottom(rect)).toBeCloseTo(bounds.y + bounds.height, 2);
        expect(rect.x).toBeGreaterThanOrEqual(
          bounds.x + (bucket * bounds.width) / 3,
        );
        expect(rect.x + rect.width).toBeLessThanOrEqual(
          bounds.x + ((bucket + 1) * bounds.width) / 3,
        );
        const previous = rectangles[order - 1];
        if (previous) expect(previous.x + previous.width).toBeLessThan(rect.x);
      }
    }
  },
);

it.each(["bar", "mixed"] as const)(
  "keeps sparse %s values in their original clipped buckets and unknown bars absent",
  (mode) => {
    const { container } = render(plot(fixture(true, 50, 130), mode, "stack"));
    const bounds = coordinates(container.querySelector("clipPath rect"));
    const series = bars(container);
    expect(series.map((items) => items.length)).toEqual([2, 2, 3, 3]);
    const first = series[0]?.[0],
      third = series[0]?.[1],
      middle = series[1]?.[1];
    if (!first || !third || !middle) throw new Error("sparse bars absent");
    expect(first.x).toBeGreaterThanOrEqual(bounds.x);
    expect(first.x + first.width).toBeLessThanOrEqual(
      bounds.x + (bounds.width * 10) / 80,
    );
    expect(third.x).toBeGreaterThanOrEqual(bounds.x + (bounds.width * 70) / 80);
    expect(third.x + third.width).toBeLessThanOrEqual(bounds.x + bounds.width);
    expect(bottom(middle)).toBeCloseTo(bounds.y + bounds.height, 2);
  },
);

it("moves real bar geometry before tightening Y and expands Y before real stacking", () => {
  vi.useFakeTimers({
    toFake: ["requestAnimationFrame", "cancelAnimationFrame", "performance"],
  });
  const chart = fixture();
  const { container, rerender } = render(plot(chart, "bar", "stack"));
  const sample = () => {
    const [first, second] = bars(container);
    const a = first?.[0],
      b = second?.[0];
    if (!a || !b) throw new Error("motion bars absent");
    return { gap: Math.abs(a.x - b.x), height: a.height };
  };
  const initial = sample();
  expect(initial.gap).toBe(0);
  rerender(plot(chart, "bar", "overlay"));
  act(() => vi.advanceTimersByTime(120));
  const separating = sample();
  expect(separating.gap).toBeGreaterThan(0);
  expect(separating.height).toBeCloseTo(initial.height, 2);
  act(() => vi.advanceTimersByTime(360));
  const overlay = sample();
  expect(overlay.gap).toBeGreaterThan(separating.gap);
  expect(overlay.height).toBeGreaterThan(initial.height);
  rerender(plot(chart, "bar", "stack"));
  act(() => vi.advanceTimersByTime(120));
  const expanding = sample();
  expect(expanding.gap).toBeCloseTo(overlay.gap, 2);
  expect(expanding.height).toBeLessThan(overlay.height);
  act(() => vi.advanceTimersByTime(240));
  expect(sample().gap).toBeLessThan(expanding.gap);
  act(() => vi.advanceTimersByTime(120));
  expect(sample().gap).toBe(0);
});
