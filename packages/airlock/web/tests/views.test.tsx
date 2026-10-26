import { RegistryProvider } from "@effect/atom-react";
import { MantineProvider } from "@mantine/core";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import * as AsyncResult from "effect/reactivity/AsyncResult";
import * as Atom from "effect/reactivity/Atom";
import { afterEach, describe, expect, it, vi } from "vitest";
import { time } from "../src/components/data.tsx";
import type { AppRuntime } from "../src/data/app.ts";
import type {
  CollectionValue,
  Credential,
  RequestRow,
  Snapshot,
} from "../src/data/protocol.ts";
import { initialViewState, type ViewState } from "../src/data/reducer.ts";
import { App } from "../src/views/App.tsx";
import { Overview } from "../src/views/Overview.tsx";
import { chartPoints, ProviderHistory } from "../src/views/ProviderHistory.tsx";
import { RequestHistory } from "../src/views/RequestHistory.tsx";

class VisibleObserver implements IntersectionObserver {
  static instances: VisibleObserver[] = [];
  target: Element | null = null;
  readonly root = null;
  readonly rootMargin = "";
  readonly thresholds = [];
  readonly callback: IntersectionObserverCallback;
  constructor(callback: IntersectionObserverCallback) {
    this.callback = callback;
    VisibleObserver.instances.push(this);
  }
  observe(target: Element) {
    this.target = target;
    this.set(true);
  }
  set(visible: boolean) {
    if (this.target)
      this.callback(
        [
          {
            isIntersecting: visible,
            target: this.target,
          } as IntersectionObserverEntry,
        ],
        this,
      );
  }
  unobserve() {}
  disconnect() {}
  takeRecords() {
    return [];
  }
}

class BrowserSocket extends EventTarget {
  static instances: BrowserSocket[] = [];
  readyState = 1;
  sent: string[] = [];
  closed = false;
  constructor(_url: string, _protocol: string) {
    super();
    BrowserSocket.instances.push(this);
  }
  send(value: string) {
    this.sent.push(value);
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    this.dispatchEvent(new Event("close"));
  }
}

function frame(children: React.ReactNode) {
  return (
    <MantineProvider>
      <RegistryProvider>{children}</RegistryProvider>
    </MantineProvider>
  );
}
function metadata() {
  return {
    as_of_unix: 1200,
    window: null,
    oldest_at_unix: null,
    has_more: false,
    next_before: null,
    truncated: false,
    known_gaps: ["console_balance_requires_ant_auth_login"],
    request_loss_total: 2,
    provider_snapshot_loss_total: 1,
    reset_events_observed_only: true as const,
    reset_events_complete_since_unix: null,
  };
}
function snapshot(fields: Partial<Snapshot> = {}): Snapshot {
  return {
    account_id: "account",
    credential: "claude",
    provider: "claude",
    client: null,
    group: null,
    gap_reason: null,
    fetched_at_unix: 1000,
    source: "out_of_band_fetch",
    surface: "claude_subscription",
    status: "fresh",
    claude_limits: [],
    credits: [
      {
        label: "wattle_ember",
        limit_minor_units: 20000,
        remaining_minor_units: 6800,
        used_minor_units: 13200,
        reset_at_unix: null,
      },
    ],
    header_windows: [],
    metrics: [],
    pools: [
      {
        label: "five_hour",
        limit: 100000,
        remaining: 30000,
        utilized: 70000,
        unit: "percent_milli",
        reset_at_unix: 1800,
      },
    ],
    partial_gaps: ["seven_day_unavailable"],
    ...fields,
  };
}
function credential(fields: Partial<Credential> = {}): Credential {
  return {
    account_id: "account",
    client: null,
    group: null,
    credential: "claude",
    provider: "claude",
    surface: "claude_subscription",
    auth: "oauth_managed",
    explicit_usage_selection: true,
    global_quota_complete: false,
    header_age_seconds: null,
    latest_fetch: snapshot(),
    latest_header: null,
    status: "fresh",
    routes: [],
    ...fields,
  };
}
function request(fields: Partial<RequestRow> = {}): RequestRow {
  return {
    id: "1",
    occurred_at_unix: 1000,
    client: null,
    group: "g",
    credential: "key",
    provider: "p",
    model: "m",
    outcome: "completed",
    status_code: 200,
    latency_ms: 40,
    request_bytes: 2,
    response_bytes: 3,
    input_tokens: null,
    output_tokens: null,
    cache_read_tokens: null,
    cache_write_tokens: null,
    usage_complete: false,
    ...fields,
  };
}
function state(entries: [string, CollectionValue][]): ViewState {
  return {
    ...initialViewState(),
    phase: "live",
    meta: metadata(),
    entries: new Map(entries),
    lastGoodEntries: new Map(entries),
  };
}
function staticRuntime(view: ViewState): AppRuntime {
  const atom = Atom.make(AsyncResult.success(view));
  return { subscriptionAtom: () => atom };
}

