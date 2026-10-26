import { Alert, Box, Select, Stack, Text } from "@mantine/core";
import { useReducedMotion } from "@mantine/hooks";
import { useMemo, useState } from "react";
import {
  Area,
  Bar,
  CartesianGrid,
  ComposedChart,
  type DotItemDotProps,
  Line,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import type { UsageChart } from "./domain.ts";
import {
  bucketPosition,
  type UsageLayout,
  type UsageRender,
  usageGeometry,
  usageRenderFits,
  usageRenderLimits,
  usageRenderPoints,
} from "./geometry.ts";
import { useUsageMotion } from "./motion.ts";

export interface UsagePlotProps {
  readonly chart: UsageChart;
  readonly label: string;
  readonly layout: UsageLayout;
  readonly render: UsageRender;
  readonly height?: number;
  readonly showErrors?: boolean;
}

const number = new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 });
const compact = new Intl.NumberFormat(undefined, { notation: "compact" });
const date = (unix: number) => new Date(unix * 1000).toLocaleString();
const valueLabel = (value: number | null | undefined) =>
  value == null ? "Unknown" : number.format(value);
function color(id: string) {
  let hash = 0;
  for (const char of id) hash = (hash * 31 + char.charCodeAt(0)) | 0;
  return `hsl(${(hash >>> 0) % 360} 64% 55%)`;
}

function isolatedDot({ cx, cy, index, points, stroke }: DotItemDotProps) {
  if (
    cx === undefined ||
    cy === undefined ||
    points[index - 1]?.y != null ||
    points[index + 1]?.y != null
  )
    return null;
  return (
    <circle className="recharts-dot" cx={cx} cy={cy} fill={stroke} r={3} />
  );
}

function BucketDetails({ chart, index }: { chart: UsageChart; index: number }) {
  const at = chart.axis[index];
  if (at === undefined) return null;
  const error = chart.errors.find((mark) => mark.bucketStartUnix === at);
  return (
    <Stack gap={2}>
      <Text size="xs">
        Bucket: {date(at)} – {date(at + chart.bucketSeconds)}
      </Text>
      {chart.series.map((item) => (
        <Text key={item.id} size="xs" c={color(item.id)}>
          {item.name}: {valueLabel(item.values[index])}
        </Text>
      ))}
      <Text size="xs">Total: {valueLabel(chart.bucketTotals[index])}</Text>
      {error && (
        <Text size="xs">
          {number.format(error.errorEvents)} errors within bucket /{" "}
          {number.format(error.events)} requests
        </Text>
      )}
    </Stack>
  );
}

