# Airlock web data layer

> **Last verified:** 2026-10-25 — the Effect 4 data layer and loopback fixture
> pass lint, type checking, tests, and the Vite build.

The browser data layer uses one scoped Effect transport for all visible widget
subscriptions. `ControlTransport` owns the authenticated WebSocket, its single
message listener, bounded per-widget ingress queues, heartbeat timeout, and
connection generation. `Subscriptions` owns widget IDs, applied sequence state,
fresh reconnection, and retry. The root Atom runtime shares these layers; a
widget's scope sends `unsubscribe` and releases its reference when hidden or
unmounted. The socket closes after a 250 ms idle grace following the final
reference, or when the app runtime shuts down.

The local query includes `kind` for discriminated typing, while the subscribe
frame sends that field beside a query object containing only the kind's filter
fields. Collection entries use the persisted identities: provider and credential
tuple, opaque snapshot ID, decimal request ID, aggregate tuple, or reset
provenance tuple. The reducer rejects mismatched keys, unknown fields, unsafe
integers, sequence gaps, and a fresh snapshot that reuses the current epoch.
Server contact uses receipt time in Unix seconds; `meta.as_of_unix` describes
the server view, and provider observations retain their own row timestamps.

An ingress overflow closes its socket generation before buffered data can be
applied or acknowledged, publishes `client_overflow`, and requests a fresh
snapshot. Schema failures and nonretryable server errors end in a typed failed
state. Transport loss and retryable gaps use jittered exponential retry from
about one second, capped at 30 seconds. Last-good entries remain visible while
reconnecting or paused. The visibility hook combines tab and intersection
signals and remembers the raw intersection result through its 250 ms leave
debounce.

`fixtures/server.mjs` is a loopback-only fake with a separate fake read token.
It independently emits the four supported kinds, filters and windows, fresh
subscriptions, and explicit normal, stale, partial, failed, Console gap,
reconnect, slow consumer, client overflow, malformed, unknown-field, and
unsafe-number cases. `logs.tail` returns `unsupported_subscription`. Run
`npm run fixture` for Vite development and `npm test` for offline data-layer and
loopback tests. The fixture is never selected by a production build. Do not put
real provider credentials or request/response bodies in fixture data.