describe("screen contracts", () => {
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
    BrowserSocket.instances = [];
    VisibleObserver.instances = [];
    window.location.hash = "";
  });
  it("breaks the rendered chart data on failed, missing, and temporal gaps", () => {
    expect(
      chartPoints([
        { key: "one", at: 100, value: 40, gap: null },
        { key: "failed", at: 200, value: 50, gap: "fetch_failed" },
        { key: "three", at: 300, value: 30, gap: null },
        { key: "missing", at: 400, value: null, gap: "missing field" },
        { key: "five", at: 500, value: 20, gap: null },
        { key: "later", at: 2000, value: 10, gap: null },
      ]),
    ).toEqual([
      { key: "one", at: 100, value: 40 },
      { key: "failed", at: 200, value: null },
      { key: "three", at: 300, value: 30 },
      { key: "missing", at: 400, value: null },
      { key: "five", at: 500, value: 20 },
      { key: "gap:five:later", at: 1400, value: null },
      { key: "later", at: 2000, value: 10 },
    ]);
  });
  it("preserves measured stale and exhausted values and interrupts actual gaps", () => {
    expect(
      chartPoints([
        { key: "one", at: 100, value: 40, gap: null, status: "exhausted" },
        {
          key: "missing",
          at: 200,
          value: null,
          gap: "missing field",
          status: "stale",
        },
        { key: "three", at: 300, value: 30, gap: null, status: "stale" },
        { key: "later", at: 2000, value: 20, gap: null, status: "unavailable" },
      ]),
    ).toEqual([
      { key: "one", at: 100, value: 40 },
      { key: "missing", at: 200, value: null },
      { key: "three", at: 300, value: 30 },
      { key: "gap:three:later", at: 1200, value: null },
      { key: "later", at: 2000, value: 20 },
    ]);
  });
  it("renders partial quota, Codex usage-only and global losses", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    render(
      frame(
        <Overview
          runtime={staticRuntime(
            state([
              ["credentials:claude", credential()],
              [
                "credentials:codex",
                credential({
                  credential: "codex",
                  provider: "openai-personal",
                  surface: "codex_rate_limits",
                  auth: "oauth_bearer",
                  global_quota_complete: true,
                  latest_fetch: null,
                }),
              ],
            ]),
          )}
        />,
      ),
    );
    expect(await screen.findByText(/seven_day_unavailable/)).toBeTruthy();
    expect(
      screen.getByText(/usage-only; request count unavailable/),
    ).toBeTruthy();
    expect(
      screen.getByText(/2 request events and 1 provider snapshots lost/),
    ).toBeTruthy();
    expect(
      screen.getAllByText(/Response headers: no observations yet/),
    ).toHaveLength(2);
  });
  it("keeps Console unavailable apart from OAuth credits and names missing surfaces", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    render(
      frame(
        <ProviderHistory
          runtime={staticRuntime(
            state([
              ["credentials:claude", credential()],
              [
                "credentials:key",
                credential({
                  credential: "key",
                  provider: "claude-api",
                  auth: "api_key",
                  latest_fetch: null,
                  global_quota_complete: true,
                }),
              ],
            ]),
          )}
        />,
      ),
    );
    expect(
      await screen.findAllByText("console_balance_requires_ant_auth_login"),
    ).toBeTruthy();
    expect(screen.getByText(/wattle_ember:/)).toBeTruthy();
    expect(screen.getByText(/Promo: not collected/)).toBeTruthy();
    expect(screen.getByText(/Purchased: not collected/)).toBeTruthy();
    expect(screen.getByText(/Fable sub-limit: not collected/)).toBeTruthy();
    expect(
      screen.getByText(/Granted early resets and their expiry: not collected/),
    ).toBeTruthy();
  });

  it("shows provider gaps, observed resets, and a graph table equivalent", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    const failed = snapshot({
      fetched_at_unix: 1100,
      status: "unavailable",
      gap_reason: "usage_timeout",
      pools: [],
    });
    const view = state([
      ["credentials:claude", credential()],
      ["snapshots:one", snapshot()],
      ["snapshots:two", failed],
      [
        "reset_events:one",
        {
          credential: "claude",
          pool: "five_hour",
          provider: "claude",
          surface: "claude_subscription",
          detected_at_unix: 1200,
          reset_at_unix: null,
          kind: "utilization_drop",
        },
      ],
    ]);
    render(frame(<ProviderHistory runtime={staticRuntime(view)} />));
    expect(await screen.findAllByText(/usage_timeout/)).toBeTruthy();
    expect(
      screen.getAllByRole("figure", { name: /interrupted lines at gaps/ }),
    ).toBeTruthy();
    expect(screen.getByText("utilization_drop")).toBeTruthy();
    expect(
      screen.getByText(/countdown reaching zero alone is not a reset/),
    ).toBeTruthy();
    fireEvent.change(
      screen.getByRole("combobox", { name: "Observation source" }),
      { target: { value: "response_headers" } },
    );
    expect(
      screen.getByText("Selected source has no observations yet."),
    ).toBeTruthy();
  });
  it("charts measured exhausted quotas, scoped limits and header observations", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    const scoped = {
      kind: "weekly",
      group: "subscription",
      severity: null,
      percent_milli: 40000,
      reset_at_unix: 1300,
      is_active: true,
      scope: { model_display_name: "Fable", surface_display_name: "chat" },
    };
    const exhausted = snapshot({
      status: "exhausted",
      fetched_at_unix: 1000,
      pools: [],
      claude_limits: [scoped],
      metrics: [{ label: "granted_reset", unit: "gap", value: 0 }],
    });
    const stale = snapshot({
      status: "stale",
      fetched_at_unix: 1100,
      pools: [],
      credits: [],
      claude_limits: [scoped],
    });
    render(
      frame(
        <ProviderHistory
          runtime={staticRuntime(
            state([
              [
                "credentials:claude",
                credential({
                  latest_fetch: exhausted,
                  latest_header: snapshot({
                    source: "response_headers",
                    surface: "response_headers",
                    header_windows: [
                      {
                        label: "five_hour",
                        utilization_milli: 25000,
                        reset_at_unix: 1250,
                        status: "allowed",
                      },
                    ],
                    pools: [],
                    credits: [],
                  }),
                }),
              ],
              ["snapshots:one", exhausted],
              ["snapshots:two", stale],
            ]),
          )}
        />,
      ),
    );
    expect(
      await screen.findByRole("figure", {
        name: /scoped limit weekly · subscription · Fable · chat/,
      }),
    ).toBeTruthy();
    expect(
      screen.getAllByText(/observed \(exhausted\)/).length,
    ).toBeGreaterThan(0);
    expect(screen.getAllByText(/observed \(stale\)/).length).toBeGreaterThan(0);
    expect(screen.getByText(/granted_reset: unavailable/)).toBeTruthy();
    expect(
      screen.getByText(
        (_, element) =>
          element?.tagName === "P" &&
          element.textContent?.includes(`Next reset: ${time(1300)}`) === true,
      ),
    ).toBeTruthy();
    expect(screen.getByText(/age 200 seconds as of/)).toBeTruthy();
    expect(
      screen.getByText(/100 seconds remaining as of the observation clock/),
    ).toBeTruthy();
    fireEvent.change(
      screen.getByRole("combobox", { name: "Observation source" }),
      { target: { value: "response_headers" } },
    );
    expect(
      screen.getByText(
        (_, element) =>
          element?.tagName === "P" &&
          element.textContent?.includes(`Next reset: ${time(1250)}`) === true,
      ),
    ).toBeTruthy();
    expect(
      screen.getByText(/50 seconds remaining as of the observation clock/),
    ).toBeTruthy();
  });
  it("does not infer a reset from an elapsed countdown", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    const elapsed = snapshot({
      pools: snapshot().pools.map((pool) => ({ ...pool, reset_at_unix: 1100 })),
    });
    render(
      frame(
        <ProviderHistory
          runtime={staticRuntime(
            state([
              ["credentials:claude", credential({ latest_fetch: elapsed })],
              ["snapshots:one", elapsed],
            ]),
          )}
        />,
      ),
    );
    expect(
      await screen.findByText(
        /Scheduled reset time elapsed; reset due\/unknown until a later observation confirms it/,
      ),
    ).toBeTruthy();
  });
  it("preserves snapshot and reset wire keys through same-second updates", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    const first = snapshot({
      fetched_at_unix: 1000,
      metrics: [{ label: "shared_metric", unit: "percent_milli", value: 5 }],
      partial_gaps: ["shared_gap"],
    });
    const second = snapshot({
      fetched_at_unix: 1000,
      metrics: [{ label: "shared_metric", unit: "percent_milli", value: 5 }],
      partial_gaps: ["shared_gap"],
    });
    const reset = {
      credential: "claude",
      pool: "five_hour",
      provider: "claude",
      surface: "claude_subscription" as const,
      detected_at_unix: 1200,
      reset_at_unix: null,
      kind: "utilization_drop" as const,
    };
    const quotaKey = JSON.stringify([
      "snap-a",
      "snap-b",
      "quota",
      "five_hour",
      "utilization_drop",
    ]);
    const creditKey = JSON.stringify([
      "snap-a",
      "snap-b",
      "credit",
      "five_hour",
      "utilization_drop",
    ]);
    const warning = vi.spyOn(console, "error").mockImplementation(() => {});
    const view = (includeSecond: boolean) =>
      state([
        ["credentials:claude", credential()],
        ["snapshots:snap-a", first],
        ...(includeSecond
          ? [["snapshots:snap-b", second] as [string, CollectionValue]]
          : []),
        [`reset_events:${quotaKey}`, reset],
        ...(includeSecond
          ? [[`reset_events:${creditKey}`, reset] as [string, CollectionValue]]
          : []),
      ]);
    const { rerender } = render(
      frame(<ProviderHistory runtime={staticRuntime(view(true))} />),
    );
    expect(await screen.findAllByText("shared_gap")).toHaveLength(2);
    expect(screen.getAllByText("utilization_drop")).toHaveLength(2);
    const quotaTable = screen
      .getByRole("figure", { name: /quota:five_hour observations/ })
      .parentElement?.querySelector("table");
    expect(quotaTable).not.toBeNull();
    expect(within(quotaTable as HTMLElement).getAllByRole("row")).toHaveLength(
      3,
    );
    rerender(frame(<ProviderHistory runtime={staticRuntime(view(false))} />));
    await waitFor(() =>
      expect(screen.getAllByText("shared_gap")).toHaveLength(1),
    );
    expect(screen.getAllByText("utilization_drop")).toHaveLength(1);
    expect(within(quotaTable as HTMLElement).getAllByRole("row")).toHaveLength(
      2,
    );
    expect(
      warning.mock.calls.some((args) => args.join(" ").includes("same key")),
    ).toBe(false);
    warning.mockRestore();
  });
  it("retains the gap reason when a provider has no measured dimensions", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    const failed = snapshot({
      gap_reason: "fetch_failed",
      status: "unavailable",
      pools: [],
      credits: [],
    });
    render(
      frame(
        <ProviderHistory
          runtime={staticRuntime(
            state([
              ["credentials:claude", credential({ latest_fetch: failed })],
              ["snapshots:failed", failed],
            ]),
          )}
        />,
      ),
    );
    expect(await screen.findAllByText(/fetch_failed/)).toBeTruthy();
    expect(screen.getByText(/Selected claude_subscription/)).toBeTruthy();
  });
  it("shows unknown row tokens, incomplete usage, and truncation", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    const view = {
      ...state([
        [
          "requests:1",
          {
            id: "1",
            occurred_at_unix: 1000,
            client: null,
            group: "g",
            credential: "key",
            provider: "p",
            model: "m",
            outcome: "completed",
            status_code: 200,
            latency_ms: 40,
            request_bytes: 2,
            response_bytes: 3,
            input_tokens: null,
            output_tokens: null,
            cache_read_tokens: null,
            cache_write_tokens: null,
            usage_complete: false,
          },
        ],
      ]),
      meta: {
        ...metadata(),
        truncated: true,
        window: { since_unix: 100, until_unix: 1200 },
      },
    };
    render(frame(<RequestHistory runtime={staticRuntime(view)} />));
    fireEvent.click(
      screen.getByRole("button", { name: "Expand raw request details" }),
    );
    expect(
      await screen.findByText(/At least one request has incomplete usage/),
    ).toBeTruthy();
    expect(screen.getByText(/unknown \/ unknown · incomplete/)).toBeTruthy();
    expect(screen.getAllByText(/History truncated/).length).toBeGreaterThan(0);
    expect(screen.getByText("40 ms")).toBeTruthy();
  });
  it("sorts request rows by occurrence before the numeric id", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    render(
      frame(
        <RequestHistory
          runtime={staticRuntime(
            state([
              [
                "requests:900",
                request({ id: "900", occurred_at_unix: 900, model: "old" }),
              ],
              [
                "requests:2",
                request({ id: "2", occurred_at_unix: 1100, model: "new" }),
              ],
              [
                "requests:3",
                request({
                  id: "3",
                  occurred_at_unix: 1100,
                  model: "newest-id",
                }),
              ],
            ]),
          )}
        />,
      ),
    );
    fireEvent.click(
      screen.getByRole("button", { name: "Expand raw request details" }),
    );
    const table = (await screen.findByText("newest-id")).closest("table");
    expect(table).not.toBeNull();
    expect(
      within(table as HTMLElement)
        .getAllByRole("row")
        .slice(1)
        .map((row) => row.textContent),
    ).toEqual([
      expect.stringContaining("newest-id"),
      expect.stringContaining("new"),
      expect.stringContaining("old"),
    ]);
  });
  it("freezes older-page bounds and applies request filters", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    const view = {
      ...state([]),
      meta: {
        ...metadata(),
        window: { since_unix: 100, until_unix: 1200 },
        has_more: true,
        next_before: "7",
      },
    };
    const queries: unknown[] = [];
    const atom = Atom.make(AsyncResult.success(view));
    const runtime: AppRuntime = {
      subscriptionAtom: (query) => {
        queries.push(query);
        return atom;
      },
    };
    render(frame(<RequestHistory runtime={runtime} />));
    fireEvent.click(
      screen.getByRole("button", { name: "Expand raw request details" }),
    );
    fireEvent.click(await screen.findByRole("button", { name: "Older page" }));
    await waitFor(() =>
      expect(queries).toContainEqual(
        expect.objectContaining({
          kind: "requests.table",
          before: "7",
          window: { since_unix: 100, until_unix: 1200 },
        }),
      ),
    );
    fireEvent.change(screen.getByLabelText("model"), {
      target: { value: "fable" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Apply filters" }));
    await waitFor(() =>
      expect(queries).toContainEqual(
        expect.objectContaining({ kind: "requests.table", model: "fable" }),
      ),
    );
  });
  it("restores the rolling window after paging back or resuming", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    const view = {
      ...state([]),
      meta: {
        ...metadata(),
        window: { since_unix: 100, until_unix: 1200 },
        has_more: true,
        next_before: "7",
      },
    };
    const queries: unknown[] = [];
    const atom = Atom.make(AsyncResult.success(view));
    const runtime: AppRuntime = {
      subscriptionAtom: (query) => {
        queries.push(query);
        return atom;
      },
    };
    render(frame(<RequestHistory runtime={runtime} />));
    fireEvent.click(
      screen.getByRole("button", { name: "Expand raw request details" }),
    );
    fireEvent.click(await screen.findByRole("button", { name: "Older page" }));
    await waitFor(() =>
      expect(queries).toContainEqual(
        expect.objectContaining({ kind: "requests.table", before: "7" }),
      ),
    );
    fireEvent.click(screen.getByRole("button", { name: "Newer page" }));
    await waitFor(() =>
      expect(
        queries
          .filter(
            (query) => (query as { kind: string }).kind === "requests.table",
          )
          .at(-1),
      ).toEqual({
        kind: "requests.table",
        window: { last_seconds: 3600 },
        limit: 100,
      }),
    );
    fireEvent.click(screen.getByRole("button", { name: "Older page" }));
    fireEvent.click(screen.getByRole("button", { name: "Pause live tail" }));
    fireEvent.click(screen.getByRole("button", { name: "Resume live tail" }));
    await waitFor(() =>
      expect(
        queries
          .filter(
            (query) => (query as { kind: string }).kind === "requests.table",
          )
          .at(-1),
      ).toEqual({
        kind: "requests.table",
        window: { last_seconds: 3600 },
        limit: 100,
      }),
    );
    expect(screen.getByText(/Live range: rolling last hour/)).toBeTruthy();
  });
  it("shows OAuth fetch and metric gaps in provider observations", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    const oauth = snapshot({
      gap_reason: "oauth_fetch_failed",
      partial_gaps: ["weekly_scope_missing"],
      metrics: [{ label: "promo_balance", unit: "gap", value: 0 }],
    });
    render(
      frame(
        <ProviderHistory
          runtime={staticRuntime(
            state([
              ["credentials:oauth", credential({ latest_fetch: oauth })],
              [
                "credentials:key",
                credential({
                  credential: "key",
                  auth: "api_key",
                  latest_fetch: null,
                }),
              ],
            ]),
          )}
        />,
      ),
    );
    expect(
      await screen.findByText(/claude\/claude: oauth_fetch_failed/),
    ).toBeTruthy();
    expect(
      screen.getByText(/claude\/claude: weekly_scope_missing/),
    ).toBeTruthy();
    expect(
      screen.getByText(
        /claude\/claude · account account: promo_balance unavailable/,
      ),
    ).toBeTruthy();
    expect(
      screen.getAllByText(/provider snapshots lost/).length,
    ).toBeGreaterThan(0);
  });
  it("selects duplicate credential names by provider for quota observations", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    const view = state([
      ...["p1", "p2"].map(
        (provider) =>
          [
            `credentials:${provider}:same`,
            credential({
              provider,
              credential: "same",
              latest_fetch: snapshot({ provider, credential: "same" }),
            }),
          ] as [string, CollectionValue],
      ),
    ]);
    const queries: unknown[] = [];
    const atom = Atom.make(AsyncResult.success(view));
    const runtime: AppRuntime = {
      subscriptionAtom: (query) => {
        queries.push(query);
        return atom;
      },
    };
    render(frame(<ProviderHistory runtime={runtime} />));
    await waitFor(() =>
      expect(queries).toContainEqual(
        expect.objectContaining({
          kind: "usage.series",
          provider: "p1",
          credential: "same",
        }),
      ),
    );
    fireEvent.click(
      screen.getByRole("combobox", { name: "Provider and credential" }),
    );
    fireEvent.click(await screen.findByText("p2 · same"));
    await waitFor(() =>
      expect(queries).toContainEqual(
        expect.objectContaining({
          kind: "usage.series",
          provider: "p2",
          credential: "same",
        }),
      ),
    );
    expect(
      queries.every(
        (query) =>
          !(
            typeof query === "object" &&
            query !== null &&
            "kind" in query &&
            String(query.kind).startsWith("requests.")
          ),
      ),
    ).toBe(true);
  });
  it("attributes disagreeing OAuth metrics to their accounts", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    render(
      frame(
        <ProviderHistory
          runtime={staticRuntime(
            state([
              [
                "credentials:first",
                credential({
                  account_id: "first-account",
                  credential: "first",
                  latest_fetch: snapshot({
                    account_id: "first-account",
                    credential: "first",
                    metrics: [
                      { label: "spending_enabled", unit: "boolean", value: 1 },
                    ],
                  }),
                }),
              ],
              [
                "credentials:second",
                credential({
                  account_id: "second-account",
                  credential: "second",
                  latest_fetch: snapshot({
                    account_id: "second-account",
                    credential: "second",
                    metrics: [
                      { label: "spending_enabled", unit: "boolean", value: 0 },
                    ],
                  }),
                }),
              ],
            ]),
          )}
        />,
      ),
    );
    expect(
      await screen.findByText(
        /claude\/first · account first-account · spending_enabled: 1 boolean/,
      ),
    ).toBeTruthy();
    expect(
      screen.getByText(
        /claude\/second · account second-account · spending_enabled: 0 boolean/,
      ),
    ).toBeTruthy();
    const unavailable = screen.getByText(/Spending past plan limits:/);
    expect(unavailable.textContent).toContain("unavailable as a global status");
    expect(unavailable.textContent).toContain("claude/first");
    expect(unavailable.textContent).toContain("claude/second");
    expect(unavailable.textContent).not.toContain("enabled (read-only)");
  });
  it("shares one provider overview with credential observations", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    vi.stubGlobal("WebSocket", BrowserSocket);
    window.location.hash = "#providers";
    render(frame(<App />));
    fireEvent.change(screen.getByLabelText(/Airlock read token/), {
      target: { value: "fake-token" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Connect" }));
    const overviewMessages = () =>
      BrowserSocket.instances
        .flatMap((socket) => socket.sent)
        .filter((message) => message.includes('"kind":"usage.overview"'));
    await waitFor(() => expect(overviewMessages()).toHaveLength(1));
    expect(
      screen.getByText("OAuth subscription credits and limits"),
    ).toBeTruthy();
    expect(screen.queryByRole("link", { name: "API-key usage" })).toBeNull();
    expect(
      BrowserSocket.instances
        .flatMap((socket) => socket.sent)
        .every((message) => !message.includes('"kind":"requests.')),
    ).toBe(true);
  });
  it("authenticates once in memory and releases subscriptions on navigation and collapse", async () => {
    vi.stubGlobal("IntersectionObserver", VisibleObserver);
    vi.stubGlobal("WebSocket", BrowserSocket);
    const storage = vi.spyOn(Storage.prototype, "setItem");
    window.location.hash = "#overview";
    render(frame(<App />));
    fireEvent.change(screen.getByLabelText(/Airlock read token/), {
      target: { value: "fake-token" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Connect" }));
    await waitFor(() =>
      expect(
        BrowserSocket.instances.some((socket) =>
          socket.sent.some((message) =>
            message.includes('"kind":"usage.overview"'),
          ),
        ),
      ).toBe(true),
    );
    const overviewObserver = VisibleObserver.instances.find(
      (observer) => observer.target?.getAttribute("aria-label") === "Overview",
    );
    expect(overviewObserver).toBeDefined();
    overviewObserver?.set(false);
    await waitFor(() =>
      expect(
        BrowserSocket.instances.some((socket) =>
          socket.sent.some((message) =>
            message.includes('"type":"unsubscribe","id":"usage-overview'),
          ),
        ),
      ).toBe(true),
    );
    overviewObserver?.set(true);
    await waitFor(() =>
      expect(
        BrowserSocket.instances
          .flatMap((socket) => socket.sent)
          .filter((message) => message.includes('"kind":"usage.overview"'))
          .length,
      ).toBeGreaterThan(1),
    );
    const unsubscribeCount = () =>
      BrowserSocket.instances
        .flatMap((socket) => socket.sent)
        .filter((message) =>
          message.includes('"type":"unsubscribe","id":"usage-overview'),
        ).length;
    const beforeNavigation = unsubscribeCount();
    window.location.hash = "#usage";
    window.dispatchEvent(new Event("hashchange"));
    fireEvent.click(
      await screen.findByRole("button", { name: "Expand raw request details" }),
    );
    await waitFor(() =>
      expect(
        BrowserSocket.instances.some((socket) =>
          socket.sent.some((message) =>
            message.includes('"kind":"requests.table"'),
          ),
        ),
      ).toBe(true),
    );
    await waitFor(() =>
      expect(unsubscribeCount()).toBeGreaterThan(beforeNavigation),
    );
    fireEvent.click(screen.getByRole("button", { name: "Pause live tail" }));
    await waitFor(() =>
      expect(
        BrowserSocket.instances
          .flatMap((socket) => socket.sent)
          .some((message) =>
            message.includes('"type":"unsubscribe","id":"requests-table'),
          ),
      ).toBe(true),
    );
    expect(screen.getByText("No recorded data before pause.")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Resume live tail" }));
    await waitFor(() =>
      expect(
        BrowserSocket.instances
          .flatMap((socket) => socket.sent)
          .filter((message) => message.includes('"kind":"requests.table"'))
          .length,
      ).toBeGreaterThan(1),
    );
    const beforeCollapse = BrowserSocket.instances
      .flatMap((socket) => socket.sent)
      .filter((message) =>
        message.includes('"type":"unsubscribe","id":"requests-table'),
      ).length;
    fireEvent.click(
      screen.getByRole("button", { name: "Collapse raw request details" }),
    );
    await waitFor(() =>
      expect(
        BrowserSocket.instances
          .flatMap((socket) => socket.sent)
          .filter((message) =>
            message.includes('"type":"unsubscribe","id":"requests-table'),
          ).length,
      ).toBeGreaterThan(beforeCollapse),
    );
    const overviewSocket = BrowserSocket.instances.find((socket) =>
      socket.sent.some((message) =>
        message.includes('"kind":"usage.overview"'),
      ),
    );
    expect(overviewSocket).toBeDefined();
    fireEvent.click(screen.getByRole("button", { name: "Disconnect" }));
    await waitFor(() =>
      expect(BrowserSocket.instances.every((socket) => socket.closed)).toBe(
        true,
      ),
    );
    expect(storage).not.toHaveBeenCalled();
    storage.mockRestore();
  });
});
