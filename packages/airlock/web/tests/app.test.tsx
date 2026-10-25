import { RegistryProvider, useAtomValue } from "@effect/atom-react";
import { render, screen, waitFor } from "@testing-library/react";
import { type ReactNode, StrictMode } from "react";
import { describe, expect, it } from "vitest";
import {
  type AppRuntime,
  fixtureAppRuntime,
  makeAppRuntime,
} from "../src/data/app.ts";
import type { SubscriptionQuery } from "../src/data/protocol.ts";
import {
  type ControlEndpoint,
  MemorySocket,
  makeMemoryDataLayer,
} from "../src/data/services.ts";

const endpoint: ControlEndpoint = {
  url: "ws://127.0.0.1/test",
  token: "fake-token",
  resumeSession: null,
};

const query: SubscriptionQuery = { kind: "usage.overview" };

function Frame({ children }: { readonly children: ReactNode }) {
  return (
    <StrictMode>
      <RegistryProvider>{children}</RegistryProvider>
    </StrictMode>
  );
}

function Probe({ result }: { readonly result: unknown }) {
  const value = result as { _tag: string; value?: { phase: string } };
  const phase = value._tag === "Success" ? value.value?.phase : value._tag;
  return <div data-testid="phase">{phase}</div>;
}

function Live({
  query,
  runtime,
}: {
  readonly query: SubscriptionQuery;
  readonly runtime: AppRuntime;
}) {
  return <Probe result={useAtomValue(runtime.subscriptionAtom(query))} />;
}

describe("app runtime", () => {
  it("memoizes identical query atoms", () => {
    const sockets = [new MemorySocket()];
    const socket = sockets[0];
    if (socket === undefined) throw new Error("test socket is missing");
    const runtime = makeAppRuntime(makeMemoryDataLayer(endpoint, () => socket));
    expect(runtime.subscriptionAtom(query)).toBe(
      runtime.subscriptionAtom(query),
    );
    expect(runtime.subscriptionAtom({ ...query, provider: "claude" })).toBe(
      runtime.subscriptionAtom({ provider: "claude", kind: "usage.overview" }),
    );
    const bounded = fixtureAppRuntime(endpoint);
    const atoms = Array.from({ length: 9 }, (_, index) =>
      bounded.subscriptionAtom({ ...query, credential: `credential-${index}` }),
    );
    expect(new Set(atoms).size).toBe(9);
    expect(
      bounded.subscriptionAtom({ ...query, credential: "credential-8" }),
    ).toBe(atoms[8]);
  });

  it("mounts and StrictMode-cleans the live atom subscription", async () => {
    const sockets = [new MemorySocket(), new MemorySocket()];
    let opened = 0;
    const runtime = makeAppRuntime(
      makeMemoryDataLayer(
        endpoint,
        () => sockets[opened++] ?? new MemorySocket(),
      ),
    );
    const view = render(
      <Frame>
        <Live query={query} runtime={runtime} />
      </Frame>,
    );
    const active = await waitFor(() => {
      const open = sockets.find((socket) => !socket.closed);
      expect(
        open?.sent.some((frame) => JSON.parse(frame).type === "subscribe"),
      ).toBe(true);
      return open ?? new MemorySocket();
    });
    expect(active.sent[0] && JSON.parse(active.sent[0])).toMatchObject({
      type: "auth",
    });
    await waitFor(() =>
      expect(screen.getByTestId("phase").textContent).toBe("idle"),
    );
    view.unmount();
    await waitFor(() => {
      expect(active.closed).toBe(true);
      expect(active.messageListenerCount).toBe(0);
      expect(active.closeListenerCount).toBe(0);
    });
  });
});
