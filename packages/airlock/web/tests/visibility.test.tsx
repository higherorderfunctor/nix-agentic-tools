import { RegistryProvider } from "@effect/atom-react";
import { render, screen, waitFor } from "@testing-library/react";
import { act, StrictMode, useEffect } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { makeAppRuntime } from "../src/data/app.ts";
import type { SubscriptionQuery } from "../src/data/protocol.ts";
import {
  type ControlEndpoint,
  MemorySocket,
  makeMemoryDataLayer,
} from "../src/data/services.ts";
import { useVisibleSubscription } from "../src/data/visibility.ts";

const endpoint: ControlEndpoint = {
  url: "ws://127.0.0.1/test",
  token: "fake-token",
};
const query: SubscriptionQuery = { kind: "usage.overview" };
const metadata = {
  as_of_unix: 100,
  window: null,
  oldest_at_unix: null,
  has_more: false,
  next_before: null,
  truncated: false,
  known_gaps: [],
  request_loss_total: 0,
  provider_snapshot_loss_total: 0,
  reset_events_observed_only: true as const,
  reset_events_complete_since_unix: null,
};
const subscribed = JSON.stringify({
  v: 1,
  type: "subscribed",
  id: "usage-overview-1",
  epoch: "epoch-a",
  interval_ms: 1000,
});
const snapshot = JSON.stringify({
  v: 1,
  type: "snapshot",
  id: "usage-overview-1",
  epoch: "epoch-a",
  seq: 1,
  collections: {
    credentials: [
      {
        key: JSON.stringify(["provider-a", "credential-a"]),
        value: {
          account_id: null,
          client: null,
          group: null,
          credential: "credential-a",
          provider: "provider-a",
          surface: "surface-a",
          auth: "api_key",
          explicit_usage_selection: false,
          global_quota_complete: false,
          header_age_seconds: null,
          latest_fetch: null,
          latest_header: null,
          status: "fresh",
          routes: [],
        },
      },
    ],
  },
  meta: metadata,
});

class FakeIntersectionObserver {
  static instances: FakeIntersectionObserver[] = [];
  readonly observed: Element[] = [];
  readonly unobserved: Element[] = [];
  disconnected = false;
  readonly callback: IntersectionObserverCallback;

  constructor(callback: IntersectionObserverCallback) {
    this.callback = callback;
    FakeIntersectionObserver.instances.push(this);
  }

  readonly root: Element | Document | null = null;
  readonly rootMargin = "";
  readonly thresholds: readonly number[] = [];

  takeRecords(): IntersectionObserverEntry[] {
    return [];
  }

  observe(element: Element) {
    this.observed.push(element);
  }

  unobserve(element: Element) {
    this.unobserved.push(element);
  }

  disconnect() {
    this.disconnected = true;
  }
}

function View({
  runtime,
  targetElement,
}: {
  readonly runtime: ReturnType<typeof makeAppRuntime>;
  readonly targetElement?: Element | null;
}) {
  const subscription = useVisibleSubscription(runtime, query, {
    debounceMs: 250,
  });
  const phase =
    subscription.result._tag === "Success"
      ? subscription.result.value.phase
      : subscription.result._tag;
  useEffect(() => {
    if (targetElement === undefined) return;
    subscription.targetRef(targetElement);
    return () => subscription.targetRef(null);
  }, [subscription.targetRef, targetElement]);
  return (
    <div
      ref={targetElement === undefined ? subscription.targetRef : undefined}
      data-visible={subscription.visible}
    >
      <span data-testid="phase">{phase}</span>
      <span data-testid="entries">
        {subscription.result._tag === "Success"
          ? subscription.result.value.entries.size
          : 0}
      </span>
    </div>
  );
}

function setDocumentVisibility(visible: boolean) {
  Object.defineProperty(document, "visibilityState", {
    value: visible ? "visible" : "hidden",
    configurable: true,
  });
  document.dispatchEvent(new Event("visibilitychange"));
}

function latestObserver() {
  const observer = FakeIntersectionObserver.instances.at(-1);
  if (observer === undefined) throw new Error("test observer is missing");
  return observer;
}

