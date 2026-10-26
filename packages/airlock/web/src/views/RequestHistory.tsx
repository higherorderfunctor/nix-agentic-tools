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
  ConnectionNotice,
  number,
  Status,
  time,
  values,
} from "../components/data.tsx";
import type { AppRuntime } from "../data/app.ts";
import type {
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
  const [expanded, setExpanded] = useState(false);
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
      <Button
        variant="subtle"
        aria-expanded={expanded}
        onClick={() => setExpanded(!expanded)}
      >
        {expanded
          ? "Collapse raw request details"
          : "Expand raw request details"}
      </Button>
      {expanded && (
        <Stack>
          <Card withBorder>
            <Title order={2}>Raw-table filters and live tail</Title>
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
            <LiveTable
              runtime={runtime}
              query={tableQuery}
              onState={setLastGood}
              onOlder={onOlder}
              onNewer={onNewer}
              hasPrevious={cursors.length > 0}
            />
          )}
        </Stack>
      )}
    </Stack>
  );
}
