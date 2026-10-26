import {
  Alert,
  Button,
  Card,
  Checkbox,
  Group,
  NativeSelect,
  Popover,
  SegmentedControl,
  SimpleGrid,
  Stack,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import { useState } from "react";
import type { UsageBreakdown, UsageTokenPart } from "./domain.ts";
import {
  type ExplorerMetric,
  type ExplorerRange,
  type ExplorerSelection,
  explorerSelectionKey,
  selectExplorer,
  type UsageExplorerState,
} from "./explorer.ts";
import type { UsageLayout, UsageRender } from "./geometry.ts";
import type { UsagePlotData } from "./plot.ts";
import { UsagePlot } from "./UsagePlot.tsx";

export interface UsageExplorerCompleteView {
  readonly asOfUnix: number;
  readonly chart: UsagePlotData;
  readonly formatValue?: (value: number) => string;
  readonly label: string;
  readonly selection: ExplorerSelection;
  readonly summary: {
    readonly errorEvents: number;
    readonly incompleteEvents: number;
    readonly requests: number;
    readonly total: number | null;
  };
}
export type UsageExplorerStatus =
  | { readonly kind: "ready" }
  | {
      readonly kind: "error" | "loading" | "stale" | "unavailable";
      readonly message: string;
    };
export interface UsageExplorerViewProps {
  readonly onChange: (state: UsageExplorerState) => void;
  readonly state: UsageExplorerState;
  readonly status: UsageExplorerStatus;
  readonly view: UsageExplorerCompleteView | null;
}

const dimensions = [
  { value: "none", label: "None" },
  { value: "client", label: "Client" },
  { value: "model", label: "Model" },
  { value: "provider", label: "Provider" },
];
const parts = [
  { value: "total", label: "Total" },
  { value: "input_tokens", label: "In" },
  { value: "output_tokens", label: "Out" },
  { value: "cache_read_tokens", label: "Cache read" },
  { value: "cache_write_tokens", label: "Cache write" },
];
const integer = new Intl.NumberFormat().format;
const date = (unix: number) => new Date(unix * 1000).toLocaleString();

function ExactFilter({
  label,
  onApply,
  onUnknown,
  value,
}: {
  label: string;
  onApply: (value: string | undefined) => void;
  onUnknown?: () => void;
  value: string | null | undefined;
}) {
  const [draft, setDraft] = useState(value ?? "");
  const [opened, setOpened] = useState(false);
  const apply = (next: string | undefined) => {
    setOpened(false);
    onApply(next);
  };
  return (
    <Popover
      opened={opened}
      onChange={setOpened}
      position="bottom-start"
      withArrow
    >
      <Popover.Target>
        <Button
          variant={value === undefined ? "default" : "light"}
          size="xs"
          maw={220}
          onClick={() => setOpened(!opened)}
        >
          <span
            style={{
              overflow: "hidden",
              textOverflow: "ellipsis",
              whiteSpace: "nowrap",
            }}
          >
            {label}
            {value !== undefined && `: ${value ?? "Unknown"}`}
          </span>
        </Button>
      </Popover.Target>
      <Popover.Dropdown>
        <form
          onSubmit={(event) => {
            event.preventDefault();
            if (draft.length > 0) apply(draft);
          }}
        >
          <Stack gap="xs">
            <TextInput
              label={`${label} exact ID`}
              value={draft}
              onChange={(event) => setDraft(event.currentTarget.value)}
            />
            <Group>
              <Button type="submit" size="xs" disabled={draft.length === 0}>
                Apply
              </Button>
              <Button
                variant="subtle"
                size="xs"
                onClick={() => apply(undefined)}
              >
                Clear
              </Button>
            </Group>
            {onUnknown && (
              <Button
                size="xs"
                variant="subtle"
                onClick={() => {
                  setOpened(false);
                  onUnknown();
                }}
              >
                Unknown client
              </Button>
            )}
          </Stack>
        </form>
      </Popover.Dropdown>
    </Popover>
  );
}

export function UsageExplorerView({
  onChange,
  state,
  status,
  view,
}: UsageExplorerViewProps) {
  const { selection } = state;
  const choose = (patch: Partial<ExplorerSelection>) =>
    onChange(selectExplorer(state, patch));
  const complete =
    view !== null &&
    explorerSelectionKey(view.selection) === explorerSelectionKey(selection) &&
    (status.kind === "ready" || status.kind === "stale")
      ? view
      : null;
  const bars = state.render === "bar" || state.render === "mixed";
  return (
    <Card withBorder radius="md" p="lg">
      <Stack gap="md">
        <Group justify="space-between">
          <Title order={2}>Usage</Title>
          <Text size="xs" c="dimmed">
            Requests routed through Airlock
          </Text>
        </Group>
        <Group justify="space-between" align="start">
          <SegmentedControl
            aria-label="Metric"
            size="sm"
            value={selection.metric}
            data={[
              { value: "cost", label: "Cost" },
              { value: "tokens", label: "Tokens" },
              { value: "requests", label: "Requests" },
            ]}
            onChange={(metric) => choose({ metric: metric as ExplorerMetric })}
          />
          <SegmentedControl
            aria-label="Time range"
            size="xs"
            value={selection.range}
            data={[
              { value: "24h", label: "24h" },
              { value: "yesterday", label: "Yesterday" },
              { value: "7d", label: "7d" },
              { value: "month", label: "Month" },
              { value: "all", label: "All" },
            ]}
            title="Month means rolling 30 days"
            onChange={(range) => choose({ range: range as ExplorerRange })}
          />
        </Group>
        {selection.metric === "tokens" && (
          <SegmentedControl
            aria-label="Token part"
            size="xs"
            value={selection.part}
            data={parts}
            onChange={(part) => choose({ part: part as UsageTokenPart })}
          />
        )}
        <SimpleGrid cols={{ base: 2, sm: 4 }}>
          <NativeSelect
            label="Stack by"
            value={selection.stackBy}
            data={[
              ...dimensions,
              ...(selection.metric === "tokens" && selection.part === "total"
                ? [{ value: "token", label: "Token type" }]
                : []),
            ]}
            onChange={(event) =>
              choose({ stackBy: event.currentTarget.value as UsageBreakdown })
            }
          />
          <NativeSelect
            label="Split by"
            value={selection.splitBy}
            data={dimensions}
            onChange={(event) =>
              choose({
                splitBy: event.currentTarget
                  .value as ExplorerSelection["splitBy"],
              })
            }
          />
          <NativeSelect
            label="Style"
            value={state.render}
            data={[
              { value: "line", label: "Line" },
              { value: "area", label: "Area" },
              { value: "bar", label: "Bar" },
              { value: "mixed", label: "Bar + total" },
            ]}
            onChange={(event) =>
              onChange({
                ...state,
                render: event.currentTarget.value as UsageRender,
              })
            }
          />
          <NativeSelect
            label="Layout"
            value={state.layout}
            data={[
              { value: "overlay", label: bars ? "Grouped" : "Overlay" },
              { value: "stack", label: "Stack" },
            ]}
            onChange={(event) =>
              onChange({
                ...state,
                layout: event.currentTarget.value as UsageLayout,
              })
            }
          />
        </SimpleGrid>
        <Group justify="space-between">
          <Group gap="xs">
            {(["client", "model", "provider"] as const).map((dimension) => {
              const apply = (value: string | undefined) => {
                const filters = { ...selection.filters };
                if (value === undefined) delete filters[dimension];
                else filters[dimension] = value;
                choose({ filters });
              };
              return (
                <ExactFilter
                  key={`${dimension}:${JSON.stringify(selection.filters[dimension])}`}
                  label={dimension.charAt(0).toUpperCase() + dimension.slice(1)}
                  value={selection.filters[dimension]}
                  onApply={apply}
                  {...(dimension === "client"
                    ? {
                        onUnknown: () =>
                          choose({
                            filters: { ...selection.filters, client: null },
                          }),
                      }
                    : {})}
                />
              );
            })}
          </Group>
          <Checkbox
            label="Errors within buckets"
            checked={state.showErrors}
            onChange={(event) =>
              onChange({ ...state, showErrors: event.currentTarget.checked })
            }
          />
        </Group>
        {status.kind !== "ready" && (
          <Alert
            role="status"
            color={status.kind === "error" ? "red" : "orange"}
          >
            {status.message}
          </Alert>
        )}
        {complete ? (
          <>
            <Text size="xs" c="dimmed">
              {complete.chart.bucketSeconds === 3600
                ? "Hourly"
                : complete.chart.bucketSeconds === 86400
                  ? "Daily"
                  : `${complete.chart.bucketSeconds / 86400}-day buckets`}
              {` · ${date(complete.chart.requestedStartUnix)} – ${date(complete.chart.requestedEndUnix)} · ${Intl.DateTimeFormat().resolvedOptions().timeZone} · as of ${date(complete.asOfUnix)}`}
            </Text>
            <Group grow align="start">
              {[
                [
                  complete.label,
                  complete.summary.total === null
                    ? "Unknown"
                    : (complete.formatValue ?? integer)(complete.summary.total),
                ],
                ["Errors", integer(complete.summary.errorEvents)],
                [
                  "Incomplete usage",
                  integer(complete.summary.incompleteEvents),
                ],
              ].map(([label, value]) => (
                <Stack gap={0} key={label}>
                  <Text size="xs" c="dimmed">
                    {label}
                  </Text>
                  <Text size="xl" fw={600}>
                    {value}
                  </Text>
                </Stack>
              ))}
            </Group>
            <UsagePlot
              chart={complete.chart}
              label={complete.label}
              layout={state.layout}
              render={state.render}
              showErrors={state.showErrors}
              {...(complete.formatValue
                ? { formatValue: complete.formatValue }
                : {})}
            />
            <Text size="xs" c="dimmed">
              {integer(complete.summary.requests)} requests. Unknown token usage
              remains unknown.
            </Text>
          </>
        ) : (
          status.kind === "ready" && (
            <Text role="status">Updating usage selection…</Text>
          )
        )}
      </Stack>
    </Card>
  );
}
