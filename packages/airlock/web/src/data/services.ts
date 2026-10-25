import type { Scope } from "effect";
import {
  Cause,
  Context,
  Duration,
  Effect,
  Fiber,
  Layer,
  Queue,
  RcMap,
  Result,
  Stream,
} from "effect";
import {
  type ClientFrame,
  ClientOverflowError,
  type ControlError,
  decodeServerJsonSync,
  decodeSubscriptionQuery,
  encodeClientFrameSync,
  ProtocolDecodeError,
  type ServerFrame,
  type SubscriptionQuery,
  TransportFailure,
  type WireSubscriptionQuery,
} from "./protocol.ts";
import {
  applyServerFrame,
  initialViewState,
  SubscriptionRegistry,
  type ViewState,
} from "./reducer.ts";

interface ControlSocket {
  readonly send: (frame: string) => void;
  readonly close: () => void;
  readonly addMessageListener: (listener: (data: string) => void) => void;
  readonly removeMessageListener: (listener: (data: string) => void) => void;
  readonly addCloseListener: (listener: () => void) => void;
  readonly removeCloseListener: (listener: () => void) => void;
}

export interface ControlSocketFactory {
  readonly open: () => Effect.Effect<ControlSocket, ControlError>;
}

export class ControlSocketFactoryService extends Context.Service<
  ControlSocketFactoryService,
  ControlSocketFactory
>()("ControlSocketFactoryService") {}

export interface ControlEndpoint {
  readonly url: string;
  readonly token: string;
  readonly resumeSession: string | null;
}

export class ControlEndpointService extends Context.Service<
  ControlEndpointService,
  ControlEndpoint
>()("ControlEndpointService") {}

interface TransportConnection {
  readonly frames: Stream.Stream<ServerFrame, ControlError>;
  readonly send: (frame: ClientFrame) => Effect.Effect<void, ControlError>;
  readonly failure: () => ControlError | null;
}

export class ControlTransport extends Context.Service<
  ControlTransport,
  {
    readonly connect: () => Effect.Effect<
      TransportConnection,
      ControlError,
      Scope.Scope
    >;
  }
>()("ControlTransport") {}

type IngressQueue = Queue.Queue<ServerFrame, Cause.Done | ControlError>;

interface SharedConnection {
  readonly queues: Set<IngressQueue>;
  readonly close: (error: ControlError) => void;
  readonly listen: (queue: IngressQueue) => void;
  readonly unlisten: (queue: IngressQueue) => void;
  readonly send: (frame: ClientFrame) => Effect.Effect<void, ControlError>;
  readonly failure: () => ControlError | null;
}

type TransportTimer = number | ReturnType<typeof setTimeout>;

interface TransportOptions {
  readonly silenceTimeoutMs?: number;
  readonly now?: () => number;
  readonly setTimer?: (
    callback: () => void,
    milliseconds: number,
  ) => TransportTimer;
  readonly clearTimer?: (timer: TransportTimer) => void;
}

function errorReason(error: unknown): string {
  return error instanceof TransportFailure ? error.reason : "client_overflow";
}

function makeTransport(
  factory: ControlSocketFactory,
  endpoint: ControlEndpoint,
  options: TransportOptions = {},
): Effect.Effect<
  {
    connect: () => Effect.Effect<
      TransportConnection,
      ControlError,
      Scope.Scope
    >;
  },
  never,
  Scope.Scope
