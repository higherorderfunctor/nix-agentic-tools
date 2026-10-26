import { Alert, Badge, Card, Group, Stack, Text, Title } from "@mantine/core";
import { useMemo } from "react";
import { number, percent, time, values, Widget } from "../components/data.tsx";
import type { AppRuntime } from "../data/app.ts";
import type { Credential, Credit, Pool, Snapshot } from "../data/protocol.ts";

function SnapshotDetails({ snapshot }: { readonly snapshot: Snapshot }) {
  return (
    <Stack gap="xs">
      <Text size="sm">
        {snapshot.source} · {snapshot.surface} · fetched{" "}
        {time(snapshot.fetched_at_unix)} · {snapshot.status}
      </Text>
      {snapshot.gap_reason !== null && (
        <Alert title="Fetch gap" color="red">
          {snapshot.gap_reason}
        </Alert>
      )}
      {snapshot.partial_gaps.map((gap) => (
        <Alert key={gap} title="Incomplete quota" color="orange">
          {gap}
        </Alert>
      ))}
      {snapshot.pools.map((pool: Pool) => (
        <Text key={pool.label}>
          {pool.label}: {percent(pool.utilized)} used, {number(pool.remaining)}{" "}
          remaining; next reset {time(pool.reset_at_unix)}
        </Text>
      ))}
      {snapshot.header_windows.map((window) => (
        <Text key={window.label}>
          {window.label}: {percent(window.utilization_milli)} used; next reset{" "}
          {time(window.reset_at_unix)}
        </Text>
      ))}
      {snapshot.claude_limits.map((limit) => (
        <Text
          key={`${limit.kind}-${limit.group}-${limit.scope.model_display_name}-${limit.scope.surface_display_name}`}
        >
          {limit.kind} ·{" "}
          {limit.scope.model_display_name ??
            limit.scope.surface_display_name ??
            "scoped limit"}
          : {percent(limit.percent_milli)}; next reset{" "}
          {time(limit.reset_at_unix)}; {limit.is_active ? "active" : "inactive"}
        </Text>
      ))}
      {snapshot.credits.map((credit: Credit) => (
        <Text key={credit.label}>
          {credit.label}: {number(credit.remaining_minor_units)} minor units
          remaining of {number(credit.limit_minor_units)}; expires/resets{" "}
          {time(credit.reset_at_unix)}
        </Text>
      ))}
      {snapshot.metrics.map((metric) =>
        metric.unit === "gap" ? (
          <Alert key={metric.label} title="Unmapped metric" color="orange">
            {metric.label}: not collected
          </Alert>
        ) : (
          <Text key={metric.label}>
            {metric.label}: {number(metric.value)} {metric.unit}
          </Text>
        ),
      )}
      {snapshot.pools.length === 0 && snapshot.header_windows.length === 0 && (
        <Text>No quota observations yet.</Text>
      )}
    </Stack>
  );
}

export function Overview({ runtime }: { readonly runtime: AppRuntime }) {
  const query = useMemo(() => ({ kind: "usage.overview" }) as const, []);
  return (
    <Widget runtime={runtime} query={query} title="Overview">
      {(state) => {
        const credentials = values<Credential>(state, "credentials");
        return (
          <Stack>
            {credentials.length === 0 && (
              <Text>
                {state.meta === null
                  ? "Waiting for provider snapshot."
                  : "No provider observations yet."}
              </Text>
            )}
            {credentials.map((credential) => (
              <Card
                withBorder
                key={`${credential.provider}:${credential.credential}`}
              >
                <Group>
                  <Title order={3}>
                    {credential.provider} · {credential.credential}
                  </Title>
                  <Badge
                    color={credential.status === "fresh" ? "green" : "orange"}
                  >
                    {credential.status}
                  </Badge>
                </Group>
                <Text>
                  {credential.auth} · {credential.surface}
                  {credential.surface === "codex_rate_limits"
                    ? " · usage-only; request count unavailable"
                    : ""}
                </Text>
                {!credential.global_quota_complete && (
                  <Alert title="Incomplete quota" color="orange">
                    Global quota is incomplete. A known session limit does not
                    establish a weekly limit.
                  </Alert>
                )}
                {credential.latest_fetch === null ? (
                  <Text>Out-of-band usage: not collected.</Text>
                ) : (
                  <SnapshotDetails snapshot={credential.latest_fetch} />
                )}
                {credential.latest_header === null ? (
                  <Text>Response headers: no observations yet.</Text>
                ) : (
                  <SnapshotDetails snapshot={credential.latest_header} />
                )}
                {credential.header_age_seconds !== null && (
                  <Text>
                    Header age: {number(credential.header_age_seconds)} seconds
                  </Text>
                )}
              </Card>
            ))}
          </Stack>
        );
      }}
    </Widget>
  );
}
