import { Effect, Fiber, Layer, Stream } from "effect";
import { describe, expect, it } from "vitest";
import type { SubscriptionQuery } from "../src/data/protocol.ts";
import type { ViewState } from "../src/data/reducer.ts";
import {
  type ControlEndpoint,
  ControlEndpointService,
  ControlSocketFactoryService,
  ControlTransport,
  ControlTransportLayer,
  MemorySocket,
  makeMemoryDataLayer,
  makeMemoryDataLayerWithFactory,
  openBrowserSocket,
  Subscriptions,
} from "../src/data/services.ts";

import { serverFrame } from "./protocol-fixtures.ts";

const endpoint: ControlEndpoint = {
  url: "ws://127.0.0.1/test",
  token: "fake-token",
};

const query: SubscriptionQuery = { kind: "usage.overview" };

const metadata = {
  ...serverFrame("snapshot").meta,
  as_of_unix: 100,
  window: null,
};

const subscribed = JSON.stringify({
  ...serverFrame("subscribed"),
  id: "usage-overview-1",
  epoch: "epoch-a",
});

const snapshot = JSON.stringify({
  ...serverFrame("snapshot"),
  id: "usage-overview-1",
  epoch: "epoch-a",
  collections: { credentials: [] },
  meta: metadata,
});

const hello = JSON.stringify({
  ...serverFrame("hello"),
  server_time_unix: 100,
});

const ping = JSON.stringify({
  ...serverFrame("ping"),
  nonce: "nonce-1",
  server_time_unix: 101,
});

const connectionError = JSON.stringify(serverFrame("error"));

function sentTypes(socket: MemorySocket) {
  return socket.sent.map(
    (frame) => (JSON.parse(frame) as { type: string }).type,
  );
}

