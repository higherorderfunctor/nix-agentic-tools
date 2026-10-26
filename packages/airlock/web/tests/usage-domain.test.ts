import { describe, expect, it } from "vitest";
import {
  buildUsageChart,
  type UsageChartOptions,
  type UsageChartResult,
  type UsageChartRow,
  usageChartLimits,
} from "../src/usage/domain.ts";

const axis = { startUnix: 0, endUnix: 240, bucketSeconds: 60 };
const requests: UsageChartOptions = {
  breakdown: "none",
  group: "none",
  metric: { kind: "requests" },
};
const totalTokens: UsageChartOptions = {
  ...requests,
  metric: { kind: "tokens", part: "total" },
};
function row(fields: Partial<UsageChartRow> = {}): UsageChartRow {
  return {
    bucket_start_unix: 0,
    dimensions: { client: null, model: "model", provider: "provider" },
    complete_events: 1,
    error_events: 0,
    events: 2,
    cache_read_tokens: 3,
    cache_write_tokens: 4,
    input_tokens: 1,
    output_tokens: 2,
    ...fields,
  };
}
function ok(result: UsageChartResult) {
  if (!result.ok) throw new Error(JSON.stringify(result));
  return result;
}

describe("usage chart domain", () => {
  it("conserves requests across provider/model combinations and sums projected partial rows", () => {
    const rows = [
      row({ dimensions: { provider: "a", model: "x" }, error_events: 1 }),
      row({ dimensions: { provider: "a", model: "x" }, events: 3 }),
      row({ dimensions: { provider: "a", model: "y" }, bucket_start_unix: 60 }),
      row({
        dimensions: { provider: "b", model: "x" },
        bucket_start_unix: 180,
      }),
    ];
    for (const [group, breakdown] of [
      ["provider", "model"],
      ["model", "provider"],
    ] as const) {
      const chart = ok(
        buildUsageChart(rows, axis, { ...requests, group, breakdown }),
      );
      expect(chart.series).toHaveLength(3);
      expect(chart.bucketTotals).toEqual([5, 2, 0, 2]);
      expect(chart.summary).toMatchObject({
        requests: 9,
        errorEvents: 1,
        incompleteEvents: 5,
      });
      expect(
        chart.series.reduce(
          (sum, item) =>
            sum + item.values.reduce<number>((sum, v) => sum + (v ?? 0), 0),
          0,
        ),
      ).toBe(9);
      expect(chart.errors).toEqual([
        { bucketStartUnix: 0, bucketSeconds: 60, errorEvents: 1, events: 5 },
        { bucketStartUnix: 60, bucketSeconds: 60, errorEvents: 0, events: 2 },
        { bucketStartUnix: 120, bucketSeconds: 60, errorEvents: 0, events: 0 },
        { bucketStartUnix: 180, bucketSeconds: 60, errorEvents: 0, events: 2 },
      ]);
      expect(
        ok(
          buildUsageChart([...rows].reverse(), axis, {
            ...requests,
            group,
            breakdown,
          }),
        ),
      ).toEqual(chart);
    }
  });

  it("preserves unknown totals in either row order and keeps all known token parts", () => {
    const rows = [row({ input_tokens: null }), row()];
    for (const ordered of [rows, [...rows].reverse()]) {
      const chart = ok(
        buildUsageChart(ordered, axis, { ...totalTokens, breakdown: "token" }),
      );
      expect(chart.bucketTotals).toEqual([null, 0, 0, 0]);
      expect(
        ok(buildUsageChart(ordered, axis, totalTokens)).series[0]?.values,
      ).toEqual([null, 0, 0, 0]);
      expect(chart.summary.tokens).toEqual({
        cacheRead: 6,
        cacheWrite: 8,
        input: null,
        output: 4,
        total: null,
      });
      expect(chart.series.map(({ name, values }) => [name, values])).toEqual([
        ["Cache read", [6, 0, 0, 0]],
        ["Cache write", [8, 0, 0, 0]],
        ["Input", [null, 0, 0, 0]],
        ["Output", [4, 0, 0, 0]],
      ]);
    }
    const parts = [
      "cache_read_tokens",
      "cache_write_tokens",
      "input_tokens",
      "output_tokens",
    ] as const;
    for (const [index, part] of parts.entries()) {
      const chart = ok(
        buildUsageChart([row()], axis, {
          ...requests,
          metric: { kind: "tokens", part },
        }),
      );
      expect(chart.bucketTotals).toEqual([[3, 4, 1, 2][index], 0, 0, 0]);
    }

    for (const unknownPart of parts) {
      const chart = ok(
        buildUsageChart([row({ [unknownPart]: null })], axis, {
          ...totalTokens,
          breakdown: "token",
        }),
      );
      expect(chart.summary.tokens.total).toBeNull();
      expect(
        chart.series.filter(({ values }) => values[0] === null),
      ).toHaveLength(1);
      expect(
        chart.series.filter(({ values }) => values[0] !== null),
      ).toHaveLength(3);
    }
    const output = ok(
      buildUsageChart([row({ input_tokens: null })], axis, {
        ...requests,
        metric: { kind: "tokens", part: "output_tokens" },
      }),
    );
    expect(output.bucketTotals).toEqual([2, 0, 0, 0]);
    expect(output.summary.tokens.total).toBeNull();
  });

  it("keeps raw identities separate when display labels or separators collide", () => {
    const unknowns = ok(
      buildUsageChart(
        [
          row({ dimensions: { client: null } }),
          row({ dimensions: { client: "Unknown client" } }),
        ],
        axis,
        { ...requests, group: "client" },
      ),
    );
    expect(unknowns.series.map(({ name }) => name)).toEqual([
      "Unknown client",
      "Unknown client",
    ]);
    expect(new Set(unknowns.series.map(({ id }) => id)).size).toBe(2);
    expect(unknowns.series.map(({ values }) => values[0])).toEqual([2, 2]);
    const split = ok(
      buildUsageChart(
        [
          row({ dimensions: { provider: "a / b", model: "c" } }),
          row({ dimensions: { provider: "a", model: "b / c" } }),
        ],
        axis,
        { ...requests, group: "provider", breakdown: "model" },
      ),
    );
    expect(split.series.map(({ name }) => name)).toEqual([
      "a / b / c",
      "a / b / c",
    ]);
    expect(new Set(split.series.map(({ id }) => id)).size).toBe(2);
    expect(new Set(split.series.map(({ stackId }) => stackId)).size).toBe(2);
  });

  it("aligns partial endpoint buckets while retaining the original SQL clipping bounds", () => {
    const chart = ok(
      buildUsageChart(
        [
          row({ bucket_start_unix: 60 }),
          row({ bucket_start_unix: 120, events: 3 }),
        ],
        { startUnix: 61, endUnix: 121, bucketSeconds: 60 },
        requests,
      ),
    );
    expect(chart.axis).toEqual([60, 120]);
    expect(chart.requestedStartUnix).toBe(61);
    expect(chart.requestedEndUnix).toBe(121);
    expect(chart.summary.requests).toBe(5);
    expect(
      ok(
        buildUsageChart(
          [],
          { startUnix: 61, endUnix: 120, bucketSeconds: 60 },
          requests,
        ),
      ).axis,
    ).toEqual([60]);
  });

  it("zero-fills a known empty axis without inventing series", () => {
    const chart = ok(buildUsageChart([], axis, totalTokens));
    expect(chart.axis).toEqual([0, 60, 120, 180]);
    expect(chart.series).toEqual([]);
    expect(chart.bucketTotals).toEqual([0, 0, 0, 0]);
    expect(chart.summary.tokens).toEqual({
      cacheRead: 0,
      cacheWrite: 0,
      input: 0,
      output: 0,
      total: 0,
    });
  });

  it("refuses unsafe grouped counts and tokens independently of input order", () => {
    const rows = [
      row({ events: Number.MAX_SAFE_INTEGER }),
      row({ events: 1 }),
      row({ events: 1 }),
      row({ events: 1 }),
    ];
    for (const ordered of [rows, [...rows].reverse()]) {
      expect(buildUsageChart(ordered, axis, requests)).toMatchObject({
        ok: false,
        kind: "numeric_overflow",
        observed: "9007199254740994",
      });
    }
    expect(
      buildUsageChart(
        [row({ input_tokens: Number.MAX_SAFE_INTEGER })],
        axis,
        totalTokens,
      ),
    ).toMatchObject({ ok: false, kind: "numeric_overflow" });
    expect(
      ok(
        buildUsageChart(
          [row({ events: Number.MAX_SAFE_INTEGER })],
          axis,
          requests,
        ),
      ).summary.requests,
    ).toBe(Number.MAX_SAFE_INTEGER);
  });

  it("requires queried dimensions and refuses incompatible options or buckets outside the axis", () => {
    expect(
      buildUsageChart([row({ dimensions: {} })], axis, {
        ...requests,
        group: "client",
      }),
    ).toMatchObject({ ok: false, kind: "inconsistent_view" });
    expect(
      buildUsageChart([row()], axis, {
        ...requests,
        group: "model",
        breakdown: "model",
      }),
    ).toMatchObject({ ok: false, kind: "invalid_input" });
    expect(
      buildUsageChart([], axis, { ...requests, breakdown: "token" }),
    ).toMatchObject({ ok: false, kind: "invalid_input" });
    expect(
      buildUsageChart([row({ bucket_start_unix: 61 })], axis, requests),
    ).toMatchObject({ ok: false, kind: "inconsistent_view" });
    for (const invalid of [
      { ...axis, bucketSeconds: 0 },
      { ...axis, endUnix: 0 },
      { ...axis, startUnix: -1 },
      { ...axis, endUnix: Number.MAX_SAFE_INTEGER + 1 },
    ]) {
      expect(buildUsageChart([], invalid, requests)).toMatchObject({
        ok: false,
        kind: "invalid_input",
      });
    }
  });

  it("enforces both allocation bounds including token expansion and partial endpoints", () => {
    const maxAxis = { startUnix: 1, endUnix: 366 * 60, bucketSeconds: 60 };
    expect(ok(buildUsageChart([], maxAxis, requests)).axis).toHaveLength(
      usageChartLimits.maxBuckets,
    );
    expect(
      buildUsageChart(
        [],
        { ...maxAxis, endUnix: maxAxis.endUnix + 1 },
        requests,
      ),
    ).toMatchObject({
      ok: false,
      kind: "resource_limit",
      resource: "buckets",
      observed: 367,
    });
    const rows = Array.from({ length: 257 }, (_, i) =>
      row({ dimensions: { model: `model-${i}` } }),
    );
    expect(
      ok(
        buildUsageChart(rows.slice(0, 256), axis, {
          ...requests,
          group: "model",
        }),
      ).series,
    ).toHaveLength(256);
    expect(
      buildUsageChart(rows, axis, { ...requests, group: "model" }),
    ).toMatchObject({
      ok: false,
      kind: "resource_limit",
      resource: "series",
      observed: 257,
    });
    expect(
      buildUsageChart(rows.slice(0, 65), axis, {
        ...totalTokens,
        group: "model",
        breakdown: "token",
      }),
    ).toMatchObject({
      ok: false,
      kind: "resource_limit",
      resource: "series",
      observed: 257,
    });
  });
});
