import { LineChart } from "@mantine/charts";
import {
  Alert,
  Card,
  NativeSelect,
  Select,
  Stack,
  Table,
  Text,
  Title,
} from "@mantine/core";
import { useMemo, useState } from "react";
import {
  ConnectionNotice,
  collectionEntries,
  number,
  Status,
  time,
  values,
  Widget,
} from "../components/data.tsx";
import type { AppRuntime } from "../data/app.ts";
import type {
  ClaudeLimit,
  Credential,
  ResetEvent,
  Snapshot,
} from "../data/protocol.ts";
import { useVisibleSubscription } from "../data/visibility.ts";

type Observation = {
  readonly key: string;
  readonly at: number;
  readonly value: number | null;
  readonly gap: string | null;
  readonly status?: string;
};

export function chartPoints(
  observations: readonly Observation[],
  maxIntervalSeconds = 900,
) {
  const sorted = [...observations].sort(
    (left, right) => left.at - right.at || left.key.localeCompare(right.key),
  );
  const points: { key: string; at: number; value: number | null }[] = [];
  let previous: Observation | null = null;
  for (const item of sorted) {
    if (previous !== null && item.at - previous.at > maxIntervalSeconds) {
      points.push({
        key: `gap:${previous.key}:${item.key}`,
        at: previous.at + maxIntervalSeconds,
        value: null,
      });
    }
    points.push({
      key: item.key,
      at: item.at,
      value: item.gap === null ? item.value : null,
    });
    previous = item;
  }
  return points;
}

function Graph({
  observations,
  label,
  unit,
}: {
  readonly observations: readonly Observation[];
  readonly label: string;
  readonly unit: string;
}) {
  const valid = observations.some(
    (point) => point.value !== null && point.gap === null,
  );
  return (
    <Stack gap="xs">
      <Text fw={600}>
        {label} ({unit})
      </Text>
      {valid ? (
        <figure
          aria-label={`${label} observations with interrupted lines at gaps`}
        >
          <LineChart
            h={180}
            data={chartPoints(observations)}
            dataKey="at"
            series={[{ name: "value", color: "blue.6" }]}
            connectNulls={false}
          />
        </figure>
      ) : (
        <Text>No measured values for {label}; recorded gaps follow.</Text>
      )}
      <Table striped>
        <Table.Thead>
          <Table.Tr>
            <Table.Th>Observed</Table.Th>
            <Table.Th>Value</Table.Th>
            <Table.Th>Coverage</Table.Th>
          </Table.Tr>
        </Table.Thead>
        <Table.Tbody>
          {observations.map((point) => (
            <Table.Tr key={point.key}>
              <Table.Td>{time(point.at)}</Table.Td>
              <Table.Td>{number(point.value)}</Table.Td>
              <Table.Td>
                {point.gap ?? `observed (${point.status ?? "status unknown"})`}
              </Table.Td>
            </Table.Tr>
          ))}
        </Table.Tbody>
      </Table>
    </Stack>
  );
}

function limitKey(limit: ClaudeLimit): string {
  return JSON.stringify([
    limit.kind,
    limit.group,
    limit.scope.model_display_name,
    limit.scope.surface_display_name,
  ]);
}

function limitLabel(key: string): string {
  const [kind, group, model, surface] = JSON.parse(key) as (string | null)[];
  return `scoped limit ${[kind, group, model, surface].filter((part) => part !== null).join(" · ")}`;
}