> {
  const silenceTimeoutMs = options.silenceTimeoutMs ?? 30_000;
  const now = options.now ?? Date.now;
  const setTimer =
    options.setTimer ??
    ((callback: () => void, milliseconds: number) =>
      setTimeout(callback, milliseconds));
  const clearTimer =
    options.clearTimer ??
    ((timer: TransportTimer) => clearTimeout(timer as never));
  const state = { generation: 0, session: null as string | null };

  return Effect.gen(function* () {
    const failQueues = (connection: SharedConnection, error: ControlError) => {
      for (const queue of [...connection.queues]) {
        Queue.failCauseUnsafe(queue, Cause.fail(error));
      }
    };

    const connections = yield* RcMap.make({
      idleTimeToLive: "250 millis",
      lookup: (generation: number) =>
        Effect.acquireRelease(
          Effect.gen(function* () {
            const socket = yield* factory.open();
            const queues = new Set<IngressQueue>();
            let active = true;
            let closeError: ControlError | null = null;
            let lastContact = now();
            let timer = setTimer(() => {
              if (active && now() - lastContact >= silenceTimeoutMs) {
                connection.close(
                  new TransportFailure({ reason: "silence_timeout" }),
                );
              }
            }, silenceTimeoutMs);

            const resetLiveness = () => {
              clearTimer(timer);
              lastContact = now();
              timer = setTimer(() => {
                if (active && now() - lastContact >= silenceTimeoutMs) {
                  connection.close(
                    new TransportFailure({ reason: "silence_timeout" }),
                  );
                }
              }, silenceTimeoutMs);
            };

            const connection: SharedConnection = {
              queues,
              close: (error) => {
                if (!active) return;
                active = false;
                closeError = error;
                clearTimer(timer);
                if (state.generation === generation) state.generation += 1;
                failQueues(connection, error);
                socket.removeMessageListener(receive);
                socket.removeCloseListener(closed);
                socket.close();
              },
              listen: (queue) => {
                if (active) queues.add(queue);
              },
              unlisten: (queue) => {
                queues.delete(queue);
              },
              send: (frame) =>
                Effect.gen(function* () {
                  if (!active || state.generation !== generation) {
                    return yield* Effect.fail(
                      new TransportFailure({ reason: "connection_closed" }),
                    );
                  }
                  yield* Effect.try({
                    try: () => socket.send(encodeClientFrameSync(frame)),
                    catch: () =>
                      new TransportFailure({
                        reason: "send_failed",
                      }),
                  });
                }),
              failure: () => closeError,
            };

            function dispatch(frame: ServerFrame) {
              for (const queue of [...queues]) {
                if (!Queue.offerUnsafe(queue, frame)) {
                  connection.close(new ClientOverflowError());
                  return;
                }
              }
            }

            function receive(data: string) {
              resetLiveness();
              let frame: ServerFrame;
              try {
                frame = decodeServerJsonSync(data);
              } catch (error) {
                connection.close(
                  error instanceof ProtocolDecodeError
                    ? error
                    : new TransportFailure({ reason: "invalid_frame" }),
                );
                return;
              }
              if (frame.type === "hello") state.session = frame.session;
              if (frame.type === "ping") {
                try {
                  socket.send(
                    encodeClientFrameSync({
                      v: 1,
                      type: "pong",
                      nonce: frame.nonce,
                    }),
                  );
                } catch {
                  connection.close(
                    new TransportFailure({ reason: "send_failed" }),
                  );
                  return;
                }
              }
              dispatch(frame);
            }

            function closed() {
              connection.close(
                new TransportFailure({ reason: "connection_closed" }),
              );
            }

            socket.addMessageListener(receive);
            socket.addCloseListener(closed);
            try {
              socket.send(
                encodeClientFrameSync({
                  v: 1,
                  type: "auth",
                  token: endpoint.token,
                  resume_session: state.session ?? endpoint.resumeSession,
                }),
              );
            } catch {
              connection.close(new TransportFailure({ reason: "send_failed" }));
              return yield* Effect.fail(
                new TransportFailure({ reason: "socket_open_failed" }),
              );
            }
            return connection;
          }),
          (connection) =>
            Effect.sync(() =>
              connection.close(
                new TransportFailure({ reason: "connection_closed" }),
              ),
            ),
          { interruptible: true },
        ),
    });

    const connect = Effect.gen(function* () {
      return yield* RcMap.get(connections, state.generation);
    }).pipe(
      Effect.map((connection) => ({
        frames: Stream.callback<ServerFrame, ControlError>(
          (queue) =>
            Effect.gen(function* () {
              connection.listen(queue);
              yield* Effect.addFinalizer(() =>
                Effect.sync(() => connection.unlisten(queue)),
              );
            }),
          { bufferSize: 32, strategy: "dropping" },
        ),
        send: connection.send,
        failure: connection.failure,
      })),
    );

    return { connect: () => connect };
  });
}