describe("subscription service", () => {
  it("authenticates before subscribe and acknowledges only applied frames", async () => {
    const socket = new MemorySocket();
    const program = Effect.gen(function* () {
      const stream = yield* Subscriptions.useSync((service) =>
        service.stream(query),
      );
      const pull = yield* Stream.toPull(stream);
      const [initial] = yield* pull;
      expect(initial?.phase).toBe("idle");
      const subscribedPull = yield* Effect.forkChild(pull);
      yield* Effect.sleep("10 millis");
      socket.receive(subscribed);
      const [subscribedState] = yield* Fiber.join(subscribedPull);
      expect(subscribedState?.phase).toBe("subscribed");
      expect(sentTypes(socket)).toEqual(["auth", "subscribe"]);
      const livePull = yield* Effect.forkChild(pull);
      yield* Effect.sleep("10 millis");
      socket.receive(snapshot);
      const [liveState] = yield* Fiber.join(livePull);
      expect(liveState?.phase).toBe("live");
      expect(sentTypes(socket)).toEqual(["auth", "subscribe", "ack"]);
    });
    await Effect.runPromise(
      Effect.scoped(
        Effect.provide(
          program,
          makeMemoryDataLayer(endpoint, () => socket),
        ),
      ),
    );
    expect(sentTypes(socket)).toEqual(["auth", "subscribe", "ack"]);
    expect(socket.closed).toBe(true);
  });

  it("treats a nonretryable server error as terminal without a second socket", async () => {
    const socket = new MemorySocket();
    let openings = 0;
    const layer = makeMemoryDataLayerWithFactory(
      endpoint,
      {
        open: () =>
          Effect.sync(() => {
            openings += 1;
            return socket.socket;
          }),
      },
      { retryInitialMs: 10_000 },
    );
    const program = Effect.gen(function* () {
      const stream = yield* Subscriptions.useSync((service) =>
        service.stream(query),
      );
      const pull = yield* Stream.toPull(stream);
      yield* pull;
      yield* Effect.sleep("10 millis");
      expect(sentTypes(socket)).toEqual(["auth", "subscribe"]);
      for (const frame of [subscribed, snapshot, connectionError]) {
        const next = yield* Effect.forkChild(pull);
        socket.receive(frame);
        const states = yield* Fiber.join(next);
        expect(states[0]).toBeDefined();
      }
      yield* Effect.sleep("25 millis");
      expect(openings).toBe(1);
      expect(sentTypes(socket)).toEqual([
        "auth",
        "subscribe",
        "ack",
        "unsubscribe",
      ]);
    });
    await Effect.runPromise(Effect.scoped(Effect.provide(program, layer)));
    expect(openings).toBe(1);
    expect(sentTypes(socket)).toEqual([
      "auth",
      "subscribe",
      "ack",
      "unsubscribe",
    ]);
    expect(socket.closed).toBe(true);
    expect(socket.messageListenerCount).toBe(0);
    expect(socket.closeListenerCount).toBe(0);
  });

  it("interrupts socket acquisition before OPEN through Subscriptions", async () => {
    let resumeOpening: (() => void) | undefined;
    let openingCleaned = false;
    const socket = new MemorySocket();
    const layer = makeMemoryDataLayerWithFactory(
      endpoint,
      {
        open: () =>
          Effect.callback((resume) => {
            resumeOpening = () => resume(Effect.succeed(socket.socket));
            return Effect.sync(() => {
              openingCleaned = true;
              socket.close();
            });
          }),
      },
      { retryInitialMs: 10 },
    );
    const fiber = Effect.runFork(
      Effect.scoped(
        Effect.provide(
          Effect.gen(function* () {
            const stream = yield* Subscriptions.useSync((service) =>
              service.stream(query),
            );
            yield* Stream.runDrain(stream);
          }),
          layer,
        ),
      ),
    );
    await Effect.runPromise(Effect.sleep("20 millis"));
    const stopping = Effect.runPromise(Fiber.interrupt(fiber));
    const interrupted = await Promise.race([
      stopping.then(() => true),
      new Promise<false>((resolve) => setTimeout(() => resolve(false), 80)),
    ]);
    resumeOpening?.();
    await stopping;
    expect(interrupted).toBe(true);
    expect(openingCleaned).toBe(true);
    expect(socket.closed).toBe(true);
  });

  it("processes a terminal server gap buffered before ordinary close", async () => {
    const socket = new MemorySocket();
    const terminalGap = JSON.stringify({
      ...serverFrame("gap"),
      id: "usage-overview-1",
      epoch: "epoch-a",
      after_seq: 1,
      code: "slow_consumer",
      retryable: false,
      action: "resnapshot",
    });
    const states: ViewState[] = [];
    const program = Effect.gen(function* () {
      const stream = yield* Subscriptions.useSync((service) =>
        service.stream(query),
      );
      yield* Effect.forkChild(
        Stream.runForEach(stream, (state) =>
          Effect.sync(() => {
            states.push(state);
          }),
        ),
      );
      for (
        let attempt = 0;
        sentTypes(socket).length < 2 && attempt < 100;
        attempt += 1
      )
        yield* Effect.sleep("1 millis");
      socket.receive(subscribed);
      yield* Effect.sleep("5 millis");
      socket.receive(snapshot);
      yield* Effect.sleep("5 millis");
      socket.receive(terminalGap);
      socket.close();
      yield* Effect.sleep("50 millis");
    });
    await Effect.runPromise(
      Effect.scoped(
        Effect.provide(
          program,
          makeMemoryDataLayer(endpoint, () => socket, {
            retryInitialMs: 10_000,
          }),
        ),
      ),
    );
    expect(states.some((state) => state.gap?.code === "slow_consumer")).toBe(
      true,
    );
    expect(states.at(-1)).toMatchObject({
      phase: "reconnecting",
      gap: {
        code: "slow_consumer",
        retryable: false,
        action: "resnapshot",
      },
    });
    expect(socket.closed).toBe(true);
  });

  it.each(["terminal-close", "malformed", "unknown-field"] as const)(
    "stops %s without a second auth or subscribe",
    async (failureKind) => {
      const sockets = [new MemorySocket(), new MemorySocket()];
      let openings = 0;
      const layer = makeMemoryDataLayerWithFactory(
        endpoint,
        {
          open: () =>
            Effect.sync(() => {
              openings += 1;
              const socket = sockets[openings - 1];
              if (socket === undefined) throw new Error("unexpected opening");
              return socket.socket;
            }),
        },
        { retryInitialMs: 1 },
      );
      const states: ViewState[] = [];
      const program = Effect.gen(function* () {
        const stream = yield* Subscriptions.useSync((service) =>
          service.stream(query),
        );
        yield* Effect.forkScoped(
          Stream.runForEach(stream, (state) =>
            Effect.sync(() => {
              states.push(state);
            }),
          ),
        );
        const first = sockets[0];
        if (first === undefined) throw new Error("first socket missing");
        for (
          let attempt = 0;
          (sentTypes(first).length < 2 || first.messageListenerCount < 1) &&
          attempt < 100;
          attempt += 1
        )
          yield* Effect.sleep("1 millis");
        first.receive(subscribed);
        first.receive(snapshot);
        yield* Effect.sleep("5 millis");
        if (failureKind === "terminal-close") {
          first.receive(connectionError);
          first.close();
        } else if (failureKind === "malformed") {
          first.receive("{");
        } else {
          first.receive(JSON.stringify({ ...JSON.parse(snapshot), future: 1 }));
        }
        yield* Effect.sleep("100 millis");
      });
      await Effect.runPromise(Effect.scoped(Effect.provide(program, layer)));
      expect(states.at(-1)).toMatchObject({
        phase: "failed",
        terminal: true,
      });
      expect(openings).toBe(1);
      expect(
        sockets.map((socket) =>
          socket.sent.filter((frame) => {
            const parsed = JSON.parse(frame) as { type: string };
            return parsed.type === "auth" || parsed.type === "subscribe";
          }),
        ),
      ).toEqual([
        expect.arrayContaining([expect.any(String), expect.any(String)]),
        [],
      ]);
      expect(sockets[0]?.closed).toBe(true);
      for (const socket of sockets) {
        expect(socket.messageListenerCount).toBe(0);
        expect(socket.closeListenerCount).toBe(0);
      }
    },
  );

  it("fails bounded ingress without emitting or acknowledging stale buffered frames", async () => {
    const socket = new MemorySocket();
    const program = Effect.gen(function* () {
      const stream = yield* Subscriptions.useSync((service) =>
        service.stream(query),
      );
      const pull = yield* Stream.toPull(stream);
      yield* pull;
      const overflowPull = yield* Effect.forkChild(pull);
      yield* Effect.sleep("10 millis");
      for (let index = 0; index < 33; index += 1) socket.receive(snapshot);
      yield* Effect.sleep("50 millis");
      expect(sentTypes(socket)).toEqual(["auth", "subscribe"]);
      expect(socket.closed).toBe(true);
      yield* Fiber.interrupt(overflowPull);
    });
    await Effect.runPromise(
      Effect.scoped(
        Effect.provide(
          program,
          makeMemoryDataLayer(endpoint, () => socket),
        ),
      ),
    );
  });
});