export function UsagePlot({
  chart,
  label,
  layout,
  render,
  height = 320,
  showErrors = true,
}: UsagePlotProps) {
  const geometry = useMemo(() => usageGeometry(chart, render), [chart, render]);
  const reducedMotion = useReducedMotion();
  const [selected, setSelected] = useState<string | null>(null);
  const maximum =
    (layout === "stack" ? geometry?.stackMax : geometry?.overlayMax) ?? 1;
  const animate =
    !reducedMotion &&
    usageRenderPoints(chart, render) <=
      usageRenderLimits.animatedPoints[render];
  const frame = useUsageMotion(geometry, layout, maximum, animate);
  const data = useMemo(
    () =>
      geometry === null
        ? []
        : chart.axis.map((at, index) => ({
            at: bucketPosition(chart, at),
            index,
          })),
    [chart, geometry],
  );
  if (geometry === null)
    return (
      <Alert color="orange">
        Too many chart points. Narrow the range or grouping
        {(render === "bar" || render === "mixed") &&
        usageRenderFits(chart, "line")
          ? ", or choose line mode."
          : "."}
      </Alert>
    );
  if (chart.series.length === 0)
    return <Text>No requests in this recorded range.</Text>;
  const selectedIndex = chart.axis.findIndex((at) => String(at) === selected);
  return (
    <Stack gap="xs">
      <Box component="figure" m={0} aria-label={label}>
        <Text component="figcaption" size="sm">
          {label}
        </Text>
        <Box h={height}>
          <ResponsiveContainer
            width="100%"
            height="100%"
            minWidth={0}
            initialDimension={{ width: 800, height }}
          >
            <ComposedChart
              data={data}
              barGap="-100%"
              margin={{ top: 12, right: 16, bottom: 8, left: 8 }}
              accessibilityLayer
            >
              <CartesianGrid
                vertical={false}
                stroke="var(--mantine-color-default-border)"
                strokeDasharray="3 3"
              />
              <XAxis
                type="number"
                dataKey="at"
                domain={[chart.requestedStartUnix, chart.requestedEndUnix]}
                allowDataOverflow
                tickFormatter={(at: number) =>
                  chart.requestedEndUnix - chart.requestedStartUnix >= 86400
                    ? new Date(at * 1000).toLocaleDateString([], {
                        month: "short",
                        day: "numeric",
                        ...(new Date(
                          chart.requestedStartUnix * 1000,
                        ).getFullYear() !==
                        new Date(chart.requestedEndUnix * 1000).getFullYear()
                          ? { year: "numeric" }
                          : {}),
                      })
                    : new Date(at * 1000).toLocaleTimeString([], {
                        hour: "2-digit",
                        minute: "2-digit",
                      })
                }
                minTickGap={40}
              />
              <YAxis
                type="number"
                domain={[0, frame.maximum]}
                allowDataOverflow
                width={64}
                tickFormatter={(value: number) => compact.format(value)}
              />
              <Tooltip
                filterNull={false}
                isAnimationActive={false}
                content={({ active, payload }) => {
                  const index = payload?.[0]?.payload?.index;
                  return active && typeof index === "number" ? (
                    <Box
                      p="sm"
                      bg="var(--mantine-color-body)"
                      style={{
                        border: "1px solid var(--mantine-color-default-border)",
                        maxHeight: 280,
                        overflowY: "auto",
                      }}
                    >
                      <BucketDetails chart={chart} index={index} />
                    </Box>
                  ) : null;
                }}
              />
              {showErrors &&
                chart.errors
                  .filter((mark) => mark.errorEvents > 0)
                  .map((mark) => (
                    <ReferenceLine
                      key={mark.bucketStartUnix}
                      x={bucketPosition(chart, mark.bucketStartUnix)}
                      stroke="var(--mantine-color-red-5)"
                      strokeWidth={1}
                    />
                  ))}
              {geometry.series.map((item) => {
                const value = ({ index }: { index: number }) => {
                  const raw = item.values[index];
                  const range = item.ranges[index];
                  if (raw == null || (frame.stacking > 0 && range == null))
                    return null;
                  const base = (range?.[0] ?? 0) * frame.stacking;
                  return render === "line" ? base + raw : [base, base + raw];
                };
                const props = {
                  dataKey: value,
                  name: item.name,
                  stroke: color(item.id),
                  fill: color(item.id),
                  isAnimationActive: false,
                };
                return render === "line" ? (
                  <Line
                    key={item.id}
                    {...props}
                    type="linear"
                    connectNulls={false}
                    dot={isolatedDot}
                    strokeWidth={2}
                  />
                ) : render === "area" ? (
                  <Area
                    key={item.id}
                    {...props}
                    type="linear"
                    connectNulls={false}
                    dot={isolatedDot}
                    fillOpacity={layout === "stack" ? 0.4 : 0.16}
                    strokeWidth={2}
                  />
                ) : (
                  <Bar
                    key={item.id}
                    {...props}
                    fillOpacity={0.7}
                    barSize={Math.max(
                      1,
                      Math.min(28, 640 / Math.max(chart.axis.length, 1)),
                    )}
                  />
                );
              })}
              {render === "mixed" && (
                <Line
                  dataKey={({ index }: { index: number }) =>
                    chart.bucketTotals[index] ?? null
                  }
                  name="Total"
                  stroke="var(--mantine-color-text)"
                  strokeDasharray="5 3"
                  strokeWidth={2}
                  dot={isolatedDot}
                  connectNulls={false}
                  isAnimationActive={false}
                />
              )}
            </ComposedChart>
          </ResponsiveContainer>
        </Box>
        <Text size="xs" c="dimmed">
          {`${date(chart.requestedStartUnix)} – ${date(chart.requestedEndUnix)}. `}
          Gaps are unknown values.{" "}
          {showErrors &&
            "Red 1px marks show errors within a bucket; incident timing is unavailable."}
        </Text>
      </Box>
      <Text role="status" size="xs" mih={18}>
        {frame.phase}
      </Text>
      <Select
        label="Inspect bucket"
        placeholder="Select a bucket for values"
        value={selectedIndex < 0 ? null : selected}
        onChange={setSelected}
        data={chart.axis.map((at) => ({ value: String(at), label: date(at) }))}
        searchable
        clearable
      />
      {selectedIndex >= 0 && (
        <BucketDetails chart={chart} index={selectedIndex} />
      )}
    </Stack>
  );
}