export const ControlTransportLayer = Layer.effect(
  ControlTransport,
  Effect.gen(function* () {
    const factory = yield* ControlSocketFactoryService;
    const endpoint = yield* ControlEndpointService;
    return yield* makeTransport(factory, endpoint);
  }),
);

export function wrapBrowserSocket(socket: WebSocket): ControlSocket {
  const messageListeners = new Map<(data: string) => void, EventListener>();
  const closeListeners = new Map<() => void, EventListener>();
  return {
    send: (frame) => socket.send(frame),
    close: () => socket.close(),
    addMessageListener: (listener) => {
      const eventListener: EventListener = (event) => {
        if (event.type === "message" && "data" in event) {
          listener(String(event.data));
        }
      };
      messageListeners.set(listener, eventListener);
      socket.addEventListener("message", eventListener);
    },
    removeMessageListener: (listener) => {
      const eventListener = messageListeners.get(listener);
      if (eventListener !== undefined) {
        messageListeners.delete(listener);
        socket.removeEventListener("message", eventListener);
      }
    },
    addCloseListener: (listener) => {
      const eventListener = () => listener();
      closeListeners.set(listener, eventListener);
      socket.addEventListener("close", eventListener);
    },
    removeCloseListener: (listener) => {
      const eventListener = closeListeners.get(listener);
      if (eventListener !== undefined) {
        closeListeners.delete(listener);
        socket.removeEventListener("close", eventListener);
      }
    },
  };
}

export function openBrowserSocket(
  socket: WebSocket,
): Effect.Effect<ControlSocket, ControlError> {
  if (socket.readyState === 1) {
    return Effect.succeed(wrapBrowserSocket(socket));
  }
  return Effect.callback((resume) => {
    let settled = false;
    const cleanup = () => {
      socket.removeEventListener("open", opened);
      socket.removeEventListener("close", failed);
      socket.removeEventListener("error", failed);
    };
    const opened = () => {
      if (settled) return;
      settled = true;
      cleanup();
      resume(Effect.succeed(wrapBrowserSocket(socket)));
    };
    const failed = () => {
      if (settled) return;
      settled = true;
      cleanup();
      socket.close();
      resume(
        Effect.fail(new TransportFailure({ reason: "socket_open_failed" })),
      );
    };
    socket.addEventListener("open", opened);
    socket.addEventListener("close", failed);
    socket.addEventListener("error", failed);
    return Effect.sync(() => {
      cleanup();
      if (!settled) socket.close();
    });
  });
}

export const BrowserSocketLayer = Layer.effect(
  ControlSocketFactoryService,
  Effect.gen(function* () {
    const endpoint = yield* ControlEndpointService;
    return {
      open: () => openBrowserSocket(new WebSocket(endpoint.url, "airlock.v1")),
    };
  }),
);

export interface SubscriptionRuntimeOptions {
  readonly retryInitialMs?: number;
  readonly retryJitter?: () => number;
  readonly nowUnix?: () => number;
  readonly sleep?: (milliseconds: number) => Effect.Effect<void>;
}

class SubscriptionsRuntimeOptionsService extends Context.Service<
  SubscriptionsRuntimeOptionsService,
  SubscriptionRuntimeOptions
>()("AirlockSubscriptionsRuntimeOptions") {}

export class Subscriptions extends Context.Service<
  Subscriptions,
  {
    readonly stream: (
      query: SubscriptionQuery,
    ) => Stream.Stream<ViewState, ControlError, Scope.Scope>;
  }
>()("AirlockSubscriptions") {}

