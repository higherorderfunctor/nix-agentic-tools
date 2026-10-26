import { Alert, Card, Stack, Text, Title } from "@mantine/core";
import { number, time } from "../components/data.tsx";
import type { Credential, Credit, Snapshot } from "../data/protocol.ts";

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

export function CredentialObservations({
  credentials,
}: {
  readonly credentials: readonly Credential[];
}) {
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
    <Stack>
      <Card withBorder>
        <Stack>
          <Title order={2}>OAuth subscription credits and limits</Title>

          <Text>These pools are separate from Claude Console API credit.</Text>
          {snapshots.length === 0 && (
            <Text>OAuth subscription usage: not collected.</Text>
          )}
          {snapshots.map((snapshot) => (
            <Stack
              key={JSON.stringify([
                snapshot.provider,
                snapshot.credential,
                snapshot.fetched_at_unix,
              ])}
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
                  {snapshot.provider}/{snapshot.credential}:{" "}
                  {snapshot.gap_reason}
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
                    {snapshot.account_id ?? "unknown"}: {metric.label}{" "}
                    unavailable
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
            <Text key={JSON.stringify([provider, credential, credit.label])}>
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
      <Card withBorder>
        <Stack>
          <Title order={2}>Claude Console grant and spend</Title>
          <Alert title="Console balance unavailable" color="orange">
            console_balance_requires_ant_auth_login
          </Alert>
          <Text>
            Console balance, per-key cost and current grant expiry are
            unavailable.
          </Text>
        </Stack>
      </Card>
    </Stack>
  );
}