describe("connection-wide control frames", () => {
  it("answers pings and exposes anonymous errors", async () => {
    const socket = new MemorySocket();
    const program = Effect.gen(function* () {
      const stream = yield* Subscriptions.useSync((service) =>
        service.stream(query),
      );
      const pull = yield* Stream.toPull(stream);
      yield* pull;
      const helloPull = yield* Effect.forkChild(pull);
      yield* Effect.sleep("10 millis");
      socket.receive(hello);
      yield* Fiber.join(helloPull);
      const subscribedPull = yield* Effect.forkChild(pull);
      yield* Effect.sleep("10 millis");
      socket.receive(subscribed);
      yield* Fiber.join(subscribedPull);
      const snapshotPull = yield* Effect.forkChild(pull);
      yield* Effect.sleep("10 millis");
      socket.receive(snapshot);
      yield* Fiber.join(snapshotPull);
      const pingPull = yield* Effect.forkChild(pull);
      yield* Effect.sleep("10 millis");
      socket.receive(ping);
      const afterPing = yield* Fiber.join(pingPull);
      expect(afterPing[0]?.lastServerContactUnix).toBe(101);
      expect(sentTypes(socket)).toContain("pong");
      const errorPull = yield* Effect.forkChild(pull);
      yield* Effect.sleep("10 millis");
      socket.receive(connectionError);
      const failed = yield* Fiber.join(errorPull);
      expect(failed[0]?.phase).toBe("failed");
      expect(failed[0]?.error).toBe("unauthorized");
    });
    await Effect.runPromise(
      Effect.scoped(
        Effect.provide(
          program,
          makeMemoryDataLayer(endpoint, () => socket, { nowUnix: () => 101 }),
        ),
      ),
    );
  });

  it("reconnects with fresh authentication and a fresh subscription", async () => {
    const first = new MemorySocket();
    const second = new MemorySocket();
    const sockets = [first, second];
    const states: ViewState[] = [];
    const program = Effect.gen(function* () {
      const stream = yield* Subscriptions.useSync((service) =>
        service.stream(query),
      );
      yield* Effect.forkScoped(
        Stream.runForEach(stream, (state) =>
          Effect.sync(() => {
            states.push(state);
          }),
        ),
      );
      yield* Effect.sleep("10 millis");
      first.receive(subscribed);
      first.receive(snapshot);
      yield* Effect.sleep("10 millis");
      const firstLive = states.find((state) => state.phase === "live");
      expect(firstLive?.epoch).toBe("epoch-a");
      first.close();
      for (
        let attempt = 0;
        second.sent.length < 2 && attempt < 200;
        attempt += 1
      ) {
        yield* Effect.sleep("10 millis");
      }
      const auth = JSON.parse(second.sent[0] ?? "{}") as Record<
        string,
        unknown
      >;
      expect(auth).toMatchObject({ type: "auth" });
      expect(auth).not.toHaveProperty("resume_session");
      const subscribe = JSON.parse(second.sent[1] ?? "{}") as Record<
        string,
        unknown
      >;
      expect(subscribe).toMatchObject({ type: "subscribe" });
      expect(subscribe).not.toHaveProperty("resume");
      second.receive(
        JSON.stringify({
          ...serverFrame("subscribed"),
          id: "usage-overview-1",
          epoch: "epoch-b",
        }),
      );
      second.receive(
        JSON.stringify({
          ...serverFrame("snapshot"),
          id: "usage-overview-1",
          epoch: "epoch-b",
          collections: { credentials: [] },
          meta: metadata,
        }),
      );
      for (
        let attempt = 0;
        attempt < 100 &&
        !states.some(
          (state) => state.phase === "live" && state.epoch === "epoch-b",
        );
        attempt += 1
      ) {
        yield* Effect.sleep("10 millis");
      }
      expect(states.some((state) => state.phase === "reconnecting")).toBe(true);
      expect(
        states.some(
          (state) => state.phase === "live" && state.epoch === "epoch-b",
        ),
      ).toBe(true);
    });
    await Effect.runPromise(
      Effect.scoped(
        Effect.provide(
          program,
          makeMemoryDataLayer(
            endpoint,
            () => sockets.shift() ?? new MemorySocket(),
          ),
        ),
      ),
    );
  });
});