describe("visible subscriptions", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
    FakeIntersectionObserver.instances = [];
    setDocumentVisibility(true);
  });

  it("waits for known intersection, debounces leaving, and resumes", async () => {
    FakeIntersectionObserver.instances = [];
    vi.stubGlobal("IntersectionObserver", FakeIntersectionObserver);
    const sockets = [new MemorySocket(), new MemorySocket()];
    let opened = 0;
    const runtime = makeAppRuntime(
      makeMemoryDataLayer(
        endpoint,
        () => sockets[opened++] ?? new MemorySocket(),
      ),
    );
    const view = render(
      <StrictMode>
        <RegistryProvider>
          <View runtime={runtime} />
        </RegistryProvider>
      </StrictMode>,
    );
    await act(async () => {
      await Promise.resolve();
    });
    expect(opened).toBe(0);
    expect(screen.getByTestId("phase").textContent).toBe("paused");

    const observer = latestObserver();
    await act(async () => {
      observer.callback(
        [{ isIntersecting: true } as IntersectionObserverEntry],
        observer as unknown as IntersectionObserver,
      );
    });
    const first = await waitFor(() => {
      const active = sockets.find((socket) => !socket.closed);
      expect(
        active?.sent.some((frame) => JSON.parse(frame).type === "subscribe"),
      ).toBe(true);
      return active ?? new MemorySocket();
    });

    vi.useFakeTimers();
    await act(async () => {
      observer.callback([], observer as unknown as IntersectionObserver);
    });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(249);
    });
    expect(first.closed).toBe(false);
    expect(screen.getByTestId("phase").textContent).toBe("idle");
    expect(screen.getByTestId("entries").textContent).toBe("0");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(1);
    });
    vi.useRealTimers();
    await waitFor(() => {
      expect(first.closed).toBe(true);
      expect(screen.getByTestId("phase").textContent).toBe("paused");
      expect(first.messageListenerCount).toBe(0);
    });
    await act(async () => {
      observer.callback(
        [{ isIntersecting: true } as IntersectionObserverEntry],
        observer as unknown as IntersectionObserver,
      );
    });
    const second = await waitFor(() => {
      const active = sockets.find(
        (socket) => !socket.closed && socket !== first,
      );
      expect(
        active?.sent.some((frame) => JSON.parse(frame).type === "subscribe"),
      ).toBe(true);
      return active ?? new MemorySocket();
    });
    expect(second).not.toBe(first);
    view.unmount();
    await waitFor(() => {
      expect(second.closed).toBe(true);
      expect(second.messageListenerCount).toBe(0);
      expect(latestObserver().disconnected).toBe(true);
    });
  });

  it("keeps each widget's last-good data paused across tab and intersection changes", async () => {
    FakeIntersectionObserver.instances = [];
    vi.stubGlobal("IntersectionObserver", FakeIntersectionObserver);
    const sockets = [new MemorySocket(), new MemorySocket()];
    let opened = 0;
    const runtime = makeAppRuntime(
      makeMemoryDataLayer(
        endpoint,
        () => sockets[opened++] ?? new MemorySocket(),
      ),
    );
    const view = render(
      <StrictMode>
        <RegistryProvider>
          <View runtime={runtime} />
        </RegistryProvider>
      </StrictMode>,
    );
    const observer = latestObserver();
    await act(async () => {
      observer.callback(
        [{ isIntersecting: true } as IntersectionObserverEntry],
        observer as unknown as IntersectionObserver,
      );
    });
    const first = await waitFor(() => {
      const active = sockets.find((socket) => !socket.closed);
      expect(
        active?.sent.some((frame) => JSON.parse(frame).type === "subscribe"),
      ).toBe(true);
      return active ?? new MemorySocket();
    });
    first.receive(subscribed);
    first.receive(snapshot);
    await waitFor(() =>
      expect(screen.getByTestId("phase").textContent).toBe("live"),
    );
    expect(screen.getByTestId("entries").textContent).toBe("1");

    await act(async () => setDocumentVisibility(false));
    await waitFor(() => {
      expect(screen.getByTestId("phase").textContent).toBe("paused");
      expect(screen.getByTestId("entries").textContent).toBe("1");
      expect(first.closed).toBe(true);
    });
    await act(async () => {
      observer.callback(
        [{ isIntersecting: true } as IntersectionObserverEntry],
        observer as unknown as IntersectionObserver,
      );
    });
    expect(opened).toBe(1);
    expect(screen.getByTestId("phase").textContent).toBe("paused");

    await act(async () => {
      observer.callback([], observer as unknown as IntersectionObserver);
    });
    await act(async () => setDocumentVisibility(true));
    await act(async () => {
      await Promise.resolve();
    });
    expect(opened).toBe(1);
    expect(screen.getByTestId("phase").textContent).toBe("paused");
    expect(screen.getByTestId("entries").textContent).toBe("1");
    view.unmount();
  });

  it("reobserves when the target element changes", async () => {
    FakeIntersectionObserver.instances = [];
    vi.stubGlobal("IntersectionObserver", FakeIntersectionObserver);
    const sockets = [new MemorySocket(), new MemorySocket()];
    let opened = 0;
    const runtime = makeAppRuntime(
      makeMemoryDataLayer(
        endpoint,
        () => sockets[opened++] ?? new MemorySocket(),
      ),
    );
    const firstElement = document.createElement("div");
    const secondElement = document.createElement("div");
    const view = render(
      <StrictMode>
        <RegistryProvider>
          <View runtime={runtime} targetElement={firstElement} />
        </RegistryProvider>
      </StrictMode>,
    );
    const firstObserver = latestObserver();
    expect(firstObserver.observed).toEqual([firstElement]);
    await act(async () => {
      firstObserver.callback(
        [{ isIntersecting: true } as IntersectionObserverEntry],
        firstObserver as unknown as IntersectionObserver,
      );
    });
    await waitFor(() => expect(opened).toBe(1));

    view.rerender(
      <StrictMode>
        <RegistryProvider>
          <View runtime={runtime} targetElement={secondElement} />
        </RegistryProvider>
      </StrictMode>,
    );
    const secondObserver = latestObserver();
    await waitFor(() => {
      expect(firstObserver.disconnected).toBe(true);
      expect(secondObserver.observed).toEqual([secondElement]);
      expect(screen.getByTestId("phase").textContent).toBe("paused");
      expect(sockets[0]?.closed).toBe(true);
    });
    await act(async () => {
      secondObserver.callback(
        [{ isIntersecting: true } as IntersectionObserverEntry],
        secondObserver as unknown as IntersectionObserver,
      );
    });
    await waitFor(() => expect(opened).toBe(2));
    view.unmount();
  });
});
