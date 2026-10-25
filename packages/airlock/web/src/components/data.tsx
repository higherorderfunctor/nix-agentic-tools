import {
  Alert,
  Badge,
  Button,
  Card,
  Group,
  Stack,
  Text,
  Title,
} from "@mantine/core";
import { type ReactNode, useState } from "react";
import type { AppRuntime } from "../data/app.ts";
import type { CollectionValue, SubscriptionQuery } from "../data/protocol.ts";
import type { ViewState } from "../data/reducer.ts";
import {
  type SubscriptionResult,
  useVisibleSubscription,
} from "../data/visibility.ts";

export function collectionEntries<T extends CollectionValue>(
  state: ViewState,
  collection: string,
): { readonly key: string; readonly value: T }[] {
  return Array.from(state.entries)
    .filter(([key]) => key.startsWith(`${collection}:`))
    .map(([key, value]) => ({
      key: key.slice(collection.length + 1),
      value: value as T,
    }));
}

export function values<T extends CollectionValue>(
  state: ViewState,
  collection: string,
): T[] {
  return collectionEntries<T>(state, collection).map(({ value }) => value);
}

export function time(unix: number | null): string {
  return unix === null ? "unknown" : new Date(unix * 1000).toLocaleString();
}

export function number(value: number | null): string {
  return value === null ? "unknown" : value.toLocaleString();
}

export function percent(milli: number): string {
  return `${(milli / 1000).toFixed(1)}%`;
}

export function Status({ state }: { readonly state: ViewState }) {
  const metadata = state.meta;
  return (
    <Stack gap="xs">
      <Group>
        <Badge color={state.phase === "live" ? "green" : "orange"}>
          {state.phase}
        </Badge>
        {state.lastServerContactUnix !== null && (
          <Text size="sm">
            Last contact: {time(state.lastServerContactUnix)}
          </Text>
        )}
      </Group>
      {state.phase !== "live" && state.phase !== "idle" && (
        <Alert title="Connection status" color="orange">
          Showing the last recorded data while {state.phase}.{" "}
          {state.gap?.code ?? state.error ?? "Waiting for an update."}
        </Alert>
      )}
      {state.gap !== null && (
        <Alert title="Live data gap" color="red">
          {state.gap.code}; {state.gap.action} required.
        </Alert>
      )}
      {state.error !== null && (
        <Alert title="Query failed" color="red">
          {state.error}
        </Alert>
      )}
      {metadata !== null &&
        (metadata.request_loss_total > 0 ||
          metadata.provider_snapshot_loss_total > 0) && (
          <Alert title="Global observations lost" color="red">
            {number(metadata.request_loss_total)} request events and{" "}
            {number(metadata.provider_snapshot_loss_total)} provider snapshots
            lost. These losses are unattributed.
          </Alert>
        )}
      {metadata !== null && metadata.known_gaps.length > 0 && (
        <details>
          <summary>Known gaps ({metadata.known_gaps.length})</summary>
          <ul>
            {metadata.known_gaps.map((gap) => (
              <li key={gap}>{gap}</li>
            ))}
          </ul>
        </details>
      )}
      {metadata?.truncated && (
        <Alert title="History truncated" color="orange">
          This range omits older observations. Oldest included:{" "}
          {time(metadata.oldest_at_unix)}.
        </Alert>
      )}
    </Stack>
  );
}

export function ConnectionNotice({
  result,
  subject,
}: {
  readonly result: SubscriptionResult;
  readonly subject: string;
}) {
  return result._tag === "Failure" ? (
    <Alert title="Query failed" color="red">
      The {subject} query failed. Check the connection or filters.
    </Alert>
  ) : (
    <Alert title="Connection status" color="orange">
      Waiting for {subject} data.
    </Alert>
  );
}

export function Collapsible({
  title,
  children,
}: {
  readonly title: string;
  readonly children: ReactNode;
}) {
  const [expanded, setExpanded] = useState(true);
  return (
    <Stack>
      <Button
        variant="subtle"
        aria-expanded={expanded}
        onClick={() => setExpanded((value) => !value)}
      >
        {expanded ? `Collapse ${title}` : `Expand ${title}`}
      </Button>
      {expanded && children}
    </Stack>
  );
}

function WidgetBody({
  runtime,
  query,
  title,
  children,
}: {
  readonly runtime: AppRuntime;
  readonly query: SubscriptionQuery;
  readonly title: string;
  readonly children: (state: ViewState) => ReactNode;
}) {
  const subscription = useVisibleSubscription(runtime, query);
  const state =
    subscription.result._tag === "Success" ? subscription.result.value : null;
  return (
    <Card
      ref={subscription.targetRef}
      withBorder
      padding="lg"
      aria-label={title}
    >
      <Stack>
        <Title order={2}>{title}</Title>
        {state === null ? (
          <ConnectionNotice
            result={subscription.result}
            subject={title.toLowerCase()}
          />
        ) : (
          <>
            <Status state={state} />
            {children(state)}
          </>
        )}
      </Stack>
    </Card>
  );
}

export function Widget(props: {
  readonly runtime: AppRuntime;
  readonly query: SubscriptionQuery;
  readonly title: string;
  readonly children: (state: ViewState) => ReactNode;
}) {
  return (
    <Collapsible title={props.title}>
      <WidgetBody {...props} />
    </Collapsible>
  );
}