class OpeningSocket extends EventTarget {
  readyState: number = WebSocket.CONNECTING;
  closed = false;
  readonly sent: string[] = [];
  readonly added: string[] = [];
  readonly removed: string[] = [];
  listenerCount = 0;

  override addEventListener(
    type: string,
    listener: EventListenerOrEventListenerObject,
    options?: boolean | AddEventListenerOptions,
  ) {
    this.added.push(type);
    this.listenerCount += 1;
    super.addEventListener(type, listener, options);
  }

  override removeEventListener(
    type: string,
    listener: EventListenerOrEventListenerObject,
    options?: boolean | EventListenerOptions,
  ) {
    this.removed.push(type);
    this.listenerCount -= 1;
    super.removeEventListener(type, listener, options);
  }

  send(frame: string) {
    if (this.readyState !== WebSocket.OPEN) throw new Error("not open");
    this.sent.push(frame);
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.readyState = WebSocket.CLOSED;
    this.dispatchEvent(new Event("close"));
  }

  open() {
    this.readyState = WebSocket.OPEN;
    this.dispatchEvent(new Event("open"));
  }

  fail() {
    this.dispatchEvent(new Event("error"));
  }
}

describe("browser socket opening", () => {
  it("waits for OPEN before returning a sendable socket", async () => {
    const browserSocket = new OpeningSocket();
    const pending = Effect.runPromise(
      openBrowserSocket(browserSocket as unknown as WebSocket),
    );
    expect(browserSocket.sent).toEqual([]);
    browserSocket.open();
    const socket = await pending;
    expect(browserSocket.sent).toEqual([]);
    socket.send("frame");
    expect(browserSocket.sent).toEqual(["frame"]);
  });

  it("closes a CONNECTING browser socket and removes listeners on interruption", async () => {
    const browserSocket = new OpeningSocket();
    const fiber = Effect.runFork(
      openBrowserSocket(browserSocket as unknown as WebSocket),
    );
    await Promise.resolve();
    expect(browserSocket.listenerCount).toBe(3);
    await Effect.runPromise(Fiber.interrupt(fiber));
    expect(browserSocket.closed).toBe(true);
    expect(browserSocket.listenerCount).toBe(0);
    expect([...browserSocket.removed].sort()).toEqual([
      "close",
      "error",
      "open",
    ]);
  });

  it("fails and removes open listeners when the browser socket closes first", async () => {
    const browserSocket = new OpeningSocket();
    const pending = Effect.runPromise(
      Effect.flip(openBrowserSocket(browserSocket as unknown as WebSocket)),
    );
    browserSocket.fail();
    const failure = await pending;
    expect(failure).toMatchObject({
      _tag: "TransportFailure",
      reason: "socket_open_failed",
    });
    expect(browserSocket.added).toEqual(["open", "close", "error"]);
    expect([...browserSocket.removed].sort()).toEqual([
      "close",
      "error",
      "open",
    ]);
    expect(browserSocket.closed).toBe(true);
  });
});

