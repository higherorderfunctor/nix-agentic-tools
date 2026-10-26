import { LineChart } from "@mantine/charts";
import {
  Alert,
  Button,
  Card,
  Group,
  Select,
  Stack,
  Table,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import { useEffect, useMemo, useState } from "react";
import {
  Collapsible,
  ConnectionNotice,
  collectionEntries,
  number,
  Status,
  time,
  values,
} from "../components/data.tsx";
import type { AppRuntime } from "../data/app.ts";
import type {
  Aggregate,
  RequestRow,
  SubscriptionQuery,
  Window,
} from "../data/protocol.ts";
import type { ViewState } from "../data/reducer.ts";
import { useVisibleSubscription } from "../data/visibility.ts";

type Filters = {
  client?: string;
  group?: string;
  credential?: string;
  provider?: string;
  model?: string;
  outcome?: "cancelled" | "completed" | "failed" | "rejected";
};
const fields = ["client", "group", "credential", "provider", "model"] as const;

export function aggregateStats(rows: readonly Aggregate[]) {
  const events = rows.reduce((total, row) => total + row.events, 0);
  const incompleteEvents = rows.reduce(
    (total, row) => total + row.events - row.complete_events,
    0,
  );
  const latency = rows.reduce((total, row) => total + row.latency_ms, 0);
  const tokens = (field: "input_tokens" | "output_tokens") =>
    rows.some((row) => row[field] === null)
      ? null
      : rows.reduce((total, row) => total + (row[field] ?? 0), 0);
  return {
    events,
    incompleteEvents,
    latency,
    meanLatency: events === 0 ? null : latency / events,
    inputTokens: tokens("input_tokens"),
    outputTokens: tokens("output_tokens"),
  };
}

export function requestChartData(
  rows: readonly Aggregate[],
  bucketSeconds = 60,
) {
  const buckets = new Map<
    number,
    {
      at: number;
      count: number | null;
      input: number | null;
      output: number | null;
      latency: number;
      events: number;
    }
  >();
  for (const row of rows) {
    const bucket = buckets.get(row.bucket_start_unix) ?? {
      at: row.bucket_start_unix,
      count: 0,
      input: 0,
      output: 0,
      latency: 0,
      events: 0,
    };
    bucket.count = (bucket.count ?? 0) + row.events;
    bucket.input =
      bucket.input === null || row.input_tokens === null
        ? null
        : bucket.input + row.input_tokens;
    bucket.output =
      bucket.output === null || row.output_tokens === null
        ? null
        : bucket.output + row.output_tokens;
    bucket.latency += row.latency_ms;
    bucket.events += row.events;
    buckets.set(row.bucket_start_unix, bucket);
  }
  const sorted = [...buckets.values()].sort(
    (left, right) => left.at - right.at,
  );
  const points: {
    at: number;
    count: number | null;
    input: number | null;
    output: number | null;
    mean: number | null;
  }[] = [];
  for (const bucket of sorted) {
    const previous = points.at(-1);
    if (previous !== undefined && bucket.at - previous.at > bucketSeconds)
      points.push({
        at: previous.at + bucketSeconds,
        count: null,
        input: null,
        output: null,
        mean: null,
      });
    points.push({
      at: bucket.at,
      count: bucket.count,
      input: bucket.input,
      output: bucket.output,
      mean: bucket.events === 0 ? null : bucket.latency / bucket.events,
    });
  }
  return points;
}

export function RequestTrend({
  rows,
  includeDuration = true,
}: {
  readonly rows: readonly Aggregate[];
  readonly includeDuration?: boolean;
}) {
  const data = requestChartData(rows);
  const charts = [
    {
      label: "Request count over time",
      series: [{ name: "count", color: "blue.6" }],
    },
    {
      label: "Token usage over time",
      series: [
        { name: "input", color: "teal.6" },
        { name: "output", color: "orange.6" },
      ],
    },
    ...(includeDuration
      ? [
          {
            label: "Mean duration over time (ms)",
            series: [{ name: "mean", color: "violet.6" }],
          },
        ]
      : []),
  ];
  return charts.map((chart) => (
    <figure key={chart.label} aria-label={chart.label}>
      <figcaption>{chart.label}</figcaption>
      <LineChart
        h={180}
        data={data}
        dataKey="at"
        series={chart.series}
        connectNulls={false}
        withLegend={chart.series.length > 1}
      />
    </figure>
  ));
}

function RequestTable({
  state,
  onOlder,
  onNewer,
  hasPrevious,
}: {
  readonly state: ViewState;
  readonly onOlder: (cursor: string, window: Window) => void;
  readonly onNewer: () => void;
  readonly hasPrevious: boolean;
}) {
  const rows = values<RequestRow>(state, "requests").sort((left, right) =>
    right.occurred_at_unix !== left.occurred_at_unix
      ? right.occurred_at_unix - left.occurred_at_unix
      : BigInt(right.id) > BigInt(left.id)
        ? 1
        : BigInt(right.id) < BigInt(left.id)
          ? -1
          : 0,
  );
  return (
    <Stack>
      <Status state={state} />
      {state.meta?.truncated && (
        <Alert title="History truncated" color="orange">
          Older observations were omitted from this range.
        </Alert>
      )}
      {rows.length === 0 && (
        <Text>
          {state.meta === null
            ? "Waiting for request snapshot."
            : "No requests in this recorded range."}
        </Text>
      )}
      {rows.some((row) => !row.usage_complete) && (
        <Alert title="Incomplete token usage" color="orange">
          At least one request has incomplete usage; unknown tokens are not
          zero.
        </Alert>
      )}
      {rows.length > 0 && (
        <Table.ScrollContainer minWidth={1000}>
          <Table striped>
            <Table.Thead>
              <Table.Tr>
                {[
                  "When",
                  "Client / group",
                  "Provider / served credential",
                  "Model",
                  "Outcome / HTTP",
                  "Duration",
                  "Input / output tokens",
                  "Cache read / write",
                  "Request / response bytes",
                ].map((name) => (
                  <Table.Th key={name}>{name}</Table.Th>
                ))}
              </Table.Tr>
            </Table.Thead>
            <Table.Tbody>
              {rows.map((row) => (
                <Table.Tr key={row.id}>
                  <Table.Td>{time(row.occurred_at_unix)}</Table.Td>
                  <Table.Td>
                    {row.client ?? "unknown"} / {row.group}
                  </Table.Td>
                  <Table.Td>
                    {row.provider} / {row.credential}
                  </Table.Td>
                  <Table.Td>{row.model}</Table.Td>
                  <Table.Td>
                    {row.outcome} / {row.status_code}
                  </Table.Td>
                  <Table.Td>{number(row.latency_ms)} ms</Table.Td>
                  <Table.Td>
                    {number(row.input_tokens)} / {number(row.output_tokens)}
                    {!row.usage_complete && " · incomplete"}
                  </Table.Td>
                  <Table.Td>
                    {number(row.cache_read_tokens)} /{" "}
                    {number(row.cache_write_tokens)}
                  </Table.Td>
                  <Table.Td>
                    {number(row.request_bytes)} / {number(row.response_bytes)}
                  </Table.Td>
                </Table.Tr>
              ))}
            </Table.Tbody>
          </Table>
        </Table.ScrollContainer>
      )}
      <Group>
        <Button disabled={!hasPrevious} onClick={onNewer}>
          Newer page
        </Button>
        <Button
          disabled={
            !state.meta?.has_more ||
            state.meta?.next_before === null ||
            state.meta?.window === null
          }
          onClick={() => {
            const cursor = state.meta?.next_before;
            const window = state.meta?.window;
            if (cursor && window) onOlder(cursor, window);
          }}
        >
          Older page
        </Button>
      </Group>
    </Stack>
  );
}

function RequestSeries({
  runtime,
  query,
}: {
  readonly runtime: AppRuntime;
  readonly query: Extract<SubscriptionQuery, { kind: "requests.series" }>;
}) {
  const subscription = useVisibleSubscription(runtime, query);
  const state =
    subscription.result._tag === "Success" ? subscription.result.value : null;
  const entries =
    state === null ? [] : collectionEntries<Aggregate>(state, "request_usage");
  const rows = entries.map(({ value }) => value);
  const stats = aggregateStats(rows);
  return (
    <Card ref={subscription.targetRef} withBorder>
      <Stack>
        <Title order={2}>Request counts and tokens</Title>
        {state !== null && <Status state={state} />}
        {rows.length === 0 ? (
          state === null ? (
            <ConnectionNotice
              result={subscription.result}
              subject="request series"
            />
          ) : (
            <Text>
              {state.meta === null
                ? "Waiting for request snapshot."
                : "No requests in this recorded range."}
            </Text>
          )
        ) : (
          <>
            {stats.incompleteEvents > 0 && (
              <Alert title="Incomplete aggregate usage" color="orange">
                {number(stats.incompleteEvents)} of {number(stats.events)}{" "}
                request events have incomplete usage.
              </Alert>
            )}
            <Text>
              {number(stats.events)} requests; {number(stats.inputTokens)} input
              and {number(stats.outputTokens)} output tokens.
            </Text>
            <RequestTrend rows={rows} />
            <Text>
              Total duration {number(stats.latency)} ms; mean duration{" "}
              {stats.meanLatency === null
                ? "unknown"
                : `${stats.meanLatency.toFixed(1)} ms per request`}
              . No percentile or first-token timing is inferred.
            </Text>
            <Table striped>
              <Table.Thead>
                <Table.Tr>
                  <Table.Th>Bucket</Table.Th>
                  <Table.Th>Provider / model</Table.Th>
                  <Table.Th>Requests</Table.Th>
                  <Table.Th>Input / output tokens</Table.Th>
                  <Table.Th>Mean duration</Table.Th>
                </Table.Tr>
              </Table.Thead>
              <Table.Tbody>
                {entries.map(({ key, value: row }) => (
                  <Table.Tr key={key}>
                    <Table.Td>{time(row.bucket_start_unix)}</Table.Td>
                    <Table.Td>
                      {row.provider} / {row.model}
                    </Table.Td>
                    <Table.Td>{number(row.events)}</Table.Td>
                    <Table.Td>
                      {number(row.input_tokens)} / {number(row.output_tokens)}
                    </Table.Td>
                    <Table.Td>
                      {row.events === 0
                        ? "unknown"
                        : `${(row.latency_ms / row.events).toFixed(1)} ms`}
                    </Table.Td>
                  </Table.Tr>
                ))}
              </Table.Tbody>
            </Table>
          </>
        )}
      </Stack>
    </Card>
  );
}

function LiveTable({
  runtime,
  query,
  onState,
  onOlder,
  onNewer,
  hasPrevious,
}: {
  readonly runtime: AppRuntime;
  readonly query: Extract<SubscriptionQuery, { kind: "requests.table" }>;
  readonly onState: (state: ViewState) => void;
  readonly onOlder: (cursor: string, window: Window) => void;
  readonly onNewer: () => void;
  readonly hasPrevious: boolean;
}) {
  const subscription = useVisibleSubscription(runtime, query);
  const state =
    subscription.result._tag === "Success" ? subscription.result.value : null;
  useEffect(() => {
    if (state?.phase === "live") onState(state);
  }, [state, onState]);
  return (
    <Card ref={subscription.targetRef} withBorder>
      <Stack>
        <Title order={2}>Request history</Title>
        {state === null ? (
          <ConnectionNotice result={subscription.result} subject="request" />
        ) : (
          <RequestTable
            state={state}
            onOlder={onOlder}
            onNewer={onNewer}
            hasPrevious={hasPrevious}
          />
        )}
      </Stack>
    </Card>
  );
}

export function RequestHistory({ runtime }: { readonly runtime: AppRuntime }) {
  const [draft, setDraft] = useState<Filters>({});
  const [filters, setFilters] = useState<Filters>({});
  const [paused, setPaused] = useState(false);
  const [lastGood, setLastGood] = useState<ViewState | null>(null);
  const [cursors, setCursors] = useState<string[]>([]);
  const [fixedWindow, setFixedWindow] = useState<Window | null>(null);
  const window = useMemo<Window>(
    () => fixedWindow ?? { last_seconds: 3600 },
    [fixedWindow],
  );
  const before = cursors.at(-1);
  const tableQuery = useMemo(
    () =>
      ({
        kind: "requests.table",
        window,
        limit: 100,
        ...filters,
        ...(before ? { before } : {}),
      }) as const,
    [window, filters, before],
  );
  const seriesQuery = useMemo(
    () =>
      ({
        kind: "requests.series",
        window,
        bucket_seconds: 60,
        ...filters,
      }) as const,
    [window, filters],
  );
  const onOlder = (cursor: string, range: Window) => {
    setFixedWindow(range);
    setCursors((previous) => [...previous, cursor]);
  };
  const onNewer = () => {
    if (cursors.length <= 1) setFixedWindow(null);
    setCursors((previous) => previous.slice(0, -1));
  };
  const togglePause = () => {
    if (paused) {
      setCursors([]);
      setFixedWindow(null);
    }
    setPaused((value) => !value);
  };
  return (
    <Stack>
      <Card withBorder>
        <Title order={2}>Filters and live tail</Title>
        <form
          onSubmit={(event) => {
            event.preventDefault();
            setFilters(
              Object.fromEntries(
                Object.entries(draft).filter(([, value]) => value !== ""),
              ) as Filters,
            );
            setCursors([]);
            setFixedWindow(null);
            setLastGood(null);
          }}
        >
          <Group align="end">
            {fields.map((field) => (
              <TextInput
                key={field}
                label={field}
                value={draft[field] ?? ""}
                onChange={(event) => {
                  const value = event.currentTarget.value;
                  setDraft((previous) => ({ ...previous, [field]: value }));
                }}
              />
            ))}
            <Select
              label="outcome"
              data={["cancelled", "completed", "failed", "rejected"]}
              clearable
              value={draft.outcome ?? null}
              onChange={(value) =>
                setDraft((previous) => {
                  const { outcome: _old, ...rest } = previous;
                  return value === null
                    ? rest
                    : {
                        ...rest,
                        outcome: value as NonNullable<Filters["outcome"]>,
                      };
                })
              }
            />
            <Button type="submit">Apply filters</Button>
            <Button type="button" onClick={togglePause}>
              {paused ? "Resume live tail" : "Pause live tail"}
            </Button>
          </Group>
        </form>
        <Text>
          {fixedWindow !== null && "since_unix" in fixedWindow
            ? `Historical range: ${time(fixedWindow.since_unix)} to ${time(fixedWindow.until_unix)}. Newer returns to the rolling last hour.`
            : "Live range: rolling last hour; older pages freeze the range at the first page boundary."}
        </Text>
      </Card>
      {paused ? (
        <Card withBorder>
          <Title order={2}>Request history · paused</Title>
          {lastGood === null ? (
            <Text>No recorded data before pause.</Text>
          ) : (
            <RequestTable
              state={{ ...lastGood, phase: "paused" }}
              onOlder={onOlder}
              onNewer={onNewer}
              hasPrevious={cursors.length > 0}
            />
          )}
        </Card>
      ) : (
        <Collapsible title="request table">
          <LiveTable
            runtime={runtime}
            query={tableQuery}
            onState={setLastGood}
            onOlder={onOlder}
            onNewer={onNewer}
            hasPrevious={cursors.length > 0}
          />
        </Collapsible>
      )}
      {!paused && (
        <Collapsible title="request charts">
          <RequestSeries runtime={runtime} query={seriesQuery} />
        </Collapsible>
      )}
    </Stack>
  );
}