class ReconnectNow extends Error {}
class TerminalNow extends Error {}

function reconnectingView(state: ViewState, code: string): ViewState {
  return {
    ...state,
    phase: "reconnecting",
    syncPhase: "none",
    gap: { code, retryable: true, action: "retry" },
  };
}

function overflowView(state: ViewState): ViewState {
  return {
    ...state,
    phase: "resynchronizing",
    syncPhase: "none",
    epoch: null,
    headSeq: 0,
    lastSeq: 0,
    entries: state.lastGoodEntries,
    retainedBytes: state.retainedBytes,
    gap: {
      code: "client_overflow",
      retryable: true,
      action: "resnapshot",
    },
  };
}

function retryDelayMs(
  attempt: number,
  initialMs: number,
  jitter: () => number,
): number {
  return Math.min(30_000, initialMs * 2 ** attempt * (0.5 + jitter()));
}

function failedView(state: ViewState, reason: string): ViewState {
  return {
    ...state,
    phase: "failed",
    syncPhase: "none",
    gap: { code: reason, retryable: false, action: "retry" },
    error: reason,
    terminal: true,
  };
}

function wireQuery(query: SubscriptionQuery): WireSubscriptionQuery {
  switch (query.kind) {
    case "usage.overview":
      return {
        ...(query.provider === undefined ? {} : { provider: query.provider }),
        ...(query.credential === undefined
          ? {}
          : { credential: query.credential }),
      };
    case "usage.series":
      return {
        provider: query.provider,
        credential: query.credential,
        source: query.source,
        surface: query.surface,
        window: query.window,
        limit: query.limit,
      };
    case "requests.table": {
      const { kind: _kind, ...wire } = query;
      return wire;
    }
    case "requests.series": {
      const { kind: _kind, ...wire } = query;
      return wire;
    }
    case "logs.tail": {
      const { kind: _kind, ...wire } = query;
      return wire;
    }
  }
}

function subscribeFrame(
  id: string,
  query: SubscriptionQuery,
  state: ViewState,
): ClientFrame {
  return {
    v: 1,
    type: "subscribe",
    id,
    kind: query.kind,
    query: wireQuery(query),
    resume:
      state.epoch === null || state.lastSeq === 0
        ? null
        : { epoch: state.epoch, after_seq: state.lastSeq },
  } as ClientFrame;
}