describe("transport isolation", () => {
  it("fails consumer streams when a shared socket closes", async () => {
    const socket = new MemorySocket();
    const endpointLayer = Layer.succeed(ControlEndpointService, endpoint);
    const socketLayer = Layer.succeed(ControlSocketFactoryService, {
      open: () => Effect.succeed(socket.socket),
    });
    const program = Effect.gen(function* () {
      const transport = yield* ControlTransport.useSync((value) => value);
      const connection = yield* transport.connect();
      const done = yield* Effect.forkChild(
        Stream.runForEach(connection.frames, () => Effect.void),
      );
      yield* Effect.sleep("10 millis");
      socket.close();
      const exit = yield* Effect.exit(Fiber.join(done));
      expect(exit._tag).toBe("Failure");
    });
    await Effect.runPromise(
      Effect.scoped(
        Effect.provide(
          program,
          ControlTransportLayer.pipe(
            Layer.provide(socketLayer),
            Layer.provide(endpointLayer),
          ),
        ),
      ),
    );
  });
});

describe("shared transport acquisition", () => {
  it("keeps one socket while a second scoped widget remains active", async () => {
    const sockets: MemorySocket[] = [];
    const secondStates: ViewState[] = [];
    const layer = makeMemoryDataLayer(
      endpoint,
      () => {
        const socket = new MemorySocket();
        sockets.push(socket);
        return socket;
      },
      { retryInitialMs: 10, retryJitter: () => 0.5 },
    );
    const program = Effect.gen(function* () {
      const subscriptions = yield* Subscriptions.useSync((service) => service);
      const first = yield* Effect.forkChild(
        Effect.scoped(
          Stream.runDrain(
            subscriptions.stream({ ...query, provider: "first" }),
          ),
        ),
      );
      yield* Effect.sleep("20 millis");
      const second = yield* Effect.forkChild(
        Effect.scoped(
          Stream.runForEach(
            subscriptions.stream({ ...query, provider: "second" }),
            (state) => Effect.sync(() => secondStates.push(state)),
          ),
        ),
      );
      yield* Effect.sleep("20 millis");
      expect(sockets).toHaveLength(1);
      yield* Fiber.interrupt(first);
      yield* Effect.sleep("60 millis");
      expect(sockets).toHaveLength(1);
      expect(sockets[0]?.closed).toBe(false);
      expect(sockets[0]?.messageListenerCount).toBe(1);
      const socket = sockets[0];
      if (socket === undefined) throw new Error("missing shared socket");
      expect(sentTypes(socket)).toContain("unsubscribe");
      socket.receive(
        JSON.stringify({ ...JSON.parse(subscribed), id: "usage-overview-2" }),
      );
      socket.receive(
        JSON.stringify({ ...JSON.parse(snapshot), id: "usage-overview-2" }),
      );
      yield* Effect.sleep("20 millis");
      expect(secondStates.at(-1)?.phase).toBe("live");
      expect(sentTypes(socket)).toContain("ack");
      yield* Fiber.interrupt(second);
      expect(socket.closed).toBe(false);
      yield* Effect.sleep("300 millis");
      expect(socket.closed).toBe(true);
    });
    await Effect.runPromise(Effect.scoped(Effect.provide(program, layer)));
    expect(sockets[0]?.closed).toBe(true);
    expect(sockets[0]?.messageListenerCount).toBe(0);
  });

  it("opens one socket for asynchronous concurrent widgets and cleans it up", async () => {
    const socket = new MemorySocket();
    let openings = 0;
    const layer = makeMemoryDataLayerWithFactory(endpoint, {
      open: () =>
        Effect.callback((resume) => {
          openings += 1;
          queueMicrotask(() => resume(Effect.succeed(socket.socket)));
        }),
    });
    const program = Effect.gen(function* () {
      const subscriptions = yield* Subscriptions.useSync((service) => service);
      const first = yield* Stream.toPull(subscriptions.stream(query));
      const second = yield* Stream.toPull(subscriptions.stream(query));
      yield* first;
      yield* second;
      for (
        let attempt = 0;
        socket.sent.length < 4 && attempt < 100;
        attempt += 1
      ) {
        yield* Effect.sleep("1 millis");
      }
      expect(openings).toBe(1);
      expect(
        socket.sent.filter((frame) => JSON.parse(frame).type === "auth"),
      ).toHaveLength(1);
      expect(
        socket.sent.filter((frame) => JSON.parse(frame).type === "subscribe"),
      ).toHaveLength(2);

      socket.receive(hello);
      socket.receive(ping);
      for (const [id, pull] of [
        ["usage-overview-1", first],
        ["usage-overview-2", second],
      ] as const) {
        socket.receive(JSON.stringify({ ...JSON.parse(subscribed), id }));
        let state: { phase: string } | undefined;
        for (
          let attempt = 0;
          attempt < 4 && state?.phase !== "subscribed";
          attempt += 1
        )
          state = (yield* pull)[0];
        socket.receive(JSON.stringify({ ...JSON.parse(snapshot), id }));
        for (
          let attempt = 0;
          attempt < 4 && state?.phase !== "live";
          attempt += 1
        )
          state = (yield* pull)[0];
        expect(state?.phase ?? "missing").toBe("live");
      }
      expect(
        socket.sent.filter((frame) => JSON.parse(frame).type === "pong"),
      ).toHaveLength(1);
    });
    await Effect.runPromise(Effect.scoped(Effect.provide(program, layer)));
    expect(openings).toBe(1);
    expect(socket.closed).toBe(true);
    expect(socket.messageListenerCount).toBe(0);
    expect(socket.closeListenerCount).toBe(0);
  });
});