function HistoryData({
  snapshots,
  resets,
}: {
  readonly snapshots: readonly {
    readonly key: string;
    readonly value: Snapshot;
  }[];
  readonly resets: readonly {
    readonly key: string;
    readonly value: ResetEvent;
  }[];
}) {
  const labels = Array.from(
    new Set(
      snapshots.flatMap(({ value: snapshot }) => [
        ...snapshot.pools.map((pool) => `quota:${pool.label}`),
        ...snapshot.credits.map((credit) => `credit:${credit.label}`),
        ...snapshot.header_windows.map((window) => `header:${window.label}`),
        ...snapshot.claude_limits.map((limit) => `scoped:${limitKey(limit)}`),
      ]),
    ),
  ).sort();
  return (
    <Stack>
      {snapshots.length === 0 && <Text>No observations yet.</Text>}
      {snapshots.length > 0 && (
        <Table striped>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Observed</Table.Th>
              <Table.Th>Source</Table.Th>
              <Table.Th>Status</Table.Th>
              <Table.Th>Fetch gap</Table.Th>
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {snapshots.map(({ key, value: snapshot }) => (
              <Table.Tr key={key}>
                <Table.Td>{time(snapshot.fetched_at_unix)}</Table.Td>
                <Table.Td>
                  {snapshot.source} · {snapshot.surface}
                </Table.Td>
                <Table.Td>{snapshot.status}</Table.Td>
                <Table.Td>{snapshot.gap_reason ?? "none"}</Table.Td>
              </Table.Tr>
            ))}
          </Table.Tbody>
        </Table>
      )}
      {snapshots.some(
        ({ value: snapshot }) =>
          snapshot.gap_reason !== null || snapshot.partial_gaps.length > 0,
      ) && (
        <Alert title="Provider collection gaps" color="orange">
          A fetch or quota dimension is incomplete. Chart lines stop at missing
          measurements; older or exhausted measured values remain visible.
        </Alert>
      )}
      {labels.map((label) => {
        const splitAt = label.indexOf(":");
        const kind = label.slice(0, splitAt);
        const name = label.slice(splitAt + 1);
        const observations = snapshots.map(({ key, value: snapshot }) => {
          const value =
            kind === "quota"
              ? snapshot.pools.find((pool) => pool.label === name)?.utilized
              : kind === "credit"
                ? snapshot.credits.find((credit) => credit.label === name)
                    ?.remaining_minor_units
                : kind === "header"
                  ? snapshot.header_windows.find(
                      (window) => window.label === name,
                    )?.utilization_milli
                  : snapshot.claude_limits.find(
                      (limit) => limitKey(limit) === name,
                    )?.percent_milli;
          return {
            key,
            at: snapshot.fetched_at_unix,
            value: value ?? null,
            gap:
              snapshot.gap_reason ??
              (value === undefined ? "missing field" : null),
            status: snapshot.status,
          };
        });
        return (
          <Graph
            key={label}
            observations={observations}
            label={kind === "scoped" ? limitLabel(name) : label}
            unit={kind === "credit" ? "minor units" : "percent milli"}
          />
        );
      })}
      {snapshots.flatMap(({ key, value: snapshot }) =>
        snapshot.metrics.map((metric) =>
          metric.unit === "gap" ? (
            <Alert
              key={`${key}:metric:${metric.label}`}
              title="Metric gap"
              color="orange"
            >
              {time(snapshot.fetched_at_unix)} · {snapshot.source} ·{" "}
              {metric.label}: unavailable
            </Alert>
          ) : (
            <Text key={`${key}:metric:${metric.label}`}>
              {time(snapshot.fetched_at_unix)} · {snapshot.source} ·{" "}
              {metric.label}: {number(metric.value)} {metric.unit}
            </Text>
          ),
        ),
      )}
      <Title order={3}>Reset events observed</Title>
      <Text>
        Reset events are derived from changes between observations; countdown
        reaching zero alone is not a reset.
      </Text>
      {resets.length === 0 ? (
        <Text>No reset events observed.</Text>
      ) : (
        <Table>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Detected</Table.Th>
              <Table.Th>Pool</Table.Th>
              <Table.Th>Kind</Table.Th>
              <Table.Th>Next reset</Table.Th>
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {resets.map(({ key, value: reset }) => (
              <Table.Tr key={key}>
                <Table.Td>{time(reset.detected_at_unix)}</Table.Td>
                <Table.Td>{reset.pool}</Table.Td>
                <Table.Td>{reset.kind}</Table.Td>
                <Table.Td>{time(reset.reset_at_unix)}</Table.Td>
              </Table.Tr>
            ))}
          </Table.Tbody>
        </Table>
      )}
      {snapshots.flatMap(({ key, value: snapshot }) =>
        snapshot.partial_gaps.map((gap) => (
          <Alert
            key={`${key}:gap:${gap}`}
            title="Incomplete provider data"
            color="orange"
          >
            {gap}
          </Alert>
        )),
      )}
    </Stack>
  );
}

