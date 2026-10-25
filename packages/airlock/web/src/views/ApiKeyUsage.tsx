import { Alert, Card, Select, Stack, Table, Text, Title } from "@mantine/core";
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
  Aggregate,
  Credential,
  Credit,
  Snapshot,
  SubscriptionQuery,
} from "../data/protocol.ts";
import { useVisibleSubscription } from "../data/visibility.ts";
import { aggregateStats, RequestTrend } from "./RequestHistory.tsx";

type CreditObservation = {
  readonly credit: Credit;
  readonly credential: string;
  readonly provider: string;
};

function NamedCredit({
  name,
  credits,
}: {
  readonly name: string;
  readonly credits: readonly CreditObservation[];
}) {
  return credits.some(
    (item) => item.credit.label.toLowerCase() === name.toLowerCase(),
  ) ? null : (
    <Text>{name}: not collected or not authoritatively mapped.</Text>
  );
}

function OAuthCredits({
  runtime,
  query,
}: {
  readonly runtime: AppRuntime;
  readonly query: Extract<SubscriptionQuery, { kind: "usage.overview" }>;
}) {
  const subscription = useVisibleSubscription(runtime, query);
  const state =
    subscription.result._tag === "Success" ? subscription.result.value : null;
  const credentials =
    state === null ? [] : values<Credential>(state, "credentials");
  const snapshots = credentials
    .filter((item) => item.auth !== "api_key")
    .map((item) => item.latest_fetch)
    .filter((item): item is Snapshot => item !== null);
  const credits = snapshots.flatMap((snapshot) =>
    snapshot.credits.map((credit) => ({
      credit,
      credential: snapshot.credential,
      provider: snapshot.provider,
    })),
  );
  return (
    <Card ref={subscription.targetRef} withBorder>
      <Stack>
        <Title order={2}>OAuth subscription credits and limits</Title>
        {state === null ? (
          <ConnectionNotice
            result={subscription.result}
            subject="OAuth credits"
          />
        ) : (
          <Status state={state} />
        )}
        <Text>These pools are separate from Claude Console API credit.</Text>
        {snapshots.length === 0 && (
          <Text>OAuth subscription usage: not collected.</Text>
        )}
        {snapshots.map((snapshot) => (
          <Stack
            key={`${snapshot.credential}-${snapshot.fetched_at_unix}`}
            gap="xs"
          >
            <Text>
              {snapshot.provider}/{snapshot.credential} · account{" "}
              {snapshot.account_id ?? "unknown"} · {snapshot.source} ·{" "}
              {snapshot.surface} · fetched {time(snapshot.fetched_at_unix)} ·{" "}
              {snapshot.status}
            </Text>
            {snapshot.gap_reason !== null && (
              <Alert title="OAuth fetch gap" color="red">
                {snapshot.provider}/{snapshot.credential}: {snapshot.gap_reason}
              </Alert>
            )}
            {snapshot.partial_gaps.map((gap) => (
              <Alert key={gap} title="Incomplete OAuth quota" color="orange">
                {snapshot.provider}/{snapshot.credential}: {gap}
              </Alert>
            ))}
            {snapshot.metrics.map((metric) =>
              metric.unit === "gap" ? (
                <Alert
                  key={metric.label}
                  title="OAuth metric gap"
                  color="orange"
                >
                  {snapshot.provider}/{snapshot.credential} · account{" "}
                  {snapshot.account_id ?? "unknown"}: {metric.label} unavailable
                </Alert>
              ) : (
                <Text key={metric.label}>
                  {snapshot.provider}/{snapshot.credential} · account{" "}
                  {snapshot.account_id ?? "unknown"} · {metric.label}:{" "}
                  {number(metric.value)} {metric.unit}
                </Text>
              ),
            )}
          </Stack>
        ))}
        {credits.map(({ credit, credential, provider }) => (
          <Text key={`${provider}:${credential}:${credit.label}`}>
            {provider}/{credential} · {credit.label}:{" "}
            {number(credit.remaining_minor_units)} remaining minor units;
            expiry/reset {time(credit.reset_at_unix)}
          </Text>
        ))}
        <NamedCredit name="Promo" credits={credits} />
        <NamedCredit name="Purchased" credits={credits} />
        <Text>
          Fable sub-limit: not collected or not authoritatively mapped.
        </Text>
        <Text>
          Granted early resets and their expiry: not collected or not
          authoritatively mapped.
        </Text>
        <Text>
          Spending past plan limits: unavailable as a global status.
          Account-specific metrics above:{" "}
          {snapshots
            .filter((snapshot) => snapshot.metrics.length > 0)
            .map(
              (snapshot) =>
                `${snapshot.provider}/${snapshot.credential} (account ${snapshot.account_id ?? "unknown"})`,
            )
            .join(", ") || "none"}
          .
        </Text>
      </Stack>
    </Card>
  );
}