describe("transport lifecycle regressions", () => {
  it("reconnects every widget through one replacement socket", async () => {
    const sockets = [new MemorySocket(), new MemorySocket()];
    let openings = 0;
    const layer = makeMemoryDataLayerWithFactory(endpoint, {
      open: () =>
        Effect.sync(() => {
          openings += 1;
          const socket = sockets[openings - 1];
          if (socket === undefined) throw new Error("unexpected socket open");
          return socket.socket;
        }),
    });
    const program = Effect.gen(function* () {
      const subscriptions = yield* Subscriptions.useSync((service) => service);
      const first = yield* Stream.toPull(subscriptions.stream(query));
      const second = yield* Stream.toPull(subscriptions.stream(query));
      yield* first;
      yield* second;
      const shared = sockets[0] ?? new MemorySocket();
      for (
        let attempt = 0;
        shared.sent.length < 3 && attempt < 100;
        attempt += 1
      )
        yield* Effect.sleep("1 millis");
      expect(sentTypes(shared)).toEqual(["auth", "subscribe", "subscribe"]);
      shared.close();
      const replacement = sockets[1] ?? new MemorySocket();
      for (
        let attempt = 0;
        replacement.sent.length < 3 && attempt < 100;
        attempt += 1
      )
        yield* Effect.sleep("1 millis");
      expect(sentTypes(replacement)).toEqual([
        "auth",
        "subscribe",
        "subscribe",
      ]);
    });
    await Effect.runPromise(Effect.scoped(Effect.provide(program, layer)));
    expect(openings).toBe(2);
    expect(sockets[0]?.messageListenerCount).toBe(0);
    expect(sockets[1]?.closed).toBe(true);
    expect(sockets[1]?.messageListenerCount).toBe(0);
    expect(sockets[1]?.closeListenerCount).toBe(0);
  });

  it("closes silently after an injected timeout and publishes reconnecting", async () => {
    const socket = new MemorySocket();
    let clock = 0;
    const timers: Array<() => void> = [];
    const cleared: unknown[] = [];
    const layer = makeMemoryDataLayerWithFactory(
      endpoint,
      { open: () => Effect.succeed(socket.socket) },
      {
        retryInitialMs: 10,
        silenceTimeoutMs: 30_000,
        now: () => clock,
        setTimer: (callback) => {
          timers.push(callback);
          return timers.length;
        },
        clearTimer: (timer) => {
          cleared.push(timer);
        },
      },
    );
    const program = Effect.gen(function* () {
      const stream = yield* Subscriptions.useSync((service) =>
        service.stream(query),
      );
      const pull = yield* Stream.toPull(stream);
      yield* pull;
      for (
        let attempt = 0;
        sentTypes(socket).length < 2 && attempt < 100;
        attempt += 1
      )
        yield* Effect.sleep("1 millis");
      expect(timers).toHaveLength(1);
      const reconnectingPull = yield* Effect.forkChild(pull);
      clock += 30_000;
      timers[0]?.();
      const reconnecting = yield* Fiber.join(reconnectingPull);
      expect(reconnecting[0]).toMatchObject({
        phase: "reconnecting",
        gap: { code: "silence_timeout" },
      });
      expect(cleared).toEqual([1]);
      expect(socket.closed).toBe(true);
    });
    await Effect.runPromise(Effect.scoped(Effect.provide(program, layer)));
    expect(socket.messageListenerCount).toBe(0);
    expect(socket.closeListenerCount).toBe(0);
  });

  it("publishes client overflow and requires a fresh snapshot on retry", async () => {
    const sockets = [new MemorySocket(), new MemorySocket()];
    let openings = 0;
    const layer = makeMemoryDataLayerWithFactory(
      endpoint,
      {
        open: () =>
          Effect.sync(() => {
            openings += 1;
            const socket = sockets[openings - 1];
            if (socket === undefined) throw new Error("unexpected socket open");
            return socket.socket;
          }),
      },
      { retryInitialMs: 10_000 },
    );
    const program = Effect.gen(function* () {
      const stream = yield* Subscriptions.useSync((service) =>
        service.stream(query),
      );
      const pull = yield* Stream.toPull(stream);
      yield* pull;
      for (
        let attempt = 0;
        sentTypes(sockets[0] ?? new MemorySocket()).length < 2 && attempt < 100;
        attempt += 1
      )
        yield* Effect.sleep("1 millis");
      for (let index = 0; index < 33; index += 1) sockets[0]?.receive(snapshot);

      const observed: ViewState[] = [];
      const drainer = yield* Effect.forkChild(
        Effect.gen(function* () {
          for (;;) observed.push(...(yield* pull));
        }),
      );
      for (
        let attempt = 0;
        attempt < 100 &&
        !observed.some((state) => state.gap?.code === "client_overflow");
        attempt += 1
      )
        yield* Effect.sleep("1 millis");
      yield* Fiber.interrupt(drainer);

      expect(observed.at(-1)).toMatchObject({
        phase: "resynchronizing",
        gap: { code: "client_overflow", action: "resnapshot" },
      });
      expect(sockets[0]?.closed).toBe(true);
      const replacement = sockets[1] ?? new MemorySocket();
      for (
        let attempt = 0;
        replacement.sent.length < 2 && attempt < 100;
        attempt += 1
      )
        yield* Effect.sleep("1 millis");
      const retrySubscribe = JSON.parse(replacement.sent[1] ?? "{}") as Record<
        string,
        unknown
      >;
      expect(retrySubscribe).toMatchObject({ type: "subscribe" });
      expect(retrySubscribe).not.toHaveProperty("resume");
    });
    await Effect.runPromise(Effect.scoped(Effect.provide(program, layer)));
    expect(openings).toBe(2);
    expect(sockets[0]?.messageListenerCount).toBe(0);
  });

  it("resubscribes from scratch after a reducer sequence gap", async () => {
    const socket = new MemorySocket();
    const program = Effect.gen(function* () {
      const stream = yield* Subscriptions.useSync((service) =>
        service.stream(query),
      );
      const pull = yield* Stream.toPull(stream);
      yield* pull;
      yield* Effect.sleep("10 millis");
      for (const frame of [subscribed, snapshot]) {
        const next = yield* Effect.forkChild(pull);
        socket.receive(frame);
        yield* Fiber.join(next);
      }
      const gapPull = yield* Effect.forkChild(pull);
      socket.receive(
        JSON.stringify({
          v: 1,
          type: "delta",
          id: "usage-overview-1",
          epoch: "epoch-a",
          seq: 3,
          prev_seq: 1,
          upserts: { credentials: [] },
          removes: { credentials: [] },
          meta: metadata,
        }),
      );
      const gap = yield* Fiber.join(gapPull);
      expect(gap[0]).toMatchObject({
        phase: "resynchronizing",
        epoch: null,
        gap: { code: "sequence_gap", action: "resnapshot" },
      });
      expect(sentTypes(socket)).toEqual([
        "auth",
        "subscribe",
        "ack",
        "unsubscribe",
        "subscribe",
      ]);
      const freshSubscribe = JSON.parse(socket.sent.at(-1) ?? "{}") as Record<
        string,
        unknown
      >;
      expect(freshSubscribe).toMatchObject({ type: "subscribe" });
      expect(freshSubscribe).not.toHaveProperty("resume");
    });
    await Effect.runPromise(
      Effect.scoped(
        Effect.provide(
          program,
          makeMemoryDataLayer(endpoint, () => socket),
        ),
      ),
    );
    expect(socket.closed).toBe(true);
    expect(socket.messageListenerCount).toBe(0);
    expect(socket.closeListenerCount).toBe(0);
  });
});

describe("supervisor reconnect isolation", () => {
  it("reconnects after a socket close", async () => {
    const first = new MemorySocket();
    const second = new MemorySocket();
    const sockets = [first, second];
    const program = Effect.gen(function* () {
      const stream = yield* Subscriptions.useSync((service) =>
        service.stream(query),
      );
      const pull = yield* Stream.toPull(stream);
      yield* pull;
      const next = yield* Effect.forkChild(pull);
      yield* Effect.sleep("10 millis");
      first.close();
      yield* Effect.sleep("50 millis");
      yield* Effect.exit(Fiber.join(next));
      expect(JSON.parse(second.sent.at(0) ?? "{}")).toMatchObject({
        type: "auth",
      });
    });
    await Effect.runPromise(
      Effect.scoped(
        Effect.provide(
          program,
          makeMemoryDataLayer(
            endpoint,
            () => sockets.shift() ?? new MemorySocket(),
          ),
        ),
      ),
    );
  });
});