export const SubscriptionsLayer = Layer.effect(
  Subscriptions,
  Effect.gen(function* () {
    const transport = yield* ControlTransport;
    const runtimeOptions = yield* SubscriptionsRuntimeOptionsService;
    const retryInitialMs = runtimeOptions.retryInitialMs ?? 1_000;
    const retryJitter = runtimeOptions.retryJitter ?? Math.random;
    const nowUnix =
      runtimeOptions.nowUnix ?? (() => Math.floor(Date.now() / 1000));
    const sleep =
      runtimeOptions.sleep ??
      ((milliseconds: number) => Effect.sleep(Duration.millis(milliseconds)));
    const registry = new SubscriptionRegistry();
    return {
      stream: (query) =>
        Stream.unwrap(
          Effect.gen(function* () {
            const validatedQuery = yield* decodeSubscriptionQuery(query);
            const lease = registry.acquire(validatedQuery);
            yield* Effect.addFinalizer(() => Effect.sync(lease.release));
            const output = yield* Queue.bounded<ViewState>(1);
            yield* Queue.offer(output, initialViewState());
            const replaceOutput = (state: ViewState) =>
              Effect.gen(function* () {
                yield* Queue.poll(output);
                yield* Queue.offer(output, state);
              });
            let view = initialViewState();
            let attemptFailure: ControlError | null = null;
            let generation = 0;

            const supervisor: Effect.Effect<void, ControlError, Scope.Scope> =
              Effect.gen(function* () {
                let attempt = 0;
                for (;;) {
                  attemptFailure = null;
                  const attemptGeneration = ++generation;
                  const attemptEffect = Effect.scoped(
                    Effect.gen(function* () {
                      const connection = yield* transport.connect();
                      yield* Effect.addFinalizer(() =>
                        connection
                          .send({ v: 1, type: "unsubscribe", id: lease.id })
                          .pipe(
                            Effect.ignore,
                            Effect.andThen(
                              Effect.sync(() => {
                                if (attemptFailure === null) {
                                  attemptFailure = connection.failure();
                                }
                              }),
                            ),
                          ),
                      );

                      yield* connection.send(
                        subscribeFrame(lease.id, validatedQuery, view),
                      );
                      yield* Stream.runForEach(connection.frames, (frame) =>
                        Effect.gen(function* () {
                          const closedFailure = connection.failure();
                          if (
                            attemptGeneration !== generation ||
                            (closedFailure !== null &&
                              !(
                                closedFailure instanceof TransportFailure &&
                                closedFailure.reason === "connection_closed" &&
                                frame.type === "error" &&
                                !frame.retryable
                              ))
                          ) {
                            return;
                          }
                          const applied = applyServerFrame(
                            view,
                            frame,
                            validatedQuery,
                            lease.id,
                            nowUnix(),
                          );
                          view = applied.state;
                          if (applied.state.phase === "live") attempt = 0;
                          yield* Queue.offer(output, applied.state);
                          if (applied.acknowledgement !== null) {
                            yield* connection.send({
                              v: 1,
                              type: "ack",
                              id: lease.id,
                              epoch: applied.acknowledgement.epoch,
                              seq: applied.acknowledgement.seq,
                            });
                          }
                          if (applied.state.terminal) {
                            return yield* Effect.fail(new TerminalNow());
                          }
                          if (applied.recovery === "reconnect") {
                            yield* connection
                              .send({
                                v: 1,
                                type: "unsubscribe",
                                id: lease.id,
                              })
                              .pipe(Effect.ignore);
                            return yield* Effect.fail(new ReconnectNow());
                          }
                          if (applied.recovery === "resnapshot") {
                            yield* connection
                              .send({
                                v: 1,
                                type: "unsubscribe",
                                id: lease.id,
                              })
                              .pipe(Effect.ignore);
                            yield* connection.send(
                              subscribeFrame(
                                lease.id,
                                validatedQuery,
                                applied.state,
                              ),
                            );
                          }
                        }),
                      ).pipe(
                        Effect.catchIf(
                          (error) => error instanceof TerminalNow,
                          () => Effect.void,
                        ),
                      );
                      return {
                        kind: "ended" as const,
                        failure: connection.failure(),
                      };
                    }),
                  );
                  const outcomeResult = yield* Effect.result(attemptEffect);
                  generation += 1;
                  const outcome = Result.isSuccess(outcomeResult)
                    ? outcomeResult.success
                    : { kind: "failed" as const, error: outcomeResult.failure };

                  const failure =
                    attemptFailure ??
                    (outcome.kind === "ended"
                      ? outcome.failure
                      : outcome.error) ??
                    new TransportFailure({ reason: "connection_closed" });
                  if (failure instanceof ClientOverflowError) {
                    view = overflowView(view);
                    yield* replaceOutput(view);
                    attempt = 0;
                    continue;
                  }
                  if (view.terminal || failure instanceof ProtocolDecodeError) {
                    if (failure instanceof ProtocolDecodeError) {
                      view = failedView(view, failure.reason);
                      yield* replaceOutput(view);
                    }
                    return yield* Effect.never;
                  }
                  view = reconnectingView(
                    view,
                    outcome.kind === "failed" &&
                      outcome.error instanceof ReconnectNow
                      ? "server_retry"
                      : errorReason(failure),
                  );
                  yield* replaceOutput(view);
                  yield* sleep(
                    retryDelayMs(attempt, retryInitialMs, retryJitter),
                  );
                  attempt += 1;
                }
              });

            const supervisorFiber = yield* Effect.forkChild(
              Effect.scoped(supervisor),
            );
            yield* Effect.addFinalizer(() => Fiber.interrupt(supervisorFiber));
            return Stream.fromQueue(output);
          }),
        ),
    };
  }),
);