export function ProviderHistory({ runtime }: { readonly runtime: AppRuntime }) {
  const overviewQuery = useMemo(
    () => ({ kind: "usage.overview" }) as const,
    [],
  );
  const overview = useVisibleSubscription(runtime, overviewQuery);
  const overviewState =
    overview.result._tag === "Success" ? overview.result.value : null;
  const credentials =
    overviewState === null
      ? []
      : values<Credential>(overviewState, "credentials");
  const [selected, setSelected] = useState<string | null>(null);
  const [sourceChoice, setSourceChoice] = useState("out_of_band_fetch");
  const current =
    credentials.find(
      (item) => `${item.provider}:${item.credential}` === selected,
    ) ?? credentials[0];
  const snapshot =
    sourceChoice === "response_headers"
      ? current?.latest_header
      : current?.latest_fetch;
  const asOfUnix = overviewState?.meta?.as_of_unix ?? null;
  const resetTimes =
    snapshot === null || snapshot === undefined
      ? []
      : [
          ...snapshot.pools.map((pool) => pool.reset_at_unix),
          ...snapshot.credits.map((credit) => credit.reset_at_unix),
          ...snapshot.header_windows.map((window) => window.reset_at_unix),
          ...snapshot.claude_limits.map((limit) => limit.reset_at_unix),
        ].filter((value): value is number => value !== null);
  const futureReset =
    asOfUnix === null
      ? null
      : (resetTimes
          .filter((value) => value > asOfUnix)
          .sort((left, right) => left - right)[0] ?? null);
  const elapsedReset =
    asOfUnix !== null && resetTimes.some((value) => value <= asOfUnix);
  const query = useMemo(
    () =>
      current && snapshot
        ? ({
            kind: "usage.series",
            provider: current.provider,
            credential: current.credential,
            source: snapshot.source,
            surface: snapshot.surface,
            window: { last_seconds: 86_400 },
            limit: 1000,
          } as const)
        : null,
    [current, snapshot],
  );
  return (
    <Stack>
      <Card ref={overview.targetRef} withBorder>
        <Title order={2}>Provider history</Title>
        {overviewState === null ? (
          <ConnectionNotice
            result={overview.result}
            subject="provider selection"
          />
        ) : (
          <Status state={overviewState} />
        )}
        <Select
          label="Provider and credential"
          data={credentials.map((item) => ({
            value: `${item.provider}:${item.credential}`,
            label: `${item.provider} · ${item.credential}`,
          }))}
          value={current ? `${current.provider}:${current.credential}` : null}
          onChange={setSelected}
        />
        <NativeSelect
          label="Observation source"
          data={[
            { value: "out_of_band_fetch", label: "Out-of-band usage" },
            {
              value: "response_headers",
              label: "Response header observations",
            },
          ]}
          value={sourceChoice}
          onChange={(event) => setSourceChoice(event.currentTarget.value)}
        />
        {snapshot === null && (
          <Text>Selected source has no observations yet.</Text>
        )}
        {snapshot && (
          <Text>
            Selected {snapshot.surface}; latest {time(snapshot.fetched_at_unix)}
            ; age{" "}
            {asOfUnix === null
              ? "unknown"
              : `${number(Math.max(0, asOfUnix - snapshot.fetched_at_unix))} seconds as of ${time(asOfUnix)}`}
            .
            {futureReset === null
              ? elapsedReset
                ? " Scheduled reset time elapsed; reset due/unknown until a later observation confirms it."
                : " Next reset time unknown."
              : ` Next reset: ${time(futureReset)}; ${number(futureReset - (asOfUnix ?? futureReset))} seconds remaining as of the observation clock. A countdown alone is not a reset.`}
          </Text>
        )}
      </Card>
      {query !== null && (
        <Widget runtime={runtime} query={query} title="Quota and credit series">
          {(state) => (
            <>
              <Text>
                Coverage: {time(state.meta?.window?.since_unix ?? null)} to{" "}
                {time(state.meta?.window?.until_unix ?? null)}; oldest returned{" "}
                {time(state.meta?.oldest_at_unix ?? null)}.
              </Text>
              <HistoryData
                snapshots={collectionEntries<Snapshot>(state, "snapshots")}
                resets={collectionEntries<ResetEvent>(state, "reset_events")}
              />
            </>
          )}
        </Widget>
      )}
      {current?.surface === "claude_subscription" && (
        <Text>
          Fable sub-limit and granted early resets with expiry remain
          unavailable until mapped to an authoritative provider field.
        </Text>
      )}
    </Stack>
  );
}