export function ApiKeyUsage({ runtime }: { readonly runtime: AppRuntime }) {
  const overviewQuery = useMemo(
    () => ({ kind: "usage.overview" }) as const,
    [],
  );
  const overview = useVisibleSubscription(runtime, overviewQuery);
  const state =
    overview.result._tag === "Success" ? overview.result.value : null;
  const keys =
    state === null
      ? []
      : collectionEntries<Credential>(state, "credentials").filter(
          ({ value }) => value.auth === "api_key",
        );
  const [selected, setSelected] = useState<string | null>(null);
  const key = keys.find((item) => item.key === selected) ?? keys[0];
  const query = useMemo(
    () =>
      key
        ? ({
            kind: "requests.series",
            window: { last_seconds: 3600 },
            bucket_seconds: 60,
            credential: key.value.credential,
            provider: key.value.provider,
          } as const)
        : null,
    [key],
  );
  return (
    <Stack>
      <Card ref={overview.targetRef} withBorder>
        <Stack>
          <Title order={2}>API-key usage and credits</Title>
          {state === null ? (
            <ConnectionNotice
              result={overview.result}
              subject="API-key selection"
            />
          ) : (
            <Status state={state} />
          )}
          <Select
            label="Routed API key"
            data={keys.map((item) => ({
              value: item.key,
              label: `${item.value.provider} · ${item.value.credential}`,
            }))}
            value={key?.key ?? null}
            onChange={setSelected}
          />
          <Text>
            Request counts and token usage cover only requests routed through
            Airlock, not whole-account usage. Unknown token dimensions remain
            unknown.
          </Text>
          {state !== null && state.meta !== null && keys.length === 0 && (
            <Text>
              Not routed through Airlock: no API-key credential is available.
            </Text>
          )}
        </Stack>
      </Card>
      {query !== null && (
        <Widget runtime={runtime} query={query} title="Routed request usage">
          {(series) => {
            const entries = collectionEntries<Aggregate>(
              series,
              "request_usage",
            );
            const rows = entries.map(({ value }) => value);
            const stats = aggregateStats(rows);
            return rows.length === 0 ? (
              <Text>No requests in this recorded range.</Text>
            ) : (
              <Stack>
                {stats.incompleteEvents > 0 && (
                  <Alert title="Incomplete aggregate usage" color="orange">
                    {number(stats.incompleteEvents)} of {number(stats.events)}{" "}
                    routed request events have incomplete usage.
                  </Alert>
                )}
                <Text>
                  {number(stats.events)} routed requests;{" "}
                  {number(stats.inputTokens)} input tokens;{" "}
                  {number(stats.outputTokens)} output tokens.
                </Text>
                <RequestTrend rows={rows} includeDuration={false} />
                <Table>
                  <Table.Thead>
                    <Table.Tr>
                      <Table.Th>Bucket</Table.Th>
                      <Table.Th>Requests</Table.Th>
                      <Table.Th>Input</Table.Th>
                      <Table.Th>Output</Table.Th>
                    </Table.Tr>
                  </Table.Thead>
                  <Table.Tbody>
                    {entries.map(({ key, value: row }) => (
                      <Table.Tr key={key}>
                        <Table.Td>{time(row.bucket_start_unix)}</Table.Td>
                        <Table.Td>{number(row.events)}</Table.Td>
                        <Table.Td>{number(row.input_tokens)}</Table.Td>
                        <Table.Td>{number(row.output_tokens)}</Table.Td>
                      </Table.Tr>
                    ))}
                  </Table.Tbody>
                </Table>
              </Stack>
            );
          }}
        </Widget>
      )}
      <Card withBorder>
        <Stack>
          <Title order={2}>Claude Console grant and spend</Title>
          <Alert title="Console balance unavailable" color="orange">
            console_balance_requires_ant_auth_login
          </Alert>
          <Text>
            Console balance and per-key cost are unavailable. The operator
            observed an expiry of 2026-10-30 on 2026-10-25. Current grant expiry
            is unavailable.
          </Text>
        </Stack>
      </Card>
      <OAuthCredits runtime={runtime} query={overviewQuery} />
    </Stack>
  );
}