export function makeDataLayer(
  endpoint: ControlEndpoint,
): Layer.Layer<Subscriptions, ControlError> {
  const endpointLayer = Layer.succeed(ControlEndpointService, endpoint);
  const optionsLayer = Layer.succeed(SubscriptionsRuntimeOptionsService, {
    retryInitialMs: 1_000,
  });
  const transport = ControlTransportLayer.pipe(
    Layer.provide(BrowserSocketLayer),
    Layer.provide(endpointLayer),
  );
  return SubscriptionsLayer.pipe(
    Layer.provide(transport),
    Layer.provide(optionsLayer),
  );
}

export class MemorySocket {
  readonly #messages = new Set<(data: string) => void>();
  readonly #closes = new Set<() => void>();
  readonly #socket: ControlSocket;
  closed = false;
  readonly sent: string[] = [];

  constructor() {
    this.#socket = {
      send: (frame) => {
        if (this.closed) throw new Error("socket closed");
        this.sent.push(frame);
      },
      close: () => this.close(),
      addMessageListener: (listener) => this.#messages.add(listener),
      removeMessageListener: (listener) => this.#messages.delete(listener),
      addCloseListener: (listener) => this.#closes.add(listener),
      removeCloseListener: (listener) => this.#closes.delete(listener),
    };
  }

  get socket(): ControlSocket {
    return this.#socket;
  }

  get messageListenerCount(): number {
    return this.#messages.size;
  }

  get closeListenerCount(): number {
    return this.#closes.size;
  }

  receive(data: string) {
    for (const listener of [...this.#messages]) listener(data);
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    for (const listener of [...this.#closes]) listener();
  }
}

export interface MemoryLayerOptions extends SubscriptionRuntimeOptions {
  readonly silenceTimeoutMs?: number;
  readonly now?: () => number;
  readonly setTimer?: (
    callback: () => void,
    milliseconds: number,
  ) => TransportTimer;
  readonly clearTimer?: (timer: TransportTimer) => void;
}

export function makeMemoryDataLayerWithFactory(
  endpoint: ControlEndpoint,
  factory: ControlSocketFactory,
  options: MemoryLayerOptions = {},
): Layer.Layer<Subscriptions, ControlError> {
  const transport = Layer.effect(
    ControlTransport,
    Effect.gen(function* () {
      const transportOptions = {
        ...(options.silenceTimeoutMs === undefined
          ? {}
          : { silenceTimeoutMs: options.silenceTimeoutMs }),
        ...(options.now === undefined ? {} : { now: options.now }),
        ...(options.setTimer === undefined
          ? {}
          : { setTimer: options.setTimer }),
        ...(options.clearTimer === undefined
          ? {}
          : { clearTimer: options.clearTimer }),
      };
      return yield* makeTransport(factory, endpoint, transportOptions);
    }),
  );
  const optionsLayer = Layer.succeed(SubscriptionsRuntimeOptionsService, {
    retryInitialMs: options.retryInitialMs ?? 10,
    ...(options.retryJitter === undefined
      ? {}
      : { retryJitter: options.retryJitter }),
    ...(options.nowUnix === undefined ? {} : { nowUnix: options.nowUnix }),
    ...(options.sleep === undefined ? {} : { sleep: options.sleep }),
  });
  return SubscriptionsLayer.pipe(
    Layer.provide(transport),
    Layer.provide(optionsLayer),
  );
}

export function makeMemoryDataLayer(
  endpoint: ControlEndpoint,
  openSocket: () => MemorySocket,
  options: MemoryLayerOptions = {},
): Layer.Layer<Subscriptions, ControlError> {
  return makeMemoryDataLayerWithFactory(
    endpoint,
    {
      open: () => Effect.succeed(openSocket().socket),
    },
    options,
  );
}
